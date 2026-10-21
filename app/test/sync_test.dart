// End-to-end check of offline storage + sync + "reinstall and restore" against a running backend:
//   CERTDECK_TEST_URL=http://127.0.0.1:8000 CERTDECK_TEST_TOKEN=devtoken flutter test test/sync_test.dart
// Skipped when CERTDECK_TEST_URL is unset.
import 'dart:io';

import 'package:certdeck/api.dart';
import 'package:certdeck/db.dart';
import 'package:certdeck/logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
    final img = await Db.saveMedia([0x89, 0x50, 0x4E, 0x47, ...List.generate(60, (i) => i)]);
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

    // A change made while a sync runs is pushed by the sync its caller awaits (an upload's "tell the server" step).
    final running = Api.sync();
    await Db.put('card', (await Db.get(card['id']))!..['question'] = 'Edited mid-sync');
    expect(await Api.sync(), isNull);
    expect(await Db.dirtyCount(), 0);
    expect(await running, isNull);
  }, skip: url == null ? 'set CERTDECK_TEST_URL to run' : false);

  test('a finished diagram job is attached to its card and its image downloads in the same sync', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Api.url = url!;
    Api.token = Platform.environment['CERTDECK_TEST_TOKEN'];
    final tmp = await Directory.systemTemp.createTemp('certdeck');

    // Stand-in for the server: a card plus a done diagrams job referencing an uploaded image.
    await Db.open(dir: '${tmp.path}/server');
    await App.init();
    final card = await Db.put('card', {'type': 'basic', 'question': 'Where does EBS live?', 'answer': 'One AZ', 'created_at': nowMs()});
    final img = await Db.saveMedia([0x89, 0x50, 0x4E, 0x47, ...List.generate(40, (i) => 255 - i)]);
    // applied_at set = an older app build already marked it done without attaching diagrams.
    await Db.put('job', {'task': 'diagrams', 'status': 'done', 'count': 1, 'added': 1, 'created_at': nowMs(), 'applied_at': 1,
      'card_ids': [card['id']], 'diagrams': [{'card_id': card['id'], 'image': img}]});
    expect(await Api.sync(), isNull);

    await Db.open(dir: '${tmp.path}/phone');
    await App.init();
    await Db.setMeta('cursor', '0');
    expect(await Api.sync(), isNull);
    expect((await Db.get(card['id']))!['answer_images'], [img]);
    expect(await Db.mediaFile(img).exists(), isTrue);
    expect(await Db.dirtyCount(), greaterThan(0)); // the card change goes back to the server on the next sync
  }, skip: url == null ? 'set CERTDECK_TEST_URL to run' : false);

  // One phone, two people (CERTDECK_TEST_TOKEN2 = a student account): switching the token pushes the first
  // account's changes, then the phone holds only the second account's data, and switching back restores the first.
  final token2 = Platform.environment['CERTDECK_TEST_TOKEN2'];
  test('switching accounts on one phone never mixes data', () async {
    FlutterSecureStorage.setMockInitialValues({}); // Api.connect saves the token in secure storage
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tmp = await Directory.systemTemp.createTemp('certdeck');
    await Db.open(dir: tmp.path);
    await App.init();
    Api.url = url!;
    Api.token = null;
    expect(await Api.connect(url, Platform.environment['CERTDECK_TEST_TOKEN']!), isNull);
    final mine = await Db.put('card', {'type': 'basic', 'question': 'Owner only', 'answer': 'x', 'certs': {'DVA-C02': '1'}, 'created_at': nowMs()});
    expect(App.role, 'owner');

    expect(await Api.connect(url, token2!), isNull); // the owner's new card is pushed first, then the phone is wiped
    expect(App.role, 'student');
    expect(await Db.get(mine['id']), isNull);
    expect((await Db.query('card')).where((c) => c['question'] == 'Owner only'), isEmpty);
    final hers = await Db.put('course', {'name': 'Calculus II', 'created_at': nowMs()});
    expect(await Api.sync(), isNull);

    expect(await Api.connect(url, Platform.environment['CERTDECK_TEST_TOKEN']!), isNull);
    expect(App.role, 'owner');
    expect((await Db.get(mine['id']))?['question'], 'Owner only'); // restored from the server
    expect(await Db.get(hers['id']), isNull);
  }, skip: url == null || token2 == null ? 'set CERTDECK_TEST_URL and CERTDECK_TEST_TOKEN2 to run' : false);
}
