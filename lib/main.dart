import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() =>
    runApp(const MaterialApp(title: 'Visiting Card Holder', home: CardsPage()));

String s(Object? v) => '${v ?? ''}'.trim();

int cmp(String a, String b) {
  a = a.trim().toLowerCase();
  b = b.trim().toLowerCase();
  if (a.isEmpty && b.isEmpty) return 0;
  if (a.isEmpty) return 1;
  if (b.isEmpty) return -1;
  return a.compareTo(b);
}

String fullName(Map<String, Object?> c) {
  final t = s(c['title']);
  final n = s(c['name']);
  if (n.isEmpty) return '';
  return t.isEmpty ? n : '$t $n';
}

Map<String, String> decodeExtra(Object? raw) {
  final text = s(raw);
  if (text.isEmpty) return {};
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry('$k', '${v ?? ''}'));
    }
  } catch (_) {}
  return {};
}

List<String> decodeWorks(Object? raw) {
  final text = s(raw);
  if (text.isEmpty) return [];
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) {
      return decoded
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
  } catch (_) {}
  return [];
}

// ---------- Database ----------
class Db {
  static Database? _db;

  static Future<Database> get db async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'cards.db'),
        version: 4,
        onCreate: (d, v) => d.execute('''CREATE TABLE cards(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT, name TEXT, company TEXT, designation TEXT, phone TEXT,
          email TEXT, website TEXT, address TEXT, works TEXT, remark TEXT,
          extra TEXT, raw TEXT, image TEXT)'''),
        onUpgrade: (d, oldV, newV) async {
          if (oldV < 2) {
            await d.execute('ALTER TABLE cards ADD COLUMN extra TEXT');
          }
          if (oldV < 3) {
            await d.execute('ALTER TABLE cards ADD COLUMN designation TEXT');
            await d.execute('ALTER TABLE cards ADD COLUMN works TEXT');
            await d.execute('ALTER TABLE cards ADD COLUMN remark TEXT');
            final rows = await d.query('cards', columns: ['id', 'extra']);
            for (final r in rows) {
              final old = decodeExtra(r['extra']);
              final list = <String>[];
              for (final e in old.entries) {
                final v = e.value.trim();
                final t = v.isNotEmpty ? v : e.key.trim();
                if (t.isNotEmpty) list.add(t);
              }
              await d.update('cards', {'works': jsonEncode(list)},
                  where: 'id = ?', whereArgs: [r['id']]);
            }
          }
          if (oldV < 4) {
            await d.execute('ALTER TABLE cards ADD COLUMN title TEXT');
          }
        },
      );

  static Future<List<Map<String, Object?>>> search(String q) async {
    final d = await db;
    q = q.trim();
    if (q.isEmpty) return d.query('cards', orderBy: 'id DESC');
    return d.query(
      'cards',
      where: 'name LIKE ? OR company LIKE ? OR designation LIKE ? '
          'OR phone LIKE ? OR email LIKE ? OR website LIKE ? '
          'OR address LIKE ? OR works LIKE ? OR remark LIKE ? OR raw LIKE ?',
      whereArgs: List.filled(10, '%$q%'),
      orderBy: 'id DESC',
    );
  }

  static Future<void> insert(Map<String, Object?> m) async =>
      (await db).insert('cards', m);

  static Future<void> update(int id, Map<String, Object?> m) async =>
      (await db).update('cards', m, where: 'id = ?', whereArgs: [id]);

  static Future<void> delete(int id) async =>
      (await db).delete('cards', where: 'id = ?', whereArgs: [id]);
}

// ---------- Parser ----------
const _desigWords = [
  'manager', 'director', 'engineer', 'founder', 'ceo', 'cfo', 'cto', 'coo',
  'owner', 'proprietor', 'proprietress', 'partner', 'sales', 'executive',
  'president', 'vice', 'officer', 'consultant', 'head', 'supervisor',
  'designer', 'developer', 'chairman', 'secretary', 'accountant',
  'architect', 'advisor', 'associate', 'representative', 'marketing',
  'md', 'gm', 'agm', 'dgm', 'incharge', 'coordinator', 'technician',
];
const _companyWords = [
  'pvt', 'ltd', 'limited', 'llp', 'inc', 'corp', 'corporation', 'company',
  'enterprises', 'enterprise', 'industries', 'solutions', 'technologies',
  'technology', 'systems', 'services', 'traders', 'trading', 'associates',
  'group', 'consultants', 'engineers', 'works', 'stores', 'agency',
  'agencies', 'infra', 'constructions', 'construction', 'builders',
  'electricals', 'electronics', 'motors', 'textiles', 'exports', 'imports',
  'laboratories', 'labs', 'studio', 'international', 'global',
];
const _addrWords = [
  'road', 'street', 'nagar', 'floor', 'sector', 'plot', 'block', 'colony',
  'lane', 'near', 'opp', 'opposite', 'building', 'tower', 'complex',
  'estate', 'area', 'city', 'district', 'dist', 'state', 'india', 'pin',
];

