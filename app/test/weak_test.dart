import 'package:certdeck/db.dart';
import 'package:certdeck/weak.dart';
import 'package:flutter_test/flutter_test.dart';

Json c(String id, {List<String> tags = const [], bool mis = false, bool leech = false, bool susp = false}) =>
    {'id': id, 'tags': tags, 'fsrs': {'state': 2}, if (mis) 'misconception': true, if (leech) 'leech': true, if (susp) 'suspended': true};
Json r(String id, bool ok, {int ver = 0}) => {'card_id': id, 'correct': ok, 'ver': ver, 'ts': 1};

void main() {
  test('a tag is weak at >= 4 answers and >= 35% missed, counting every version', () {
    final cards = [c('a', tags: ['KMS']), c('b', tags: ['KMS', 'S3'])];
    final rs = [r('a', false), r('a', false, ver: 1), r('b', true), r('b', true, ver: 2), r('b', true)];
    final s = weakSpots(cards, rs).where((w) => w.kind == WeakKind.tag).toList();
    expect(s.map((w) => w.title), ['KMS']); // S3: 3 answers, too few
    expect((s.first.missed, s.first.answered), (2, 5));
    expect(s.first.cardIds.toSet(), {'a', 'b'});
  });
  test('34% missed is not weak', () {
    final rs = [r('a', false), r('a', false), ...List.generate(4, (_) => r('a', true))];
    expect(weakSpots([c('a', tags: ['KMS'])], rs).where((w) => w.kind == WeakKind.tag), isEmpty);
  });
  test('memorized: right on the original, wrong on a rewrite', () {
    final s = weakSpots([c('a'), c('b')], [r('a', true), r('a', false, ver: 1), r('b', false), r('b', false, ver: 1)]);
    expect(s.singleWhere((w) => w.kind == WeakKind.memorized).cardIds, ['a']);
  });
  test('no ver data: no memorized spot', () {
    expect(weakSpots([c('a')], [{'card_id': 'a', 'correct': false, 'ts': 1}]).any((w) => w.kind == WeakKind.memorized), false);
  });
  test('misconceptions and unsuspended leeches', () {
    final s = weakSpots([c('a', mis: true), c('b', leech: true), c('d', leech: true, susp: true)], []);
    expect(s.singleWhere((w) => w.kind == WeakKind.misconception).cardIds, ['a']);
    expect(s.singleWhere((w) => w.kind == WeakKind.leech).cardIds, ['b']);
  });
  test('ai weak areas come from the latest analysis', () {
    final s = weakSpots([], [], analysis: {'weak_areas': [{'topic': 'IAM conditions', 'domain': '2', 'count': 15}]});
    expect(s.single.kind, WeakKind.ai);
    expect(s.single.title, 'IAM conditions');
  });
  test('sorted by severity, empty input is empty', () {
    expect(weakSpots([], []), isEmpty);
    final rs = [...List.generate(6, (_) => r('a', false)), ...List.generate(4, (_) => r('a', true))];
    final s = weakSpots([c('a', tags: ['KMS']), c('m1', mis: true), c('m2', mis: true)], rs,
        analysis: {'weak_areas': [{'topic': 'X'}]});
    expect(s.map((w) => w.kind), [WeakKind.tag, WeakKind.misconception, WeakKind.ai]);
    expect(s.first.severity, 6); // 10 answers, 6 missed: missRate * answered
  });
  test('cards without tags never make a tag spot', () {
    final rs = List.generate(6, (_) => r('a', false));
    expect(weakSpots([c('a')], rs).where((w) => w.kind == WeakKind.tag), isEmpty);
  });
  test('drill: suspended out, due first, then soonest due, capped', () {
    final now = DateTime.now().millisecondsSinceEpoch, day = 86400000;
    Json k(String id, int due, {bool susp = false}) => {'id': id, 'fsrs': {'due': due}, if (susp) 'suspended': true};
    final cards = [k('later', now + 9 * day), k('soon', now + day), k('susp', now - day, susp: true), k('due', now - day), k('other', now - day)];
    const w = WeakSpot(WeakKind.tag, 'KMS', 3, 4, ['later', 'soon', 'susp', 'due']);
    expect(drillQueue(w, cards).map((c) => c['id']), ['due', 'soon', 'later']);
    expect(drillQueue(w, cards, limit: 1).map((c) => c['id']), ['due']);
  });
}
