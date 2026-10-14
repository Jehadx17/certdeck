import 'package:certdeck/college_logic.dart';
import 'package:certdeck/db.dart';
import 'package:certdeck/logic.dart';
import 'package:certdeck/widgets.dart';
import 'package:certdeck/easy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

Json card(String id, {String section = 's1', List<String> kps = const [], String type = 'mcq', Map? fsrsState, bool misconception = false}) => {
      'id': id,
      'type': type,
      'question': id,
      'section': section,
      'kp_ids': kps,
      if (fsrsState != null) 'fsrs': fsrsState,
      if (misconception) 'misconception': true,
    };

/// A card reviewed [daysAgo] days ago with [stability] days of stability (recall falls as days pass).
Map reviewed(double stability, int daysAgo) {
  final last = DateTime.now().subtract(Duration(days: daysAgo)).millisecondsSinceEpoch;
  return {'state': 2, 'step': null, 'stability': stability, 'difficulty': 5.0, 'due': last + 86400000, 'last_review': last};
}

Scope scope(List<Json> cards, Map<String, int> prio, {int days = 2, Map<String, double> formats = const {}}) => Scope(
    {'id': 'a1', 'date': DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10), 'scope': []},
    cards,
    prio,
    schedulerForDate(DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10)),
    Pace(Pace.defaults),
    formats: formats,
    priorityScale: 5); // these tests were written with 1-5 priorities

