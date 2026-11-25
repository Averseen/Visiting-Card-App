import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const MaterialApp(home: CardsPage()));

// ---------- Database ----------
class Db {
  static Database? _db;

  static Future<Database> get db async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'cards.db'),
        version: 2,
        onCreate: (d, v) => d.execute('''CREATE TABLE cards(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT, company TEXT, phone TEXT, email TEXT,
          website TEXT, address TEXT, extra TEXT, raw TEXT, image TEXT)'''),
        onUpgrade: (d, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await d.execute('ALTER TABLE cards ADD COLUMN extra TEXT');
          }
        },
      );

  static String orderFor(String sort) {
    switch (sort) {
      case 'name':
        return "CASE WHEN name IS NULL OR TRIM(name) = '' "
            'THEN 1 ELSE 0 END, name COLLATE NOCASE ASC';
      case 'name_desc':
        return "CASE WHEN name IS NULL OR TRIM(name) = '' "
            'THEN 1 ELSE 0 END, name COLLATE NOCASE DESC';
      default:
        return 'id DESC';
    }
  }

  static Future<List<Map<String, Object?>>> search(String q,
      {String orderBy = 'id DESC'}) async {
    final d = await db;
    q = q.trim();
    if (q.isEmpty) return d.query('cards', orderBy: orderBy);
    return d.query(
      'cards',
      where: 'name LIKE ? OR company LIKE ? OR phone LIKE ? OR email LIKE ? '
          'OR website LIKE ? OR address LIKE ? OR extra LIKE ? OR raw LIKE ?',
      whereArgs: List.filled(8, '%$q%'),
      orderBy: orderBy,
    );
  }

  static Future<void> insert(Map<String, Object?> m) async =>
      (await db).insert('cards', m);

  static Future<void> update(int id, Map<String, Object?> m) async =>
      (await db).update('cards', m, where: 'id = ?', whereArgs: [id]);

  static Future<void> delete(int id) async =>
      (await db).delete('cards', where: 'id = ?', whereArgs: [id]);
}

Map<String, String> sortedExtras(Map<String, String> m) {
  final keys = m.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return {for (final k in keys) k: m[k]!};
}

Map<String, String> decodeExtra(Object? raw) {
  if (raw == null) return {};
  final text = '$raw'.trim();
  if (text.isEmpty) return {};
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return sortedExtras(
          decoded.map((k, v) => MapEntry('$k', '${v ?? ''}')));
    }
  } catch (_) {}
  return {};
}

// ---------- Parser ----------
Map<String, String> parseCard(String text) {
  final lines =
      text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final email =
      RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+').firstMatch(text)?.group(0) ?? '';
  final web = RegExp(r'(https?://|www\.)[^\s]+', caseSensitive: false)
          .firstMatch(text)
          ?.group(0) ??
      '';
  final phones = RegExp(r'\+?\d[\d\s\-()]{7,}\d')
      .allMatches(text)
      .map((m) => m.group(0)!.trim())
      .toList();

  bool isContact(String l) =>
      l.contains('@') ||
      l.toLowerCase().contains('www') ||
      l.toLowerCase().startsWith('http') ||
      phones.any((ph) => l.contains(ph));

  final plain =
      lines.where((l) => !isContact(l) && !RegExp(r'\d').hasMatch(l)).toList();
  final address = lines
      .where((l) => !isContact(l) && RegExp(r'\d').hasMatch(l))
      .join(', ');

  return {
    'name': plain.isNotEmpty ? plain[0] : '',
    'company': plain.length > 1 ? plain[1] : '',
    'phone': phones.join(', '),
    'email': email,
    'website': web,
    'address': address,
  };
}

// ---------- UI ----------
class CardsPage extends StatefulWidget {
  const CardsPage({super.key});
  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _cards = [];
  String _sort = 'newest';

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _autoOpening = false;

  Future<void> _load({bool autoOpenSingle = false}) async {
    final q = _search.text;
    final order = Db.orderFor(_sort);
    final r = await Db.search(q, orderBy: order);
    if (!mounted || q != _search.text || order != Db.orderFor(_sort)) return;
    setState(() => _cards = r);
    if (!autoOpenSingle || _autoOpening) return;
    if (q.trim().isEmpty || r.length != 1) return;
    _autoOpening = true;
    try {
      await _details(r.first);
    } finally {
      _autoOpening = false;
    }
  }

  Future<void> _scan(ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src);
    if (x == null) return;
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    final res = await rec.processImage(InputImage.fromFilePath(x.path));
    await rec.close();
    final dir = await getApplicationDocumentsDirectory();
    final saved = await File(x.path).copy(
        p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.jpg'));
    if (!mounted) return;
    final data = await showDialog<CardEditResult>(
      context: context,
      builder: (_) => EditDialog(fields: parseCard(res.text)),
    );
    if (data == null) return;
    await Db.insert({
      ...data.fields,
      'extra': jsonEncode(data.extras),
      'raw': res.text,
      'image': saved.path,
    });
    _load();
  }

  Future<void> _addManual() async {
    final data = await showDialog<CardEditResult>(
      context: context,
      builder: (_) =>
          EditDialog(fields: const <String, String>{}, title: 'Add card'),
    );
    if (data == null) return;
    await Db.insert({
      ...data.fields,
      'extra': jsonEncode(data.extras),
      'raw': '',
      'image': null,
    });
    _load();
  }

