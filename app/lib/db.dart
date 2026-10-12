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

  /// Local write; marked dirty so the next sync pushes it.
  static Future<Json> put(String kind, Json data, {bool deleted = false}) async {
    data['id'] ??= uuid.v4();
    await _db.rawInsert(_insert, _cols(kind, data, nowMs(), deleted, true));
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

  /// Docs from the server: last-write-wins on updated_at.
  static Future<void> applyRemote(List docs) async {
    final b = _db.batch();
    for (final doc in docs) {
      final d = Map<String, dynamic>.from(doc['data'] as Map)..['id'] = doc['id'];
      b.rawInsert('''${_insert.replaceFirst('OR REPLACE ', '')}
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, data=excluded.data, updated_at=excluded.updated_at,
          deleted=excluded.deleted, dirty=0, due=excluded.due, certs=excluded.certs, card_id=excluded.card_id, ts=excluded.ts
        WHERE excluded.updated_at > docs.updated_at''', _cols(doc['kind'], d, doc['updated_at'], doc['deleted'] == true, false));
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

  static Future<String?> meta(String key) async {
    final r = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  static Future<void> setMeta(String key, String value) =>
      _db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- media: content-addressed files (sha256.ext) ----
  static File mediaFile(String name) => File(p.join(mediaDir, name));

  static Future<String> saveMedia(List<int> bytes, String ext, {bool uploaded = false}) async {
    final name = '${sha256.convert(bytes)}.${ext.toLowerCase().replaceAll('jpeg', 'jpg')}';
    final f = mediaFile(name);
    if (!await f.exists()) await f.writeAsBytes(bytes, flush: true);
    await _db.insert('media', {'name': name, 'uploaded': uploaded ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
    return name;
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
