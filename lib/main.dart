import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

void main() =>
    runApp(const MaterialApp(title: 'Visiting Card Holder', home: CardsPage()));

// ---------- Helpers ----------
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

String co(Map<String, Object?> c) {
  final n = s(c['company']);
  final ct = s(c['city']);
  return (n.isEmpty ? '(no company)' : n) + (ct.isEmpty ? '' : ', $ct');
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

List<String> workKeys(Map<String, Object?> c) {
  final w = decodeWorks(c['works']);
  if (w.isEmpty) return ['no work'];
  return w.map((e) => e.toLowerCase()).toList();
}

String haystack(Map<String, Object?> c) => [
      s(c['title']),
      s(c['name']),
      s(c['company']),
      s(c['city']),
      s(c['designation']),
      s(c['phone']),
      s(c['email']),
      s(c['website']),
      s(c['address']),
      decodeWorks(c['works']).join(' '),
      s(c['remark']),
      s(c['raw']),
    ].join(' ').toLowerCase();

// ---------- Database ----------
class Db {
  static Database? _db;

  static Future<Database> get db async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'cards.db'),
        version: 5,
        onCreate: (d, v) => d.execute('''CREATE TABLE cards(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT, name TEXT, company TEXT, city TEXT, designation TEXT,
          phone TEXT, email TEXT, website TEXT, address TEXT, works TEXT,
          remark TEXT, extra TEXT, raw TEXT, image TEXT, back_image TEXT)'''),
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
          if (oldV < 5) {
            await d.execute('ALTER TABLE cards ADD COLUMN city TEXT');
            await d.execute('ALTER TABLE cards ADD COLUMN back_image TEXT');
          }
        },
      );

  static Future<List<Map<String, Object?>>> all() async =>
      (await db).query('cards', orderBy: 'id DESC');

  static Future<Map<String, Object?>?> get(int id) async {
    final r = await (await db).query('cards', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  static Future<int> insert(Map<String, Object?> m) async =>
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

  final addrText = addr.join(', ');
  var city = '';
  final cm =
      RegExp(r'([A-Za-z][A-Za-z ]{2,}?)[\s,\-.]*\d{6}').firstMatch(addrText);
  if (cm != null) city = cm.group(1)!.trim();

  return {
    'title': title,
    'name': name,
    'company': company,
    'city': city,
    'designation': desig,
    'phone': phones.join(', '),
    'email': email,
    'website': web,
    'address': addrText,
    'remark': '',
  };
}

// ---------- Back side scan ----------
Future<String?> scanBackSide(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Scan back side?'),
      content: const Text(
          'The app needs permission to use the camera. Only a picture of the back side is saved. No details are read from it.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow and scan')),
      ],
    ),
  );
  if (ok != true) return null;
  final x = await ImagePicker().pickImage(source: ImageSource.camera);
  if (x == null) return null;
  final dir = await getApplicationDocumentsDirectory();
  final saved = await File(x.path).copy(
      p.join(dir.path, 'back_${DateTime.now().millisecondsSinceEpoch}.jpg'));
  return saved.path;
}

// ---------- Main page ----------
class CardTile extends StatelessWidget {
  final Map<String, Object?> card;
  final VoidCallback onTap;
  const CardTile({super.key, required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nm = fullName(card);
    final ph = s(card['phone']);
    final line2 = nm.isEmpty ? ph : (ph.isEmpty ? nm : '$nm - $ph');
    final hasBack = s(card['back_image']).isNotEmpty;
    return Column(children: [
      InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                    child: Text(co(card), style: const TextStyle(fontSize: 16))),
                if (hasBack)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('B',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ),
              ]),
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
}

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

  Future<void> _load() async {
    final r = await Db.all();
    if (mounted) setState(() => _cards = r);
  }

