import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:darb/logic.dart';
import 'package:darb/packs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = List<int>.generate(32, (i) => i); // the fixture's key (test/fixtures/demo-3.dpk, built like core.packs.build)

  test('a pack encrypted by the backend decrypts here; the wrong version or a flipped bit does not', () async {
    final blob = File('test/fixtures/demo-3.dpk').readAsBytesSync();
    final data = await decryptPack((blob, 'demo', 3, key));
    expect((data['cards'] as List).length, 2);
    expect((data['cards'] as List).first['question'], 'قلم : كتابة');
    expect(() => decryptPack((blob, 'demo', 4, key)), throwsA(anything)); // AAD binds slug and version
    final flipped = Uint8List.fromList(blob)..[40] ^= 1;
    expect(() => decryptPack((flipped, 'demo', 3, key)), throwsA(anything));
  });

  test('watermark: the right answer survives the shuffle, the order is per account and stable, the marker is invisible', () {
    Map<String, dynamic> card(int i) =>
        {'id': 'demo:$i', 'type': 'mcq', 'question': 'q$i', 'options': ['A', 'B', 'C', 'D'], 'correct': [2], 'explanation': 'because'};
    var differs = 0;
    for (var i = 0; i < 20; i++) {
      final a = watermark(card(i), 'seed-a'), a2 = watermark(card(i), 'seed-a'), b = watermark(card(i), 'seed-b');
      expect((a['options'] as List)[(a['correct'] as List).single], 'C');
      expect((b['options'] as List)[(b['correct'] as List).single], 'C');
      expect(a['options'], a2['options']);
      if ('${a['options']}' != '${b['options']}') differs++;
      expect((a['explanation'] as String).replaceAll(RegExp('[​‌]'), ''), 'because');
      expect((a['explanation'] as String).length, 'because'.length + 32);
    }
    expect(differs, greaterThan(10)); // two accounts see different option orders on most cards
    expect(watermark(card(1), null)['options'], ['A', 'B', 'C', 'D']); // samples are left as they are
  });

  test('replaying the review log rebuilds the schedule, lapses and flags', () {
    final t0 = DateTime.utc(2026, 9, 1).millisecondsSinceEpoch;
    Map<String, dynamic> r(int day, int rating, {bool sure = false, bool correct = true, bool mis = false}) =>
        {'ts': t0 + day * dayMs, 'rating': rating, 'confidence': sure ? 'sure' : 'unsure', 'correct': correct, 'misconception': mis};
    final c = replay({'id': 'demo:1'}, [r(0, 3), r(3, 3), r(10, 1, sure: true, correct: false, mis: true)]);
    expect(c['fsrs']['state'], isNotNull);
    expect((c['lapses'], c['misconception'], c['new']), (1, true, false));
    final fixed = replay({'id': 'demo:1'}, [r(0, 3), r(10, 1, sure: true, correct: false, mis: true), r(11, 4, sure: true), r(14, 4, sure: true)]);
    expect(fixed['misconception'], isFalse); // sure and right twice in a row clears it
  });

  test('a dropped download resumes from where it stopped and is checked', () async {
    final body = List<int>.generate(300000, (i) => i % 251);
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests++;
      final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(req.headers.value('range') ?? 'bytes=0-')!.group(1)!);
      if (requests == 1) {
        // A response that promises the whole file, sends a third of it, then the connection drops.
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n'));
        socket.add(body.sublist(0, 100000));
        await socket.flush();
        socket.destroy();
        return;
      }
      req.response.statusCode = from > 0 ? 206 : 200;
      req.response.add(body.sublist(from));
      await req.response.close();
    });
    final dir = await Directory.systemTemp.createTemp('darb');
    final file = File('${dir.path}/x.dpk');
    await Packs.download(Uri.parse('http://127.0.0.1:${server.port}/x.dpk'), file, size: body.length, sha256: sha256.convert(body).toString());
    expect(await file.readAsBytes(), body);
    expect(requests, 2);
    await server.close(force: true);
  });
}
