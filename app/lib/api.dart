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
    // Every 30 s while the server is processing material or preparing an assessment for us (so progress shows);
    // every 2 min to push local changes or to collect Batch API results.
    var ticks = 0;
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      ticks++;
      if (await serverBusy() || (ticks % 4 == 0 && (await Db.dirtyCount() > 0 || await serverWaiting()))) sync().ignore();
    });
  }

  static Future<void> configure(String newUrl, String newToken) async {
    url = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    token = newToken.trim();
    await _store.write(key: 'url', value: url);
    await _store.write(key: 'token', value: token);
  }

  /// Saves the server and token. Another account on this phone: push this one's unsynced changes, then start
  /// from an empty local database so the new account restores cleanly (never mix two people's data).
  /// Returns null on success, else why it didn't switch.
  static Future<String?> connect(String newUrl, String newToken) async {
    newUrl = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    // Check the new token with the server before touching anything: a typo must never cost local data.
    try {
      final r = await http.get(Uri.parse('$newUrl/api/me'), headers: {'Authorization': 'Bearer ${newToken.trim()}'}).timeout(const Duration(seconds: 30));
      if (r.statusCode == 401) return 'The server doesn\'t recognise this token. Nothing was changed.';
      if (r.statusCode >= 400) return 'Server error (HTTP ${r.statusCode}). Nothing was changed.';
    } on Exception {
      return 'Needs connection to check the token. Nothing was changed.';
    }
    final switching = configured && newToken.trim() != token;
    if (switching) {
      if ((await Db.meta('uploads') ?? '{}') != '{}') return 'Finish the uploads in progress first (or wait until they are done).';
      final err = await sync();
      if (err != null && await Db.dirtyCount() > 0) return 'Couldn\'t upload this account\'s unsynced changes ($err). Connect to the internet first.';
      await Db.wipe();
      me.value = null;
      App.role = 'owner';
      await App.init();
    }
    await configure(newUrl, newToken);
    final err = await sync();
    if (switching && err == null) await App.reload();
    return err;
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

  /// Who this token belongs to and their AI budget this month ({name, role, usd, cap_usd, remaining_usd}).
  static final me = ValueNotifier<Json?>(null);

  static Future<void> refreshMe() async {
    final m = Map<String, dynamic>.from(await call('GET', 'me'));
    me.value = m;
    if (m['role'] is String && m['role'] != App.role) {
      App.role = m['role'];
      await Db.setMeta('role', App.role);
      changes.value++;
    }
  }

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
      await refreshMe();
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