  Future<void> _openCard(Map<String, Object?> c) async {
    FocusScope.of(context).unfocus();
    _search.clear();
    setState(() {});
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => DetailPage(c['id'] as int)));
    _load();
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
    final works = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const WorkDialog(),
    );
    if (works == null || !mounted) return;
    final data = await showDialog<CardEditResult>(
      context: context,
      builder: (_) => EditDialog(fields: parseCard(res), works: works),
    );
    if (data == null) return;
    final id = await Db.insert({
      ...data.fields,
      'works': jsonEncode(data.works),
      'raw': res.text,
      'image': saved.path,
    });
    await _load();
    if (!mounted) return;
    final back = await scanBackSide(context);
    if (back != null) {
      await Db.update(id, {'back_image': back});
      await _load();
    }
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

  List<MapEntry<String, int>> _workHeads() {
    final titles = <String, String>{};
    final counts = <String, int>{};
    for (final c in _cards) {
      final ws = decodeWorks(c['works']);
      final list = ws.isEmpty ? ['No work'] : ws;
      final seen = <String>{};
      for (final w in list) {
        final k = w.toLowerCase();
        if (!seen.add(k)) continue;
        titles.putIfAbsent(k, () => w);
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final keys = titles.keys.toList()
      ..sort((a, b) {
        if (a == 'no work') return b == 'no work' ? 0 : 1;
        if (b == 'no work') return -1;
        return a.compareTo(b);
      });
    return [for (final k in keys) MapEntry(titles[k]!, counts[k]!)];
  }

  Widget _body() {
    if (_cards.isEmpty) {
      return const Center(child: Text('No cards yet. Tap + to add.'));
    }
    if (_sort == 'work') {
      final heads = _workHeads();
      return ListView.builder(
        itemCount: heads.length,
        itemBuilder: (_, i) {
          final h = heads[i];
          return Column(children: [
            ListTile(
              title: Text('${h.key} (${h.value})',
                  style: const TextStyle(fontSize: 16)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => WorkPage(h.key)));
                _load();
              },
            ),
            const Divider(height: 1),
          ]);
        },
      );
    }
    final items = List<Map<String, Object?>>.from(_cards);
    if (_sort == 'company') {
      items.sort((a, b) => cmp(s(a['company']), s(b['company'])));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) =>
          CardTile(card: items[i], onTap: () => _openCard(items[i])),
    );
  }

  Widget _popup() {
    final tokens = _search.text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return const SizedBox.shrink();
    final m = _cards.where((c) {
      final h = haystack(c);
      return tokens.every((t) => h.contains(t));
    }).toList();
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6),
        child: m.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16), child: Text('No result'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: m.length,
                itemBuilder: (_, i) =>
                    CardTile(card: m[i], onTap: () => _openCard(m[i])),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                hintText: 'Search name, company, city, work...',
                border: InputBorder.none),
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort',
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                CheckedPopupMenuItem<String>(
                  value: 'newest',
                  checked: _sort == 'newest',
                  child: const Text('Newest first'),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'company',
                  checked: _sort == 'company',
                  child: const Text('Company A-Z'),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'work',
                  checked: _sort == 'work',
                  child: const Text('Work A-Z'),
                ),
              ],
            ),
          ],
        ),
        body: Stack(children: [
          _body(),
          
Positioned(left: 8, right: 8, top: 4, child: _popup()),
        ]),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add card',
          onPressed: _pickSource,
          child: const Icon(Icons.add),
        ),
      );
}

// ---------- Companies under one work ----------
class WorkPage extends StatefulWidget {
  final String work;
  const WorkPage(this.work, {super.key});
  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  List<Map<String, Object?>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Db.all();
    final k = widget.work.toLowerCase();
    final items = all.where((c) => workKeys(c).contains(k)).toList();
    items.sort((a, b) => cmp(s(a['company']), s(b['company'])));
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('${widget.work} (${_items.length})')),
        body: ListView.builder(
          itemCount: _items.length,
          itemBuilder: (_, i) => CardTile(
            card: _items[i],
            onTap: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => DetailPage(_items[i]['id'] as int)));
              _load();
            },
          ),
        ),
      );
}