void main() {
  test('mode from days left', () {
    expect([null, 0, 3, 4, 14, 15].map(modeFor).toList(), [Mode.long, Mode.sprint, Mode.sprint, Mode.compressed, Mode.compressed, Mode.long]);
  });

  test('triage: expected marks per second, shaky cards first, low-value leftovers skipped', () {
    final cards = [
      card('low', kps: ['k1']), // priority 1, new
      card('high', kps: ['k5']), // priority 5, new
      card('mid', kps: ['k3']), // priority 3, new
      card('shaky', kps: ['k3'], fsrsState: reviewed(1, 5)), // seen, recall low -> relearn first
      card('known', kps: ['k5'], fsrsState: reviewed(400, 1)), // mastered: nothing to gain in a sprint
      for (var i = 0; i < 20; i++) card('filler$i', kps: ['k1']),
    ];
    final s = scope(cards, {'k1': 1, 'k3': 3, 'k5': 5});
    expect(s.mode, Mode.sprint);
    expect(s.value(cards[1]), greaterThan(s.value(cards[2])));
    // 3 minutes: 85% budget = 153 s; a new mcq costs 3 x 35 s, a shaky one 2 x 35 s.
    final tri = plan(s, 3);
    final master = tri.master.map((c) => c['id']).toList();
    expect(master.first, 'shaky');
    expect(master, contains('high'));
    expect(master, isNot(contains('known')));
    expect(master, isNot(contains('low')));
    // Priority-1 cards that don't fit are "skip"; worthwhile ones that don't fit are "skim".
    expect(tri.skip.every((c) => s.weight(c) < .6), isTrue);
    expect(tri.skim.map((c) => c['id']), contains('mid'));
  });

  test('triage shares the time across formats instead of filling it with the quickest cards', () {
    final cards = [
      for (var i = 0; i < 30; i++) card('cloze$i', type: 'cloze', kps: ['k']), // 20 s each: the cheapest
      for (var i = 0; i < 5; i++) card('short$i', type: 'short', kps: ['k']), // 75 s each
      for (var i = 0; i < 5; i++) card('mcq$i', kps: ['k']),
    ];
    final even = plan(scope(cards, {'k': 4}), 15);
    expect(even.master.map(formatOf).toSet(), {'short_answer', 'mcq'}); // cloze and short both train short answers
    expect(even.master.where((c) => c['type'] == 'mcq'), isNotEmpty);
    // The professor's past papers are all MCQ: the session follows.
    final mcqOnly = plan(scope(cards, {'k': 4}, formats: {'mcq': 1.0}), 15);
    expect(mcqOnly.master.where((c) => c['type'] == 'mcq').length, 5);
  });

  test('sprint loop: right twice in a row to learn, a miss comes back 3 cards later', () {
    final cards = [for (var i = 0; i < 8; i++) card('c$i')];
    final s = scope(cards, {});
    final q = SprintSession(cards, s);
    final c0 = q.next()!;
    q.answered(c0, 0); // wrong
    expect(q.queue.indexOf(c0), 3);
    final c1 = q.next()!;
    q.answered(c1, 1); // right once: not learned yet, back 6 later
    expect(q.queue.indexOf(c1), 6);
    expect(q.learned, 0);
    q.queue.remove(c1);
    q.answered(c1, 1); // right twice in a row
    expect(q.learned, 1);
    expect(q.queue.contains(c1), isFalse);
    q.queue.remove(c0);
    q.answered(c0, .5); // partial counts as a miss and resets the streak
    expect(q.streak['c0'], 0);
  });

  test('a well-known card needs one correct answer in a sprint', () {
    final k = card('k', fsrsState: reviewed(400, 1));
    final q = SprintSession([k], scope([k], {}));
    q.answered(q.next()!, 1);
    expect((q.learned, q.remaining), (1, 0));
  });

  test('interleave alternates sections', () {
    final out = interleave([card('a1', section: 'A'), card('a2', section: 'A'), card('b1', section: 'B'), card('a3', section: 'A'), card('b2', section: 'B')]);
    expect(out.map((c) => c['id']), ['a1', 'b1', 'a2', 'b2', 'a3']);
  });

  test('graded answers: partial credit rates Hard, wrong Again', () {
    expect(ratingForScore(Conf.sure, 1, 0), fsrs.Rating.good);
    expect(ratingForScore(Conf.sure, .6, 0), fsrs.Rating.hard);
    expect(ratingForScore(Conf.unsure, .2, 0), fsrs.Rating.again);
  });

  test('written answers: rubric ticks, verified numeric answers, self verdicts', () {
    final short = AnswerState({
      'type': 'short',
      'question': 'Define a constructor.',
      'answer': '...',
      'rubric': [
        {'point': 'same name as the class', 'weight': .5},
        {'point': 'no return type', 'weight': .3},
        {'point': 'invoked with new', 'weight': .2},
      ],
    });
    expect(short.graded, isFalse);
    short
      ..rubricTouched = true
      ..rubricMet.addAll([0, 2]);
    expect(short.score, closeTo(.7, 1e-9));
    expect(short.correct, isFalse);

    final problem = AnswerState({
      'type': 'problem',
      'question': 'Evaluate.',
      'answer': '9',
      'steps': ['...'],
      'check': {'kind': 'numeric', 'expr': 'integrate(x**2, (x, 0, 3))', 'value': '9'},
    });
    problem.typed = ' 9.0 ';
    expect((problem.numericMatch, problem.graded, problem.score), (true, true, 1.0));
    problem.typed = '10';
    expect(problem.numericMatch, isFalse);
    expect(problem.graded, isFalse); // a mismatch still needs a look: the method may earn partial credit
    problem.selfScore = .5;
    expect(problem.score, .5);
  });

  test('easy app: how a session went', () {
    expect([sessionTier(0, 0), sessionTier(1, 5), sessionTier(3, 5), sessionTier(4, 5), sessionTier(10, 10)], [0, 1, 2, 3, 3]);
  });

  test('importance: college weights on the 1-10 scale, cert readiness weighted by the AI score', () {
    final s10 = Scope({'id': 'a1', 'date': null, 'scope': []}, [], {'k': 8}, schedulerForDate(null), Pace(Pace.defaults));
    expect(s10.weight(card('x', kps: ['k'])), closeTo(.8, 1e-9));
    expect(s10.weight(card('y', kps: ['other'])), closeTo(.6, 1e-9)); // not scored yet
    final s5 = Scope({'id': 'a1', 'date': null, 'scope': []}, [], {'k': 4}, schedulerForDate(null), Pace(Pace.defaults), priorityScale: 5);
    expect(s5.weight(card('x', kps: ['k'])), closeTo(.8, 1e-9)); // older 1-5 scores still read right

    final cert = {
      'id': 'DVA',
      'domains': [
        {'id': '1', 'name': 'Dev', 'weight': 1.0}
      ],
    };
    final known = {...card('known', fsrsState: reviewed(1000, 0)), 'certs': {'DVA': '1'}};
    final fresh = {...card('fresh'), 'certs': {'DVA': '1'}};
    expect(readiness(cert, [known, fresh]).predicted, closeTo(.5, .01)); // unrated: equal weight
    expect(readiness(cert, [known, fresh], importance: {'known': 9, 'fresh': 1}).predicted, closeTo(.9, .01));
    expect(readiness(cert, [known, fresh], importance: {'known': 1, 'fresh': 9}).predicted, closeTo(.1, .01));
  });
}

