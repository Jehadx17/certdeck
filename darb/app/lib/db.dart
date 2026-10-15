import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;

const uuid = Uuid();
int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Bumped on every local write so screens can rebuild.
final changes = ValueNotifier<int>(0);

/// Everything is a sync document {id, kind, data, updated_at, deleted} (docs/PROTOCOL.md).
/// A few columns are denormalized from `data` so card/review queries stay cheap.
class Db {
  static late Database _db;
  static late String mediaDir;

  /// [dir] overrides the app directories (used by the sync integration test).
  static Future<void> open({String? dir}) async {
    mediaDir = p.join(dir ?? (await getApplicationDocumentsDirectory()).path, 'media');
    await Directory(mediaDir).create(recursive: true);
    _db = await openDatabase(p.join(dir ?? await getDatabasesPath(), 'certdeck.db'), version: 1, onCreate: (db, _) async {
      await db.execute('''CREATE TABLE docs(id TEXT PRIMARY KEY, kind TEXT NOT NULL, data TEXT NOT NULL,
        updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0,
        due INTEGER, certs TEXT, card_id TEXT, ts INTEGER)''');
      await db.execute('CREATE INDEX docs_kind ON docs(kind, deleted)');
      await db.execute('CREATE INDEX docs_card ON docs(card_id)');
      await db.execute('CREATE INDEX docs_ts ON docs(kind, ts)');
      await db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
      await db.execute('CREATE TABLE media(name TEXT PRIMARY KEY, uploaded INTEGER NOT NULL DEFAULT 0)');
    });
  }

  static List<Object?> _cols(String kind, Json d, int updatedAt, bool deleted, bool dirty) {
    final f = d['fsrs'];
    return [
      d['id'],
      kind,
      jsonEncode(d),
      updatedAt,
      deleted ? 1 : 0,
      dirty ? 1 : 0,
      kind == 'card' && f is Map ? f['due'] : null,
      kind == 'card' ? ',${((d['certs'] as Map?) ?? {}).keys.join(',')},' : null,
      d['card_id'],
      d['ts'],
    ];
  }

  static const _insert = 'INSERT OR REPLACE INTO docs(id,kind,data,updated_at,deleted,dirty,due,certs,card_id,ts) VALUES(?,?,?,?,?,?,?,?,?,?)';

  /// Local write; marked dirty so the next sync pushes it. Pack cards never sync (their content comes from the pack,
  /// their schedule is rebuilt from the review log), so they are written clean.
  static Future<Json> put(String kind, Json data, {bool deleted = false}) async {
    data['id'] ??= uuid.v4();
    await _db.rawInsert(_insert, _cols(kind, data, nowMs(), deleted, data['pack'] == null));
    changes.value++;
    return data;
  }

  static Future<void> putAll(String kind, List<Json> items, {bool dirty = true}) async {
    final b = _db.batch();
    final t = nowMs();
    for (final d in items) {
      d['id'] ??= uuid.v4();
      b.rawInsert(_insert, _cols(kind, d, t, false, dirty));
    }
    await b.commit(noResult: true);
    changes.value++;
  }

  /// Insert-if-missing with updated_at 0, so anything from the server wins.
  static Future<void> seed(String kind, Json data) =>
      _db.rawInsert(_insert.replaceFirst('OR REPLACE', 'OR IGNORE'), _cols(kind, data, 0, false, false));

  /// Docs from the server: last-write-wins on updated_at. Insert-if-missing, then update-if-newer: no UPSERT
  /// syntax, which needs SQLite 3.24 (Android 7 ships 3.9).
  static Future<void> applyRemote(List docs) async {
    final b = _db.batch();
    for (final doc in docs) {
      final d = Map<String, dynamic>.from(doc['data'] as Map)..['id'] = doc['id'];
      final c = _cols(doc['kind'], d, doc['updated_at'], doc['deleted'] == true, false);
      b.rawInsert(_insert.replaceFirst('OR REPLACE', 'OR IGNORE'), c);
      b.rawUpdate('UPDATE docs SET kind=?, data=?, updated_at=?, deleted=?, dirty=0, due=?, certs=?, card_id=?, ts=? '
          'WHERE id = ? AND updated_at < ?', [c[1], c[2], c[3], c[4], c[6], c[7], c[8], c[9], c[0], c[3]]);
    }
    await b.commit(noResult: true);
    if (docs.isNotEmpty) changes.value++;
  }