// ---------- Full details ----------
class DetailPage extends StatefulWidget {
  final int id;
  const DetailPage(this.id, {super.key});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, Object?>? _c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.get(widget.id);
    if (mounted) setState(() => _c = r);
  }

  void _msg(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _google(Map<String, Object?> c) async {
    final qy = [s(c['company']), s(c['city'])].where((e) => e.isNotEmpty).join(' ');
    if (qy.isEmpty) return;
    final uri = Uri.parse(
        'https://www.google.com/search?q=${Uri.encodeQueryComponent(qy)}');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _msg('Could not open the browser');
    } catch (_) {
      if (mounted) _msg('Could not open the browser');
    }
  }

  Future<void> _share(Map<String, Object?> c, List<String> works) async {
    final t = <String>[co(c)];
    final nm = fullName(c);
    if (nm.isNotEmpty) {
      t.add(s(c['designation']).isEmpty ? nm : '$nm (${s(c['designation'])})');
    }
    const labels = {
      'phone': 'Phone',
      'email': 'Email',
      'website': 'Website',
      'address': 'Address',
    };
    for (final e in labels.entries) {
      final v = s(c[e.key]);
      if (v.isNotEmpty) t.add('${e.value}: $v');
    }
    if (works.isNotEmpty) t.add('Work: ${works.join(', ')}');
    if (s(c['remark']).isNotEmpty) t.add('Remark: ${s(c['remark'])}');
    final files = <XFile>[];
    for (final k in ['image', 'back_image']) {
      final pth = s(c[k]);
      if (pth.isNotEmpty && File(pth).existsSync()) files.add(XFile(pth));
    }
    try {
      if (files.isEmpty) {
        await Share.share(t.join('\n'));
      } else {
        await Share.shareXFiles(files, text: t.join('\n'));
      }
    } catch (_) {
      if (mounted) _msg('Could not share');
    }
  }

  Future<void> _addBack() async {
    final path = await scanBackSide(context);
    if (path == null) return;
    await Db.update(widget.id, {'back_image': path});
    _load();
  }

  Future<void> _edit(Map<String, Object?> c, List<String> works) async {
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
    await Db.update(
        widget.id, {...result.fields, 'works': jsonEncode(result.works)});
    _load();
  }

  Future<void> _delete(Map<String, Object?> c) async {
    final nm = fullName(c);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text(
            'Delete "${nm.isEmpty ? co(c) : nm}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    for (final k in ['image', 'back_image']) {
      final pth = s(c[k]);
      if (pth.isNotEmpty) {
        try {
          File(pth).deleteSync();
        } catch (_) {}
      }
    }
    await Db.delete(widget.id);
    if (mounted) Navigator.pop(context);
  }

  Widget _img(String path) => GestureDetector(
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => ZoomPage(path))),
        child: Image.file(File(path),
            width: double.infinity, fit: BoxFit.contain),
      );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final works = decodeWorks(c['works']);
    final front = s(c['image']);
    final back = s(c['back_image']);
    final hasFront = front.isNotEmpty && File(front).existsSync();
    final hasBack = back.isNotEmpty && File(back).existsSync();
    final lines = <String>[];
    final nm = fullName(c);
    if (nm.isNotEmpty) lines.add('Name: $nm');
    const fields = {
      'designation': 'Designation',
      'phone': 'Phone',
      'email': 'Email',
      'website': 'Website',
      'address': 'Address',
    };
    for (final e in fields.entries) {
      final v = s(c[e.key]);
      if (v.isNotEmpty) lines.add('${e.value}: $v');
    }
    if (works.isNotEmpty) lines.add('Work: ${works.join(', ')}');
    if (s(c['remark']).isNotEmpty) lines.add('Remark: ${s(c['remark'])}');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Company details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: () => _share(c, works),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (hasFront) _img(front),
          if (hasFront)
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 8),
              child: Text('Tap image to zoom',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          if (hasBack) ...[
            _img(back),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Back side (scanned copy only)',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: _addBack, child: const Text('Retake back side')),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                  onPressed: _addBack, child: const Text('Add back side')),
            ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _google(c),
            child: Text(co(c),
                style: const TextStyle(
                    fontSize: 17, decoration: TextDecoration.underline)),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 8),
            child: Text('Tap the company name to search on Google',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(l, style: const TextStyle(fontSize: 15)),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () => _delete(c), child: const Text('Delete')),
              TextButton(
                  onPressed: () => _edit(c, works),
                  child: const Text('Edit')),
            ],
          ),
        ],
      ),
    );
  }
}

class ZoomPage extends StatelessWidget {