class _L {
  final String t;
  final double h;
  final int i;
  _L(this.t, this.h, this.i);
}

bool _hasWord(String t, List<String> words) {
  for (final m in RegExp(r'[a-z]+').allMatches(t.toLowerCase())) {
    if (words.contains(m.group(0))) return true;
  }
  return false;
}

bool _nameLike(String t) {
  final c = t.replaceFirst(
      RegExp(r'^(mr|mrs|ms|dr|er|ca|adv|prof|shri|smt)\.?\s+',
          caseSensitive: false),
      '');
  if (!RegExp(r"^[A-Za-z][A-Za-z.' ]+$").hasMatch(c)) return false;
  final n = c.trim().split(RegExp(r'\s+')).length;
  return n >= 2 && n <= 4;
}

Map<String, String> parseCard(RecognizedText rt) {
  final lines = <_L>[];
  var idx = 0;
  for (final b in rt.blocks) {
    for (final l in b.lines) {
      final t = l.text.trim();
      if (t.isNotEmpty) lines.add(_L(t, l.boundingBox.height, idx++));
    }
  }
  final text = lines.map((l) => l.t).join('\n');

  final emailRe = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
  final webRe = RegExp(r'(https?://|www\.)[^\s]+', caseSensitive: false);
  final phoneRe = RegExp(r'\+?\d[\d \-().]{7,}\d');
  final labelRe = RegExp(
      r'^(tel|ph|phone|mob|mobile|cell|fax|email|e-mail|web|website)\b',
      caseSensitive: false);

  final email = emailRe.firstMatch(text)?.group(0) ?? '';
  final web = webRe.firstMatch(text)?.group(0) ?? '';
  final phones = <String>[];
  for (final m in phoneRe.allMatches(text)) {
    final v = m.group(0)!.trim();
    final digits = v.replaceAll(RegExp(r'\D'), '').length;
    if (digits >= 8 && digits <= 15 && !phones.contains(v)) phones.add(v);
  }

  bool hasContact(String l) =>
      emailRe.hasMatch(l) ||
      webRe.hasMatch(l) ||
      l.toLowerCase().contains('www.') ||
      labelRe.hasMatch(l) ||
      phones.any((ph) => l.contains(ph));

  var desig = '';
  var company = '';
  var name = '';
  var title = '';
  final addr = <String>[];
  final rest = <_L>[];
  for (final l in lines) {
    final t = l.t;
    if (hasContact(t)) continue;
    final hasDigit = RegExp(r'\d').hasMatch(t);
    if (desig.isEmpty && !hasDigit && _hasWord(t, _desigWords)) {
      desig = t;
      continue;
    }
    if (company.isEmpty && _hasWord(t, _companyWords)) {
      company = t;
      continue;
    }
    if (hasDigit || _hasWord(t, _addrWords)) {
      addr.add(t.replaceFirst(
          RegExp(r'^(address|addr|add|office|off)\s*[:\-.]\s*',
              caseSensitive: false),
          ''));
      continue;
    }
    rest.add(l);
  }

  final di = desig.isEmpty ? -1 : lines.indexWhere((l) => l.t == desig);
  final cands = rest.where((l) => _nameLike(l.t)).toList();
  _L? nameLine;
  if (cands.isNotEmpty) {
    if (di >= 0) {
      cands.sort((a, b) => (a.i - di).abs().compareTo((b.i - di).abs()));
    }
    nameLine = cands.first;
  } else if (rest.isNotEmpty) {
    nameLine = rest.first;
  }
  if (nameLine != null) {
    name = nameLine.t;
    rest.remove(nameLine);
  }
  final tm = RegExp(r'^(mr|mrs)\.?\s+', caseSensitive: false).firstMatch(name);
  if (tm != null) {
    title = tm.group(1)!.toLowerCase() == 'mr' ? 'Mr.' : 'Mrs.';
    name = name.substring(tm.end).trim();
  }
  if (company.isEmpty && rest.isNotEmpty) {
    rest.sort((a, b) => b.h.compareTo(a.h));
    company = rest.first.t;
  }

  return {
    'title': title,
    'name': name,
    'company': company,
    'designation': desig,
    'phone': phones.join(', '),
    'email': email,
    'website': web,
    'address': addr.join(', '),
    'remark': '',
  };
}