  static Future<List<Json>> dirtyDocs() async {
    final rows = await _db.query('docs', where: 'dirty = 1', limit: 500);
    return [
      for (final r in rows)
        {'id': r['id'], 'kind': r['kind'], 'data': jsonDecode(r['data'] as String), 'updated_at': r['updated_at'], 'deleted': r['deleted'] == 1}
    ];
  }

  /// Only clears docs not modified again while the request was in flight.
  static Future<void> markClean(List<Json> docs) async {
    final b = _db.batch();
    for (final d in docs) {
      b.update('docs', {'dirty': 0}, where: 'id = ? AND updated_at = ?', whereArgs: [d['id'], d['updated_at']]);
    }
    await b.commit(noResult: true);
  }

  static Json _decode(Map r) => (jsonDecode(r['data'] as String) as Json)..['id'] = r['id'];

  static Future<List<Json>> query(String kind, {String? where, List<Object?>? args, String? orderBy, int? limit}) async {
    final w = ['kind = ?', 'deleted = 0', if (where != null) '($where)'].join(' AND ');
    final rows = await _db.query('docs', columns: ['id', 'data'], where: w, whereArgs: [kind, ...?args], orderBy: orderBy, limit: limit);
    return rows.map(_decode).toList();
  }

  static Future<Json?> get(String id) async {
    final rows = await _db.query('docs', columns: ['id', 'data'], where: 'id = ? AND deleted = 0', whereArgs: [id]);
    return rows.isEmpty ? null : _decode(rows.first);
  }

  static Future<List<Json>> cardsFor(String cert) => query('card', where: 'certs LIKE ?', args: ['%,$cert,%']);
  static Future<List<Json>> reviewsFor(String cardId) => query('review', where: 'card_id = ?', args: [cardId], orderBy: 'ts DESC');
  static Future<List<Json>> reviewsSince(int ts) => query('review', where: 'ts >= ?', args: [ts]);
  static Future<int> dirtyCount() async => Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM docs WHERE dirty = 1')) ?? 0;

  /// Removes a pack's cards (ids are "<slug>:<n>"): before a new version is imported, or when a subscription lapsed
  /// (the free sample is then imported again). No JSON functions: Android 7's SQLite may not have them.
  static Future<void> deletePack(String slug) async {
    await _db.delete('docs', where: "kind = 'card' AND id LIKE ?", whereArgs: ['$slug:%']);
    changes.value++;
  }

  /// Forget everything local (another account signs in on this phone): docs, cursor, settings, images.
  static Future<void> wipe() async {
    await _db.delete('docs');
    await _db.delete('meta');
    await _db.delete('media');
    final dir = Directory(mediaDir);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        await f.delete(recursive: true);
      }
    }
    changes.value++;
  }

  static Future<String?> meta(String key) async {
    final r = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  static Future<void> setMeta(String key, String value) =>
      _db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- media: content-addressed files (sha256.ext) ----
  static File mediaFile(String name) => File(p.join(mediaDir, name));

  /// Stores image bytes as `sha256.ext`; ext comes from the file's magic bytes (the server
  /// accepts png/jpg/gif/webp only). Throws FormatException for anything else.
  static Future<String> saveMedia(List<int> bytes) async {
    final name = '${sha256.convert(bytes)}.${imageExt(bytes)}';
    final f = mediaFile(name);
    if (!await f.exists()) await f.writeAsBytes(bytes, flush: true);
    await _db.insert('media', {'name': name, 'uploaded': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
    return name;
  }

  static String imageExt(List<int> b) {
    bool starts(List<int> sig, [int at = 0]) => b.length >= at + sig.length && List.generate(sig.length, (i) => b[at + i]).join() == sig.join();
    if (starts([0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
    if (starts([0x47, 0x49, 0x46])) return 'gif';
    if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
    throw const FormatException('Unsupported image format (use PNG, JPEG, GIF or WebP)');
  }

  static Future<List<String>> pendingMedia() async => (await _db.query('media', where: 'uploaded = 0')).map((r) => r['name'] as String).toList();

  static Future<void> markMediaUploaded(String name) => _db.update('media', {'uploaded': 1}, where: 'name = ?', whereArgs: [name]);
}

/// Media names referenced by a card.
Iterable<String> cardMedia(Json c) => [
      if (c['image'] is String) c['image'] as String,
      ...((c['question_images'] as List?) ?? []).cast<String>(),
      ...((c['answer_images'] as List?) ?? []).cast<String>(),
    ];
