import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'db.dart';
import 'i18n.dart';
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
  static final defaultUrl = kIsWeb ? Uri.base.origin : 'https://certdeck.mithaqstay.com'; // web is served by the API's own host
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

  /// Saves the server and the token a sign-in returned. Another account on this phone: push this one's unsynced
  /// changes, then start from an empty local database so the new account restores cleanly (never mix two people's data).
  /// Returns null on success, else why it didn't switch.
  static Future<String?> connect(String newUrl, String newToken) async {
    final switching = configured && newToken.trim() != token;
    if (switching) {
      if ((await Db.meta('uploads') ?? '{}') != '{}') return 'Finish the uploads in progress first (or wait until they are done).';
      final err = await sync();
      if (await Db.dirtyCount() > 0) return 'Couldn\'t upload this account\'s unsynced changes (${err ?? 'try again'}). Connect to the internet first.';
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

  /// Signs in (or registers a new account) with email and password and connects this phone.
  /// Returns null on success, else a message for the person typing it.
  static Future<String?> signIn(String email, String password, {bool register = false}) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('$defaultUrl/api/${register ? 'signup' : 'login'}'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 30));
    } on Exception {
      return 'No internet. Connect to Wi-Fi and try again.';
    }
    String? msg;
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode == 200) return await connect(defaultUrl, body['token'] as String);
      msg = body['error']?.toString();
    } on FormatException {
      msg = null;
    }
    return msg ?? 'Something went wrong. Try again in a minute.';
  }

  static Future<dynamic> call(String method, String path, {Object? body, List<int>? bytes, Duration timeout = const Duration(seconds: 60)}) async {
    if (!configured) throw ApiError('Needs connection: sign in from Settings', offline: true);
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
      throw ApiError(r.statusCode == 402 ? budgetMessage(msg) : msg);
    }
    if (method == 'GET' && (path.startsWith('media/') || path == 'app/apk')) return r.bodyBytes;
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// AI calls can take minutes (Opus generating 20 cards with explanations).
  static Future<Json> ai(String path, Json body) async =>
      Map<String, dynamic>.from(await call('POST', path, body: body, timeout: const Duration(minutes: 6)));

  /// Who is signed in and their AI budget this month ({name, role, usd, cap_usd, remaining_usd}).
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

  static Future<String?>? _syncRun, _syncNext;

  /// Push media + dirty docs, pull everything newer than our cursor, fetch missing media.
  /// Returns null on success, else an error message. Called while a sync runs, it waits for one more run after
  /// that one (whose push may have missed the caller's change); concurrent callers share that run.
  static Future<String?> sync() {
    if (!configured) return Future.value('Sign in from Settings to sync.');
    if (_syncRun != null) {
      return _syncNext ??= _syncRun!.then((_) {
        _syncNext = null;
        return sync();
      });
    }
    return _syncRun = _sync().whenComplete(() => _syncRun = null);
  }

  static Future<String?> _sync() async {
    syncing.value = true;
    try {
      for (final name in await Db.pendingMedia()) {
        try {
          final b = await Db.mediaBytes(name);
          if (b != null) await call('PUT', 'media/$name', bytes: b);
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
      await refreshMe(); // before the media pass: a stalled image download mustn't leave a switched phone in the old role
      await applyPendingOverrides();
      await applyFinishedJobs(); // before the media pass, so new diagrams download in this sync
      for (final c in await Db.query('card')) {
        for (final name in cardMedia(c)) {
          if (await Db.mediaExists(name)) continue;
          try {
            await Db.mediaWrite(name, await call('GET', 'media/$name') as List<int>); // already on the server
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

/// The server's budget refusal carries amounts, so it can't be looked up whole in the translations.
String budgetMessage(String msg) {
  final m = RegExp(r'\$(\d+(?:\.\d+)?) of \$(\d+(?:\.\d+)?) left(?:, this needs about \$(\d+(?:\.\d+)?))?').firstMatch(msg);
  if (m == null) return msg;
  return [
    t('Monthly AI budget reached: \${left} of \${cap} left.', {'left': m[1], 'cap': m[2]}),
    if (m[3] != null) t('This needs about \${n}.', {'n': m[3]}),
    t('Studying still works.'),
  ].join(' ');
}