// ---------- UI ----------
const _sortOpts = {
  'newest': 'Newest first',
  'name': 'Name A-Z',
  'company': 'Company A-Z',
  'work': 'Work A-Z',
};

class _Header {
  final String title;
  final int count;
  _Header(this.title, this.count);
}

class CardsPage extends StatefulWidget {
  const CardsPage({super.key});
  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _cards = [];
  List<Object> _rows = [];
  String _sort = 'newest';
  bool _autoOpening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Object> _buildRows(List<Map<String, Object?>> list) {
    final items = List<Map<String, Object?>>.from(list);
    if (_sort == 'name') {
      items.sort((a, b) => cmp(s(a['name']), s(b['name'])));
      return List<Object>.from(items);
    }
    if (_sort == 'company') {
      items.sort((a, b) => cmp(s(a['company']), s(b['company'])));
      return List<Object>.from(items);
    }
    if (_sort == 'work') {
      final groups = <String, List<Map<String, Object?>>>{};
      final titles = <String, String>{};
      for (final c in items) {
        var ws = decodeWorks(c['works']);
        if (ws.isEmpty) ws = ['No work'];
        final seen = <String>{};
        for (final w in ws) {
          final k = w.toLowerCase();
          if (!seen.add(k)) continue;
          titles.putIfAbsent(k, () => w);
          groups.putIfAbsent(k, () => []).add(c);
        }
      }
      final keys = groups.keys.toList()
        ..sort((a, b) {
          if (a == 'no work') return b == 'no work' ? 0 : 1;
          if (b == 'no work') return -1;
          return a.compareTo(b);
        });
      final rows = <Object>[];
      for (final k in keys) {
        final g = groups[k]!;
        g.sort((a, b) => cmp(s(a['company']), s(b['company'])));
        rows.add(_Header(titles[k]!, g.length));
        rows.addAll(g);
      }
      return rows;
    }
    return List<Object>.from(items);
  }

  Future<void> _load({bool autoOpenSingle = false}) async {
    final q = _search.text;
    final r = await Db.search(q);
    if (!mounted || q != _search.text) return;
    setState(() {
      _cards = r;
      _rows = _buildRows(r);
    });
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
      builder: (_) => EditDialog(fields: parseCard(res)),
    );
    if (data == null) return;
    await Db.insert({
      ...data.fields,
      'works': jsonEncode(data.works),
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
      'works': jsonEncode(data.works),
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

  Future<void> _details(Map<String, Object?> card) async {
    var c = Map<String, Object?>.from(card);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final works = decodeWorks(c['works']);
          final img = s(c['image']);
          final hasImg = img.isNotEmpty && File(img).existsSync();
          final nm = fullName(c);
          final lines = <String>[];
          if (nm.isNotEmpty) lines.add('Name: $nm');
          for (final k in EditDialog.fieldOrder) {
            if (k == 'name') continue;
            if (k == 'remark' && works.isNotEmpty) {
              lines.add('Work: ${works.join(', ')}');
            }
            final v = s(c[k]);
            if (v.isNotEmpty) lines.add('${EditDialog.fieldLabels[k]}: $v');
          }
          return AlertDialog(
            title: Text(nm.isEmpty ? 'Card' : nm),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasImg)
                    GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ZoomPage(img))),
                      child: Image.file(File(img),
                          width: double.maxFinite, fit: BoxFit.contain),
                    ),
                  if (hasImg)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Tap image to zoom',
                          style:
                              TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                  const SizedBox(height: 8),
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(l),
                    ),
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
                      fields: {
                        for (final k in EditDialog.fieldOrder) k: s(c[k]),
                        'title': s(c['title']),
                      },
                      works: works,
                      title: 'Edit card',
                    ),
                  );
                  if (result == null) return;
                  final updated = {
                    ...result.fields,
                    'works': jsonEncode(result.works),
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
    final nm = fullName(c);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text(
            'Delete "${nm.isEmpty ? 'this card' : nm}"? This cannot be undone.'),
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

  Widget _header(_Header h) => Container(
        width: double.infinity,
        color: Colors.grey.shade200,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('${h.title}  (${h.count})',
            style: const TextStyle(fontSize: 15)),
      );

  Widget _tile(Map<String, Object?> c) {
    final company = s(c['company']);
    final nm = fullName(c);
    final ph = s(c['phone']);
    final line2 = nm.isEmpty ? ph : (ph.isEmpty ? nm : '$nm - $ph');
    return Column(children: [
      InkWell(
        onTap: () => _details(c),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(company.isEmpty ? '(no company)' : company,
                  style: const TextStyle(fontSize: 16)),
              if (line2.isNotEmpty)
                Text(line2,
                    style:
                        const TextStyle(fontSize: 14, color: Colors.black54)),
            ],
          ),
        ),
      ),
      const Divider(height: 1),
    ]);
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
              onSelected: (v) {
                _sort = v;
                setState(() => _rows = _buildRows(_cards));
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                for (final e in _sortOpts.entries)
                  CheckedPopupMenuItem<String>(
                    value: e.key,
                    checked: _sort == e.key,
                    child: Text(e.value),
                  ),
              ],
            ),
          ],
        ),
        body: ListView.builder(
          itemCount: _rows.length,
          itemBuilder: (_, i) {
            final r = _rows[i];
            if (r is _Header) return _header(r);
            return _tile(r as Map<String, Object?>);
          },
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add card',
          onPressed: _pickSource,
          child: const Icon(Icons.add),
        ),
      );
}

