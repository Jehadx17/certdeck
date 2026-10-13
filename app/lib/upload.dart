import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'db.dart';

/// Course material uploads: the material doc syncs first, then each file goes up in 4 MB chunks to
/// PUT upload/<material>/<n>?offset=<what the server has>, so a dropped connection or a closed app resumes
/// where it stopped. When every file is up, college/process starts the server-side work.
/// Files are copied into the app's own folder first (picker paths are temporary) and deleted once processed.
class Uploads {
  static const _chunk = 4 * 1024 * 1024;

  /// material id -> 0..1 while uploading; the material screen shows it.
  static final progress = ValueNotifier<Map<String, double>>({});
  static final errors = ValueNotifier<Map<String, String>>({});
  static bool _running = false;

  static Future<Directory> _dir(String materialId) async =>
      Directory(p.join((await getApplicationDocumentsDirectory()).path, 'uploads', materialId)).create(recursive: true);

  /// Creates the material and queues its files. [files] are paths the picker gave us.
  static Future<Json> add({required String courseId, required String kind, required String title, required List<String> files}) async {
    final id = uuid.v4();
    final dir = await _dir(id);
    final kept = <Json>[];
    for (final (i, f) in files.indexed) {
      final dest = p.join(dir.path, '$i${p.extension(f)}');
      await File(f).copy(dest);
      kept.add({'name': p.basename(f), 'size': await File(dest).length(), 'path': dest});
    }
    final m = await Db.put('material', {
      'id': id,
      'course_id': courseId,
      'kind': kind,
      'title': title,
      'files': [for (final f in kept) {'name': f['name'], 'size': f['size']}],
      'created_at': nowMs(),
    });
    final pending = await _pending();
    pending[id] = [for (final f in kept) f['path'] as String];
    await Db.setMeta('uploads', jsonEncode(pending));
    run().ignore();
    return m;
  }

  static Future<Map<String, List<String>>> _pending() async {
    final raw = await Db.meta('uploads');
    if (raw == null) return {};
    return {for (final e in (jsonDecode(raw) as Map).entries) e.key as String: (e.value as List).cast<String>()};
  }

  static bool pending(String materialId) => progress.value.containsKey(materialId);

  /// Uploads whatever is pending (on app open, after adding material, and on resume). Safe to call repeatedly.
  static Future<void> run() async {
    if (_running || !Api.configured) return;
    _running = true;
    try {
      final pending = await _pending();
      progress.value = {for (final id in pending.keys) id: progress.value[id] ?? 0};
      if (pending.isNotEmpty) await Api.sync(); // the server must know the material before its files
      for (final MapEntry(key: id, value: paths) in pending.entries) {
        try {
          await _one(id, paths);
          pending.remove(id);
          await Db.setMeta('uploads', jsonEncode(pending));
          await (await _dir(id)).delete(recursive: true);
          errors.value = {...errors.value}..remove(id);
        } on ApiError catch (e) {
          errors.value = {...errors.value, id: e.message};
          if (e.offline) break; // try again when online
          if (!e.message.contains('Needs connection')) {
            pending.remove(id); // the server refused this material (type, size): don't retry forever
            await Db.setMeta('uploads', jsonEncode(pending));
          }
        } on FileSystemException {
          pending.remove(id); // the copied file is gone (app data cleared): nothing to resume
          await Db.setMeta('uploads', jsonEncode(pending));
          errors.value = {...errors.value, id: 'File missing, add it again'};
        }
        progress.value = {...progress.value}..remove(id);
      }
      await Api.sync();
    } finally {
      _running = false;
    }
  }

  static Future<void> _one(String id, List<String> paths) async {
    final total = await Future.wait(paths.map((f) => File(f).length())).then((l) => l.fold<int>(0, (a, b) => a + b));
    var before = 0;
    for (final (n, path) in paths.indexed) {
      final file = File(path);
      final size = await file.length();
      final status = await Api.call('GET', 'upload/$id/$n');
      if (status['done'] != true) {
        var offset = status['size'] as int;
        final raf = await file.open();
        try {
          while (offset < size) {
            await raf.setPosition(offset);
            final chunk = await raf.read(_chunk);
            offset = await _put(id, n, offset, chunk);
            progress.value = {...progress.value, id: (before + offset) / total};
          }
        } finally {
          await raf.close();
        }
        await Api.call('POST', 'upload/$id/$n/done', body: {'sha256': (await sha256.bind(file.openRead()).first).toString()});
      }
      before += size;
    }
    await Api.call('POST', 'college/process', body: {'material_id': id});
  }

  /// One chunk; a 409 means the server has a different offset (a retry after a lost response), so continue there.
  static Future<int> _put(String id, int n, int offset, List<int> chunk) async {
    final uri = Uri.parse('${Api.url}/api/upload/$id/$n?offset=$offset');
    final http.Response r;
    try {
      r = await http.put(uri, headers: {'Authorization': 'Bearer ${Api.token}'}, body: chunk).timeout(const Duration(minutes: 2));
    } on SocketException {
      throw ApiError('Needs connection', offline: true);
    } on TimeoutException {
      throw ApiError('Needs connection (timed out)', offline: true);
    } on http.ClientException {
      throw ApiError('Needs connection', offline: true);
    }
    if (r.statusCode == 409) return (await Api.call('GET', 'upload/$id/$n'))['size'] as int;
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) throw ApiError(body['error']?.toString() ?? 'HTTP ${r.statusCode}');
    return body['size'] as int;
  }
}
