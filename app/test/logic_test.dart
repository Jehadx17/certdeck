import 'package:certdeck/cards.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:certdeck/api.dart' show budgetMessage;
import 'package:certdeck/logic.dart';
import 'package:certdeck/widgets.dart' show clozeBack, clozeFront, isolateRuns;
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unseen cards keep a share of the session even with a long backlog', () {
    final due = [for (var i = 0; i < 100; i++) {'id': 'd$i', 'fsrs': {'state': 2}}];
    final fresh = [for (var i = 0; i < 20; i++) {'id': 'n$i'}];
    final q = mixByTime(due, fresh, 10, 30); // 600 s: 80% = 480 s -> 8 new cards (60 s each), then 4 reviews
    expect(q.where(isNew).length, 8);
    expect(q.length, 8 + 4);
    expect(q.take(8).every(isNew), true); // new cards come first
    expect(mixByTime(due.take(2).toList(), fresh, 10, 30).where(isNew).length, 9); // few reviews: the time goes to new cards
    expect(mixByTime(due, [], 10, 30).length, 20);
  });

  test('a session is capped to its minutes, new cards cost double, at least one card always fits', () {
    final old = {'id': 'o', 'fsrs': {'state': 2}};
    final fresh = {'id': 'n'}; // no fsrs: new
    final q = [old, old, fresh, old, old];
    expect(capByTime(q, 1, 30).length, 2); // 30 + 30 = 60 s
    expect(capByTime([fresh, old], 1, 30).length, 1); // the new card costs 60 s
    expect(capByTime([fresh], 1, 600).length, 1);
    expect(capByTime(q, 60, 30).length, 5);
  });

  test('calibration counts Sure answers and the right ones', () {
    final s = sureStats([(Conf.sure, true), (Conf.sure, false), (Conf.guess, true), (Conf.sure, true)]);
    expect((s.sure, s.sureRight), (3, 2));
  });

  test('goal shifts retention, new learners study new cards first', () {
    expect(goalRetentionAdj('pass'), lessThan(0));
    expect(goalRetentionAdj('top'), greaterThan(0));
    expect(goalRetentionAdj(null), 0);
    App.settings = {...defaultSettings, 'expertise': 'new'};
    expect(studyFirst({'id': 'n'}), isTrue);
    expect(studyFirst({'id': 'o', 'fsrs': {'state': 2}}), isFalse);
    App.settings = {...defaultSettings, 'expertise': 'know'};
    expect(studyFirst({'id': 'n'}), isFalse);
    App.settings = {...defaultSettings};
  });

  test('the student pick beats the autopilot until its next update', () {
    App.role = 'student';
    App.settings = {...defaultSettings, 'session_minutes': 10};
    App.autopilot = {'session_minutes': 5, 'updated_at': 2000};
    expect(App.sessionMinutes, 5);
    App.settings['session_minutes_set_at'] = 3000;
    expect(App.sessionMinutes, 10);
    App.autopilot = {'session_minutes': 15, 'updated_at': 4000};
    expect(App.sessionMinutes, 15);
    App.role = 'owner';
    App.autopilot = {};
    App.settings = {...defaultSettings};
  });

  test('confidence → FSRS rating', () {
    expect(ratingFor(Conf.sure, false), fsrs.Rating.again);
    expect(ratingFor(Conf.guess, true), fsrs.Rating.hard);
    expect(ratingFor(Conf.unsure, true), fsrs.Rating.hard);
    expect(ratingFor(Conf.sure, true), fsrs.Rating.good);
    expect(ratingFor(Conf.sure, true), fsrs.Rating.good);
    expect(ratingFor(Conf.unsure, true, learning: true), fsrs.Rating.good);
    expect(ratingFor(Conf.guess, false, learning: true), fsrs.Rating.again);
  });

  test('lenient typed matching', () {
    expect(lenientMatch('AWS STS assume_role', ['aws sts assume-role']), isTrue);
    expect(lenientMatch('`kubectl get pods`.', ['kubectl get pods']), isTrue);
    expect(lenientMatch('kubectl get pod', ['kubectl get pods']), isTrue); // 1 typo
    expect(lenientMatch('generate data key without plaintext', ['GenerateDataKeyWithoutPlaintext']), isTrue);
    expect(lenientMatch('s4', ['s3']), isFalse); // short answers must be exact
    expect(lenientMatch('dynamodb', ['aws sts assume-role']), isFalse);
  });

  test('weighted new-card interleave follows exam weights', () {
    final cert = {
      'id': 'X',
      'domains': [
        {'id': '1', 'weight': .75},
        {'id': '2', 'weight': .25}
      ]
    };
    final cards = [
      for (var i = 0; i < 40; i++)
        {
          'id': '$i',
          'created_at': i,
          'certs': {'X': i.isEven ? '1' : '2'}
        }
    ];
    final firstEight = orderNew(cards, cert).take(8).map((c) => (c['certs'] as Map)['X']).toList();
    expect(firstEight.where((d) => d == '1').length, 6);
  });

  test('list titles: LaTeX as readable text, cloze answers, no Markdown marks', () {
    expect(plain(r'Evaluate $\int\frac{e^x}{1+e^{2x}}\,dx$.'), 'Evaluate ∫eˣ/(1+e²ˣ) dx.');
    expect(plain(r'$$\int_0^3 x^2\,dx$$'), '∫₀³ x² dx');
    expect(plain('The **default** {{constructor::kind}}'), 'The default constructor');
    expect(plain('my_var stays'), 'my_var stays');
  });

  test('mixed Arabic/English: runs of the other script are isolated, code and math untouched', () {
    const lri = '\u2066', rli = '\u2067', pdi = '\u2069';
    final ar = isolateRuns('المتغيرات الثابتة (static) مشتركة — one copy per class.', rtl: true);
    expect(ar, contains('(${lri}static$pdi)')); // brackets stay outside the isolate and pair up
    expect(ar, contains('${lri}one copy per class$pdi.'));
    final en = isolateRuns('`count` is **static** (المتغير الثابت مشترك بين جميع الكائنات), see \$x^2\$.', rtl: false);
    expect(en, startsWith('`count` is **static** ('));
    expect(en, contains('($rliالمتغير الثابت مشترك بين جميع الكائنات$pdi)'));
    expect(en, contains('\$x^2\$')); // math unchanged in an LTR paragraph
    expect(isolateRuns('ارجع إلى [الرابط](https://example.com/a_b)', rtl: true), contains('$lri[الرابط](https://example.com/a_b)$pdi'));
    // A cloze inside the English phrase stays inside the same unit; a fully wrapped term keeps its markers outside.
    final cloze = isolateRuns('المتغيرات الثابتة (‹**static**›) بين الكائنات — one copy per ‹**class**›.', rtl: true);
    expect(cloze, contains('${lri}one copy per ‹**class**›$pdi.'));
    expect(cloze, contains('(‹**${lri}static$pdi**›)'));
    expect(isolateRuns('يُعتنى بـ[**shared / separate?**]', rtl: true), contains('[**${lri}shared / separate?$pdi**]'));
    // Still valid Markdown: the bold survives the isolates.
    expect(md.markdownToHtml(isolateRuns('**قراءة الالتقاط (Scanning)**', rtl: true)), contains('<strong>'));
  });

  test('cloze blanks inside inline code', () {
    expect(clozeBack('set `{{WaitTimeSeconds}}` to {{20}}'), 'set ‹`WaitTimeSeconds`› to ‹20›');
    expect(clozeFront('set `{{WaitTimeSeconds::param}}`'), 'set ‹param›');
    expect(clozeFront('from {{0}} up'), matches(RegExp('^from ‹\u2007+› up\$')));
  });

  test('the budget refusal reads in Arabic with its amounts', () {
    const server = r'Monthly AI budget reached: $0.12 of $8.55 left, this needs about $0.25. Studying still works.';
    App.settings['lang'] = 'ar';
    final ar = budgetMessage(server);
    expect(ar, contains('\u20680.12\u2069'));
    expect(ar, contains('\u20688.55\u2069'));
    expect(ar, contains('\u20680.25\u2069'));
    expect(ar, isNot(contains('Monthly')));
    App.settings['lang'] = 'en';
    expect(budgetMessage(server), 'Monthly AI budget reached: \$\u20680.12\u2069 of \$\u20688.55\u2069 left. This needs about \$\u20680.25\u2069. Studying still works.');
    expect(budgetMessage('something else'), 'something else');
  });

  test('card versions take turns, scheduling fields stay on the original', () {
    final card = {'id': 'c1', 'type': 'cloze', 'question': 'orig', 'fsrs': {'due': 5}, 'option_explanations': ['x'], 'answer_images': ['i']};
    final vs = [{'type': 'mcq', 'question': 'v2', 'options': ['a', 'b'], 'correct': [1]}, {'type': 'mcq', 'question': 'v3'}];
    final seen = <String>[];
    for (var n = 0; n < 4; n++) {
      final (i, shown) = pickVersion(card, vs);
      seen.add(shown['question'] as String);
      expect(shown['id'], 'c1');
      expect(shown['fsrs'], {'due': 5});
      if (i > 0) expect([shown['option_explanations'], shown['answer_images']], [null, null]);
      card['ver'] = i;
    }
    expect(seen, ['orig', 'v2', 'v3', 'orig']);
    expect(pickVersion({'id': 'x', 'ver': 2}, []).$2['id'], 'x');
  });
}