  void _pickSource() => showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
          child: Wrap(children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(context);
                _scan(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(context);
                _scan(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_add),
              title: const Text('Add manually'),
              onTap: () {
                Navigator.pop(context);
                _addManual();
              },
            ),
          ]),
        ),
      );

  Map<String, String> _fixedFieldsOf(Map<String, Object?> c) => {
        for (final k in EditDialog.fieldOrder) k: '${c[k] ?? ''}',
      };

  Future<void> _details(Map<String, Object?> card) async {
    var c = Map<String, Object?>.from(card);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final extras = decodeExtra(c['extra']);
          return AlertDialog(
            title: Text('${c['name'] ?? 'Card'}'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (c['image'] != null)
                    Image.file(File('${c['image']}'),
                        width: double.maxFinite, fit: BoxFit.contain),
                  const SizedBox(height: 8),
                  for (final k in EditDialog.fieldOrder)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                          '${EditDialog.fieldLabels[k]}: ${c[k] ?? ''}'),
                    ),
                  if (extras.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Work',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    for (final e in extras.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('${e.key}: ${e.value}'),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _confirmDelete(dialogContext, c),
                child: const Text('Delete'),
              ),
              TextButton(
                onPressed: () async {
                  final result = await showDialog<CardEditResult>(
                    context: context,
                    builder: (_) => EditDialog(
                      fields: _fixedFieldsOf(c),
                      extras: extras,
                      title: 'Edit card',
                    ),
                  );
                  if (result == null) return;
                  final updated = {
                    ...result.fields,
                    'extra': jsonEncode(result.extras),
                  };
                  await Db.update(c['id'] as int, updated);
                  c = {...c, ...updated};
                  if (dialogContext.mounted) setDialogState(() {});
                  _load();
                },
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext dialogContext, Map<String, Object?> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text(
            'Delete "${c['name'] ?? 'this card'}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Db.delete(c['id'] as int);
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (_) => _load(autoOpenSingle: true),
            onSubmitted: (_) => _load(autoOpenSingle: true),
            decoration: const InputDecoration(
                hintText: 'Search name, company, or work...',
                border: InputBorder.none),
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort',
              initialValue: _sort,
              onSelected: (v) {
                setState(() => _sort = v);
                _load();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'newest', child: Text('Newest first')),
                PopupMenuItem(value: 'name', child: Text('Name A-Z')),
                PopupMenuItem(value: 'name_desc', child: Text('Name Z-A')),
              ],
            ),
          ],
        ),
        body: ListView.builder(
          itemCount: _cards.length,
          itemBuilder: (_, i) {
            final c = _cards[i];
            return ListTile(
              title: Text('${c['name']}'),
              subtitle: Text('${c['company']} • ${c['phone']}'),
              onTap: () => _details(c),
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add card',
          onPressed: _pickSource,
          child: const Icon(Icons.add),
        ),
      );
}

class CardEditResult {
  final Map<String, String> fields;
  final Map<String, String> extras;
  const CardEditResult(this.fields, this.extras);
}

class _ExtraField {
  final TextEditingController key;
  final TextEditingController value;
  _ExtraField(String k, String v)
      : key = TextEditingController(text: k),
        value = TextEditingController(text: v);

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class EditDialog extends StatefulWidget {
  static const fieldOrder = [
    'name',
    'company',
    'phone',
    'email',
    'website',
    'address',
  ];
  static const fieldLabels = {
    'name': 'Name',
    'company': 'Company',
    'phone': 'Phone',
    'email': 'Email',
    'website': 'Website',
    'address': 'Address',
  };

  final Map<String, String> fields;
  final Map<String, String> extras;
  final String title;
  const EditDialog({
    super.key,
    required this.fields,
    this.extras = const {},
    this.title = 'Verify details',
  });

  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  late final Map<String, TextEditingController> _fields = {
    for (final k in EditDialog.fieldOrder)
      k: TextEditingController(text: widget.fields[k] ?? ''),
  };
  late final List<_ExtraField> _extras = [
    for (final e in sortedExtras(widget.extras).entries)
      _ExtraField(e.key, e.value),
  ];

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final e in _extras) {
      e.dispose();
    }
    super.dispose();
  }

  CardEditResult _result() => CardEditResult(
        {
          for (final e in _fields.entries) e.key: e.value.text.trim(),
        },
        sortedExtras({
          for (final e in _extras)
            if (e.key.text.trim().isNotEmpty)
              e.key.text.trim(): e.value.text.trim(),
        }),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in _fields.entries)
                TextField(
                  controller: e.value,
                  decoration:
                      InputDecoration(labelText: EditDialog.fieldLabels[e.key]),
                ),
              const SizedBox(height: 12),
              const Text('Work',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (var i = 0; i < _extras.length; i++)
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _extras[i].key,
                        decoration:
                            const InputDecoration(labelText: 'Field name'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _extras[i].value,
                        decoration: const InputDecoration(labelText: 'Value'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () {
                        setState(() {
                          _extras.removeAt(i).dispose();
                        });
                      },
                    ),
                  ],
                ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _extras.add(_ExtraField('', ''));
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add field'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, _result()),
            child: const Text('Save'),
          ),
        ],
      );
}
