import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'db.dart';
import 'logic.dart';

class ApiError implements Exception {
  final String message;
  final bool offline;
  ApiError(this.message, {this.offline = false});
  @override
  String toString() => message;
}

class Api {
  static const _store = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const defaultUrl = 'https://certdeck.mithaqstay.com';
  static String url = defaultUrl;
  static String? token;
  static final online = ValueNotifier<bool?>(null);
  static final syncing = ValueNotifier<bool>(false);
  static final lastSync = ValueNotifier<String>('never');
  static Timer? _timer;

  static bool get configured => (token ?? '').isNotEmpty;

  static Future<void> load() async {
    token = await _store.read(key: 'token');
    url = await _store.read(key: 'url') ?? defaultUrl;
    lastSync.value = await Db.meta('last_sync') ?? 'never';
    // Push local changes, and pull background generations as soon as they finish.
    _timer ??= Timer.periodic(const Duration(minutes: 2), (_) async {
      if (await Db.dirtyCount() > 0 || await hasQueuedJobs()) sync().ignore();
    });
  }

  static Future<void> configure(String newUrl, String newToken) async {
    url = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    token = newToken.trim();
    await _store.write(key: 'url', value: url);
    await _store.write(key: 'token', value: token);
  }

  static Future<dynamic> call(String method, String path, {Object? body, List<int>? bytes, Duration timeout = const Duration(seconds: 60)}) async {
    if (!configured) throw ApiError('Needs connection: add your server token in Settings', offline: true);
    final uri = Uri.parse('$url/api/$path');
    final headers = {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json'};
    final http.Response r;
    try {
      r = await (switch (method) {
        'GET' => http.get(uri, headers: headers),
        'PUT' => http.put(uri, headers: headers, body: bytes),
        _ => http.post(uri, headers: headers, body: jsonEncode(body)),
      })
          .timeout(timeout);
    } on SocketException {
      online.value = false;
      throw ApiError('Needs connection', offline: true);
    } on TimeoutException {
      online.value = false;
      throw ApiError('Needs connection (timed out)', offline: true);
    } on http.ClientException {
      online.value = false;
      throw ApiError('Needs connection', offline: true);
    }
    online.value = true;
    if (r.statusCode >= 400) {
      String msg;
      try {
        msg = jsonDecode(utf8.decode(r.bodyBytes))['error'].toString();
      } catch (_) {
        msg = 'HTTP ${r.statusCode}';
      }
      throw ApiError(msg);
    }
    if (method == 'GET' && (path.startsWith('media/') || path == 'app/apk')) return r.bodyBytes;
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// AI calls can take minutes (Opus generating 20 cards with explanations).
  static Future<Json> ai(String path, Json body) async =>
      Map<String, dynamic>.from(await call('POST', path, body: body, timeout: const Duration(minutes: 6)));

  /// Push media + dirty docs, pull everything newer than our cursor, fetch missing media.
  /// Returns null on success, else an error message.
  static Future<String?> sync() async {
    if (!configured) return 'Add your server token in Settings to sync.';
    if (syncing.value) return null;
    syncing.value = true;
    try {
      for (final name in await Db.pendingMedia()) {
        final f = Db.mediaFile(name);
        try {
          if (await f.exists()) await call('PUT', 'media/$name', bytes: await f.readAsBytes());
        } on ApiError catch (e) {
          if (e.offline) rethrow; // rejected by the server: skip it rather than block every future sync
        }
        await Db.markMediaUploaded(name);
      }
      var cursor = int.parse(await Db.meta('cursor') ?? '0');
      var more = true;
      while (more) {
        final push = await Db.dirtyDocs();
        final res = await call('POST', 'sync', body: {'cursor': cursor, 'docs': push}, timeout: const Duration(minutes: 2));
        await Db.markClean(push);
        await Db.applyRemote(res['docs'] as List);
        cursor = res['cursor'] as int;
        await Db.setMeta('cursor', '$cursor');
        more = res['more'] == true || push.length == 500;
      }
      await App.reload();
      await applyPendingOverrides();
      await applyFinishedJobs(); // before the media pass, so new diagrams download in this sync
      for (final c in await Db.query('card')) {
        for (final name in cardMedia(c)) {
          if (await Db.mediaFile(name).exists()) continue;
          try {
            await Db.mediaFile(name).writeAsBytes(await call('GET', 'media/$name') as List<int>, flush: true); // already on the server
          } on ApiError catch (e) {
            if (e.offline) rethrow; // missing on server: skip, the card shows a placeholder
          }
        }
      }
      final stamp = DateTime.now().toString().substring(0, 16);
      await Db.setMeta('last_sync', stamp);
      lastSync.value = stamp;
      changes.value++;
      return null;
    } catch (e) {
      return 'Sync failed: $e';
    } finally {
      syncing.value = false;
    }
  }
}