class ZoomPage extends StatelessWidget {
  final String path;
  const ZoomPage(this.path, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 8,
            child: Image.file(File(path)),
          ),
        ),
      );
}

class CardEditResult {
  final Map<String, String> fields;
  final List<String> works;
  const CardEditResult(this.fields, this.works);
}

class EditDialog extends StatefulWidget {
  static const fieldOrder = [
    'name',
    'company',
    'designation',
    'phone',
    'email',
    'website',
    'address',
    'remark',
  ];
  static const fieldLabels = {
    'name': 'Name',
    'company': 'Company',
    'designation': 'Designation',
    'phone': 'Phone',
    'email': 'Email',
    'website': 'Website',
    'address': 'Address',
    'remark': 'Remark',
  };

  final Map<String, String> fields;
  final List<String> works;
  final String title;
  const EditDialog({
    super.key,
    required this.fields,
    this.works = const [],
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
  late final List<TextEditingController> _works = [
    for (final w in widget.works) TextEditingController(text: w),
    if (widget.works.isEmpty) TextEditingController(),
  ];
  late String _title = (widget.fields['title'] == 'Mr.' ||
          widget.fields['title'] == 'Mrs.')
      ? widget.fields['title']!
      : '';

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final c in _works) {
      c.dispose();
    }
    super.dispose();
  }

  CardEditResult _result() {
    final seen = <String>{};
    final ws = <String>[];
    for (final c in _works) {
      final t = c.text.trim();
      if (t.isNotEmpty && seen.add(t.toLowerCase())) ws.add(t);
    }
    return CardEditResult(
      {
        'title': _title,
        for (final e in _fields.entries) e.key: e.value.text.trim(),
      },
      ws,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Title'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _title,
                    isDense: true,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: '', child: Text('-')),
                      DropdownMenuItem(value: 'Mr.', child: Text('Mr.')),
                      DropdownMenuItem(value: 'Mrs.', child: Text('Mrs.')),
                    ],
                    onChanged: (v) => setState(() => _title = v ?? ''),
                  ),
                ),
              ),
              for (final e in _fields.entries)
                if (e.key != 'remark')
                  TextField(
                    controller: e.value,
                    decoration: InputDecoration(
                        labelText: EditDialog.fieldLabels[e.key]),
                  ),
              const SizedBox(height: 12),
              const Text('Work'),
              for (var i = 0; i < _works.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _works[i],
                        decoration:
                            InputDecoration(labelText: 'Work ${i + 1}'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () {
                        setState(() {
                          _works.removeAt(i).dispose();
                        });
                      },
                    ),
                  ],
                ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _works.add(TextEditingController())),
                icon: const Icon(Icons.add),
                label: const Text('Add work'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _fields['remark'],
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(labelText: 'Remark'),
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
