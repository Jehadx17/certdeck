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
  static const _store = FlutterSecureStorage();
  /// The one domain value (`--dart-define=DARB_DOMAIN=...`); the API is https://<domain>/api/. DARB_API overrides the
  /// whole base URL for local testing (e.g. http://10.0.2.2:8000 from the Android emulator).
  static const domain = String.fromEnvironment('DARB_DOMAIN', defaultValue: 'darbedu.sa');
  static const defaultUrl = String.fromEnvironment('DARB_API', defaultValue: 'https://$domain');
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
      if (await Db.dirtyCount() > 0) return 'Couldn\'t upload this account\'s unsynced changes (${err ?? 'try again'}). Connect to the internet first.';
      await Db.wipe();
      me.value = null;
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
      throw ApiError(r.statusCode == 402 ? budgetMessage(msg) : msg);
    }
    if (method == 'GET' && path.startsWith('media/')) return r.bodyBytes;
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// AI calls can take minutes (Opus generating 20 cards with explanations).
  static Future<Json> ai(String path, Json body) async =>
      Map<String, dynamic>.from(await call('POST', path, body: body, timeout: const Duration(minutes: 6)));

  /// Who this token belongs to and their AI budget this month ({name, role, usd, cap_usd, remaining_usd}).
  static final me = ValueNotifier<Json?>(null);

  static Future<void> refreshMe() async {
    me.value = Map<String, dynamic>.from(await call('GET', 'me'));
  }

  static Future<String?>? _syncRun, _syncNext;

  /// Push dirty docs and new reviews, pull everything newer than our cursors.
  /// Returns null on success, else an error message. Called while a sync runs, it waits for one more run after
  /// that one (whose push may have missed the caller's change); concurrent callers share that run.
  static Future<String?> sync() {
    if (!configured) return Future.value('Add your server token in Settings to sync.');
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
      // Docs and reviews are two streams with their own cursors (docs/DARB-PROTOCOL.md).
      var cursor = int.parse(await Db.meta('cursor') ?? '0');
      var rcursor = int.parse(await Db.meta('review_cursor') ?? '0');
      var more = true;
      while (more) {
        final push = await Db.dirtyDocs();
        final reviews = [for (final d in push) if (d['kind'] == 'review') reviewWire(d)];
        final docs = [for (final d in push) if (d['kind'] != 'review') d];
        final res = await call('POST', 'sync',
            body: {'cursor': cursor, 'review_cursor': rcursor, 'docs': docs, 'reviews': reviews}, timeout: const Duration(minutes: 2));
        await Db.markClean(push);
        await Db.applyRemote([...res['docs'] as List, for (final r in res['reviews'] as List) reviewDoc(r as Map)]);
        cursor = res['cursor'] as int;
        rcursor = res['review_cursor'] as int;
        await Db.setMeta('cursor', '$cursor');
        await Db.setMeta('review_cursor', '$rcursor');
        more = res['more'] == true || push.length == 500;
      }
      await App.reload();
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

/// A local review doc -> the compact wire form (the free-text answer stays on the phone).
Json reviewWire(Json d) {
  final r = d['data'] as Map;
  return {
    for (final k in const ['card_id', 'ts', 'rating', 'correct', 'confidence', 'misconception', 'study_first', 'source', 'score', 'error_type'])
      if (r[k] != null) k: r[k],
    'duration_ms': (r['duration_ms'] as num?)?.toInt() ?? 0,
  };
}

/// A pulled review -> a local review doc, with the same deterministic id the phone that recorded it used.
Json reviewDoc(Map r) => {'id': 'r:${r['card_id']}:${r['ts']}', 'kind': 'review', 'data': r, 'updated_at': r['ts'], 'deleted': false};

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
