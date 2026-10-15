// End-to-end check of offline storage + sync + "reinstall and restore" against a running Darb backend:
//   DARB_TEST_URL=http://127.0.0.1:8000 DARB_TEST_TOKEN=<token> DARB_TEST_TOKEN2=<another account's token> \
//     flutter test test/sync_test.dart
// (tokens: `manage.py users create a@example.com`). Skipped when DARB_TEST_URL is unset.
import 'dart:io';

import 'package:darb/api.dart';
import 'package:darb/db.dart';
import 'package:darb/logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final url = Platform.environment['DARB_TEST_URL'];
  final token = Platform.environment['DARB_TEST_TOKEN'];
  final token2 = Platform.environment['DARB_TEST_TOKEN2'];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('device A studies offline, syncs; fresh install B restores docs and the review log', () async {
    Api.url = url!;
    Api.token = token;
    final tmp = await Directory.systemTemp.createTemp('darb');

    // Device A: a card studied offline (a misconception), and a setting.
    await Db.open(dir: '${tmp.path}/a');
    await App.init();
    final card = await Db.put('card', {'type': 'mcq', 'question': 'Q?', 'options': ['a', 'b'], 'correct': [1], 'created_at': nowMs()});
    await recordAnswer(card, conf: Conf.sure, correct: false, source: 'study', answer: 'stays on the phone');
    App.settings['exam_date'] = '2027-01-15';
    await App.saveSettings();
    expect(await Api.sync(), isNull);
    expect(await Db.dirtyCount(), 0);
    expect(await Api.sync(), isNull); // the echoed review is the same doc (deterministic id): nothing new to push
    expect(await Db.dirtyCount(), 0);
    expect((await Db.reviewsFor(card['id'])).length, 1);

    // Device B: fresh install, same account, sync = full restore.
    await Db.open(dir: '${tmp.path}/b');
    await App.init();
    expect(await Api.sync(), isNull);
    final restored = await Db.get(card['id']);
    expect(restored!['misconception'], isTrue);
    expect(restored['fsrs']['state'], isNotNull);
    final r = (await Db.reviewsFor(card['id'])).single;
    expect((r['confidence'], r['misconception'], r['answer']), ('sure', true, null)); // the free-text answer stayed on A
    expect(App.settings['exam_date'], '2027-01-15');

    // Edit on B wins on A (last write wins).
    await Db.put('card', restored..['question'] = 'Edited on B');
    expect(await Api.sync(), isNull);
    await Db.open(dir: '${tmp.path}/a');
    await App.init();
    expect(await Api.sync(), isNull);
    expect((await Db.get(card['id']))!['question'], 'Edited on B');

    // A change made while a sync runs is pushed by the sync its caller awaits.
    final running = Api.sync();
    await Db.put('card', (await Db.get(card['id']))!..['question'] = 'Edited mid-sync');
    expect(await Api.sync(), isNull);
    expect(await Db.dirtyCount(), 0);
    expect(await running, isNull);
  }, skip: url == null || token == null ? 'set DARB_TEST_URL and DARB_TEST_TOKEN to run' : false);

  // One phone, two people: switching accounts pushes the first one's changes, then the phone holds only the second's
  // data, and switching back restores the first.
  test('switching accounts on one phone never mixes data', () async {
    FlutterSecureStorage.setMockInitialValues({}); // Api.connect saves the token in secure storage
    final tmp = await Directory.systemTemp.createTemp('darb');
    await Db.open(dir: tmp.path);
    await App.init();
    Api.url = url!;
    Api.token = null;
    expect(await Api.connect(url, token!), isNull);
    final mine = await Db.put('card', {'type': 'basic', 'question': 'Mine only', 'answer': 'x', 'created_at': nowMs()});

    expect(await Api.connect(url, 'not-a-real-token'), contains('recognise')); // a typo changes nothing
    expect((await Db.get(mine['id']))?['question'], 'Mine only');

    expect(await Api.connect(url, token2!), isNull); // my new card is pushed first, then the phone is wiped
    expect(await Db.get(mine['id']), isNull);
    final hers = await Db.put('course', {'name': 'Calculus II', 'created_at': nowMs()});
    expect(await Api.sync(), isNull);

    expect(await Api.connect(url, token), isNull);
    expect((await Db.get(mine['id']))?['question'], 'Mine only'); // restored from the server
    expect(await Db.get(hers['id']), isNull);
  }, skip: url == null || token == null || token2 == null ? 'set DARB_TEST_URL, DARB_TEST_TOKEN and DARB_TEST_TOKEN2 to run' : false);
}
