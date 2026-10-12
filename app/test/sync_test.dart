// End-to-end check of offline storage + sync + "reinstall and restore" against a running backend:
//   CERTDECK_TEST_URL=http://127.0.0.1:8000 CERTDECK_TEST_TOKEN=devtoken flutter test test/sync_test.dart
// Skipped when CERTDECK_TEST_URL is unset.
import 'dart:io';

import 'package:certdeck/api.dart';
import 'package:certdeck/db.dart';
import 'package:certdeck/logic.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['CERTDECK_TEST_URL'];
  test('device A studies offline, syncs; fresh install B restores everything', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Api.url = url!;
    Api.token = Platform.environment['CERTDECK_TEST_TOKEN'];
    final tmp = await Directory.systemTemp.createTemp('certdeck');

    // Device A: create + study a card with an image, all offline-capable local writes.
    await Db.open(dir: '${tmp.path}/a');
    await App.init();
    final img = await Db.saveMedia(List.generate(64, (i) => i), 'png');
    final card = await Db.put('card', {
      'type': 'mcq',
      'question': 'Q?',
      'options': ['a', 'b'],
      'correct': [1],
      'certs': {'DVA-C02': '2'},
      'question_images': [img],
      'created_at': nowMs(),
    });
    await recordAnswer(card, conf: Conf.sure, correct: false, source: 'study'); // misconception
    App.cert['exam_date'] = '2027-01-15';
    await Db.put('cert', App.cert);
    expect(await Api.sync(), isNull);
    expect(await Db.dirtyCount(), 0);

    // Device B: fresh install, enter token, sync = full restore.
    await Db.open(dir: '${tmp.path}/b');
    await App.init();
    await Db.setMeta('cursor', '0');
    expect(await Api.sync(), isNull);
    final restored = await Db.get(card['id']);
    expect(restored!['misconception'], isTrue);
    expect(restored['fsrs']['state'], isNotNull);
    expect((await Db.reviewsFor(card['id'])).single['confidence'], 'sure');
    expect(App.cert['exam_date'], '2027-01-15');
    expect(await Db.mediaFile(img).exists(), isTrue);

    // Edit on B wins on A (last write wins).
    await Db.put('card', restored..['question'] = 'Edited on B');
    expect(await Api.sync(), isNull);
    await Db.open(dir: '${tmp.path}/a');
    await App.init();
    expect(await Api.sync(), isNull);
    expect((await Db.get(card['id']))!['question'], 'Edited on B');
  }, skip: url == null ? 'set CERTDECK_TEST_URL to run' : false);
}
