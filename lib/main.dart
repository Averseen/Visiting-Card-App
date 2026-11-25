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
        version: 1,
        onCreate: (d, v) => d.execute('''CREATE TABLE cards(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT, company TEXT, phone TEXT, email TEXT,
          website TEXT, address TEXT, raw TEXT, image TEXT)'''),
      );

  static Future<List<Map<String, Object?>>> search(String q) async {
    final d = await db;
    q = q.trim();
    if (q.isEmpty) return d.query('cards', orderBy: 'id DESC');
    return d.query(
      'cards',
      where: 'name LIKE ? OR company LIKE ? OR phone LIKE ? OR email LIKE ? '
          'OR website LIKE ? OR address LIKE ? OR raw LIKE ?',
      whereArgs: List.filled(7, '%$q%'),
      orderBy: 'id DESC',
    );
  }

  static Future<void> insert(Map<String, Object?> m) async =>
      (await db).insert('cards', m);

  static Future<void> delete(int id) async =>
      (await db).delete('cards', where: 'id = ?', whereArgs: [id]);
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.search(_search.text);
    if (mounted) setState(() => _cards = r);
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
    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => EditDialog(parseCard(res.text)),
    );
    if (data == null) return;
    await Db.insert({...data, 'raw': res.text, 'image': saved.path});
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
          ]),
        ),
      );

  void _details(Map<String, Object?> c) => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${c['name']}'),
          content: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (c['image'] != null) Image.file(File('${c['image']}')),
              const SizedBox(height: 8),
              Text('Company: ${c['company']}'),
              Text('Phone: ${c['phone']}'),
              Text('Email: ${c['email']}'),
              Text('Website: ${c['website']}'),
              Text('Address: ${c['address']}'),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Db.delete(c['id'] as int);
                if (context.mounted) Navigator.pop(context);
                _load();
              },
              child: const Text('Delete'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _search,
            onChanged: (_) => _load(),
            decoration: const InputDecoration(
                hintText: 'Search cards...', border: InputBorder.none),
          ),
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
          onPressed: _pickSource,
          child: const Icon(Icons.add_a_photo),
        ),
      );
}

class EditDialog extends StatefulWidget {
  final Map<String, String> data;
  const EditDialog(this.data, {super.key});
  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  late final Map<String, TextEditingController> _c = {
    for (final e in widget.data.entries) e.key: TextEditingController(text: e.value)
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Verify details'),
        content: SingleChildScrollView(
          child: Column(children: [
            for (final e in _c.entries)
              TextField(
                  controller: e.value,
                  decoration: InputDecoration(labelText: e.key)),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(
                context, {for (final e in _c.entries) e.key: e.value.text}),
            child: const Text('Save'),
          ),
        ],
      );
}
