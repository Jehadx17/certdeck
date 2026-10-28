import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'speak_stub.dart' if (dart.library.js_interop) 'speak_web.dart' as player;

/// The course that holds the Oxford 3000 word cards (content import for jood); only its cards get the speaker.
const wordCourse = 'oxford3000';

/// The word a word card teaches: the bold part of its front (`**lock**\n\n*v., n.*` → `lock`).
String? cardWord(Map card) => card['course'] == wordCourse ? RegExp(r'\*\*(.+?)\*\*').firstMatch('${card['question']}')?.group(1) : null;

/// The US recording, else any recording, from a Free Dictionary API reply; null = the dictionary has none.
String? pickAudio(Object? reply) {
  final urls = [
    if (reply is List)
      for (final e in reply.whereType<Map>())
        for (final p in ((e['phonetics'] as List?) ?? []).whereType<Map>())
          if (p['audio'] is String && (p['audio'] as String).startsWith('https://')) p['audio'] as String
  ];
  return urls.where((u) => u.endsWith('-us.mp3')).firstOrNull ?? urls.firstOrNull;
}

/// Word pronunciation on the web: a real recording from the Free Dictionary API (free, no key), else the browser's
/// own English voice. iPhone browsers only play sound during the tap itself (a fallback after a failed load is
/// silenced), so the card downloads the recording when it shows ([prepare]) and the tap only plays ([say]).
class Speak {
  static final _found = <String, String?>{}; // word -> downloaded recording as a data: url (null = use the voice)
  static final _pending = <String, Future<void>>{};

  /// Looks the word up once per page load. Throws when there's no connection (and isn't cached, so it retries).
  static Future<void> prepare(String word) {
    if (_found.containsKey(word)) return Future.value();
    return _pending[word] ??= () async {
      try {
        final res = await http.get(Uri.https('api.dictionaryapi.dev', '/api/v2/entries/en/${Uri.encodeComponent(word)}')).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200 && res.statusCode != 404) throw http.ClientException('dictionary: ${res.statusCode}'); // a hiccup: try again next tap
        final url = res.statusCode == 200 ? pickAudio(jsonDecode(res.body)) : null; // 404 = not in the dictionary: the voice says it
        _found[word] = url == null ? null : await _download(url);
      } finally {
        _pending.remove(word);
      }
    }();
  }

  /// The recording, ready to play offline from the tap; null when it won't load (the dictionary's file server goes down).
  static Future<String?> _download(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      final type = res.headers['content-type'] ?? '';
      return res.statusCode == 200 && type.startsWith('audio/') ? 'data:$type;base64,${base64Encode(res.bodyBytes)}' : null;
    } catch (_) {
      return null;
    }
  }

  /// The speaker for a word card; [onTap] runs [say].
  static Widget button(String label, void Function() onTap) => player.button(label, onTap);

  /// Plays the word straight away. False = the browser is offline, so the caller tells the student.
  static bool say(String word) {
    if (!player.online()) return false;
    // Not looked up yet: the voice now (a wait would lose the tap on iPhone), the recording from the next tap.
    if (!_found.containsKey(word)) prepare(word).ignore();
    player.play(_found[word], word);
    return true;
  }
}
