import 'dart:math';

import 'package:fsrs/fsrs.dart' as fsrs;

import 'db.dart';
import 'logic.dart';

/// College study engine: everything here works offline from the local DB.
///
/// Mode by days left before an assessment: sprint (0-3 days: in-session successive relearning, no long
/// intervals), compressed (4-14: FSRS capped at the date, high retention, practice exams), long (>14 or no date:
/// FSRS as for certs plus cumulative review). Cards are ordered by expected marks = priority x (1 - recall).

enum Mode { sprint, compressed, long }

Mode modeFor(int? days) => days == null || days > 14 ? Mode.long : (days <= 3 ? Mode.sprint : Mode.compressed);

int? daysUntil(String? isoDate) {
  final d = DateTime.tryParse(isoDate ?? '');
  if (d == null) return null;
  final n = DateTime.now();
  return DateTime(d.year, d.month, d.day).difference(DateTime(n.year, n.month, n.day)).inDays;
}

String sectionKey(Map s) => '${s['material_id']}/${s['section_id']}';
Set<String> scopeKeys(Json a) => {for (final s in ((a['scope'] as List?) ?? []).cast<Map>()) sectionKey(s)};

Future<List<Json>> courses() async => (await Db.query('course'))..sort((a, b) => ((a['created_at'] as int?) ?? 0).compareTo((b['created_at'] as int?) ?? 0));
Future<List<Json>> courseDocs(String kind, String courseId) => Db.query(kind, where: 'data LIKE ?', args: ['%"course_id":"$courseId"%']);
Future<List<Json>> courseCards(String courseId) => Db.query('card', where: 'data LIKE ?', args: ['%"course":"$courseId"%']);
Future<Json?> ingestOf(String materialId) => Db.get('ingest-$materialId');
Future<Json?> prepOf(String assessmentId) => Db.get('prep-$assessmentId');

/// Assessments that are still ahead (or today), soonest first; proposals the student hasn't confirmed are left out.
Future<List<Json>> upcoming({String? courseId}) async {
  final all = await Db.query('assessment');
  return all.where((a) => (courseId == null || a['course_id'] == courseId) && a['status'] != 'proposed' && (daysUntil(a['date']) ?? 0) >= 0).toList()
    ..sort((a, b) => (daysUntil(a['date']) ?? 9999).compareTo(daysUntil(b['date']) ?? 9999));
}

/// The scheduler for one assessment: retention ramps to 0.95 as the date nears and no interval passes it
/// (the cert rule, applied per assessment).
fsrs.Scheduler schedulerForDate(String? isoDate) => schedulerFor({'exam_date': isoDate});

/// The assessment a card is studied for: the soonest upcoming one whose scope holds the card's section.
Future<Json?> assessmentForCard(Json card) async {
  if (card['course'] == null) return null;
  for (final a in await upcoming(courseId: card['course'])) {
    if (scopeKeys(a).contains(card['section'])) return a;
  }
  return null;
}

/// Seconds a card of this type usually takes this student (median of their own answers), with sane defaults.
class Pace {
  final Map<String, double> seconds;
  Pace(this.seconds);
  static const defaults = {'mcq': 35.0, 'cloze': 20.0, 'basic': 20.0, 'typed': 25.0, 'short': 75.0, 'problem': 200.0, 'ordering': 40.0, 'code': 70.0};

  static Future<Pace> load() async {
    final by = <String, List<int>>{};
    final reviews = await Db.reviewsSince(nowMs() - 60 * dayMs);
    final cards = {for (final c in await Db.query('card')) c['id']: c['type'] as String?};
    for (final r in reviews) {
      final t = cards[r['card_id']], d = r['duration_ms'];
      if (t != null && d is int && d > 2000 && d < 20 * 60000) (by[t] ??= []).add(d);
    }
    return Pace({
      for (final t in defaults.keys)
        t: (by[t]?.length ?? 0) >= 5 ? ((by[t]!..sort())[by[t]!.length ~/ 2] / 1000) : defaults[t]!,
    });
  }

  double of(Json c) => seconds[c['type']] ?? 40;
}

/// Everything the engine needs about one assessment, loaded once.
class Scope {
  final Json assessment;
  final List<Json> cards; // the scope's cards, not suspended
  final Map<String, int> priority; // kp id -> 1..5
  final fsrs.Scheduler scheduler;
  final Pace pace;
  Scope(this.assessment, this.cards, this.priority, this.scheduler, this.pace);

  int? get days => daysUntil(assessment['date']);
  Mode get mode => modeFor(days);

  static Future<Scope> load(Json a) async {
    final keys = scopeKeys(a);
    final cards = (await courseCards(a['course_id'])).where((c) => keys.contains(c['section']) && !isSuspended(c) && c['practice'] == null).toList();
    final prio = ((await Db.get('prio-${a['id']}'))?['scores'] as Map?) ?? {};
    return Scope(a, cards, {for (final e in prio.entries) e.key as String: (e.value as num).toInt()}, schedulerForDate(a['date']), await Pace.load());
  }

  /// 0.2..1: how much this card's points are likely to count on the assessment.
  double weight(Json c) {
    final ids = ((c['kp_ids'] as List?) ?? []).cast<String>();
    final p = ids.isEmpty ? 3 : ids.map((i) => priority[i] ?? 3).reduce(max);
    return p / 5;
  }

  double recall(Json c) => retrievability(scheduler, c);

  /// Expected marks gained by studying this card now.
  double value(Json c) => weight(c) * (1 - recall(c)) + (c['misconception'] == true ? .5 : 0);

  /// Seconds to get the card to "known": a new card needs ~3 presentations (first try + 2 correct recalls).
  double cost(Json c) {
    final r = recall(c);
    return pace.of(c) * (isNew(c) ? 3 : (r < .7 ? 2 : 1.2));
  }

  bool mastered(Json c) => !isNew(c) && recall(c) >= .9 && c['misconception'] != true;
}

/// A time-budgeted session split three ways: master (study now), skim (read the summary), skip (not worth the time).
class Triage {
  final List<Json> master, skim, skip;
  final int minutes;
  Triage(this.master, this.skim, this.skip, this.minutes);
  double get plannedMinutes => 0; // filled by plan(); kept for display
}

/// Picks what to study in [minutes]: greedy by expected marks per second, the relearning of earlier sprint days
/// first, 15% of the time kept for in-session relearning. What doesn't fit is split into skim (still valuable:
/// read its knowledge point on the summary sheet) and skip.
Triage plan(Scope s, int minutes) {
  final budget = minutes * 60 * .85;
  final cands = s.cards.where((c) => s.mode != Mode.sprint || !s.mastered(c) || c['misconception'] == true).toList();
  double ratio(Json c) => s.value(c) / max(1, s.cost(c));
  // Seen-but-shaky cards come first: yesterday's sprint relearned before anything new.
  int tier(Json c) => !isNew(c) && s.recall(c) < .9 ? 0 : 1;
  cands.sort((a, b) {
    final t = tier(a) - tier(b);
    return t != 0 ? t : ratio(b).compareTo(ratio(a));
  });
  final master = <Json>[], rest = <Json>[];
  var used = 0.0;
  for (final c in cands) {
    if (s.value(c) <= 0.01) continue;
    if (used + s.cost(c) <= budget) {
      master.add(c);
      used += s.cost(c);
    } else {
      rest.add(c);
    }
  }
  rest.sort((a, b) => s.value(b).compareTo(s.value(a)));
  final cut = rest.indexWhere((c) => s.weight(c) < .6);
  final skim = cut < 0 ? rest : rest.sublist(0, cut);
  final skip = cut < 0 ? <Json>[] : rest.sublist(cut);
  return Triage(interleave(master), skim, skip, minutes);
}

/// Round-robin across sections so similar cards don't come back to back (interleaving), keeping each section's order.
List<Json> interleave(List<Json> cards) {
  final by = <String, List<Json>>{};
  for (final c in cards) {
    (by[c['section'] ?? ''] ??= []).add(c);
  }
  final out = <Json>[];
  while (by.values.any((l) => l.isNotEmpty)) {
    for (final l in by.values) {
      if (l.isNotEmpty) out.add(l.removeAt(0));
    }
  }
  return out;
}

/// In-session successive relearning: a card is learned after [target] correct recalls in a row, spaced by other
/// cards; a miss brings it back 3 cards later, a correct answer 6 cards later. Cards already well known need one.
class SprintSession implements StudyQueue {
  final List<Json> queue;
  final Map<String, int> streak = {}, target = {};
  int learned = 0;

  SprintSession(List<Json> cards, Scope scope) : queue = [...cards] {
    for (final c in cards) {
      target[c['id']] = scope.mastered(c) ? 1 : 2;
    }
  }

  @override
  int get remaining => queue.length;

  @override
  Json? next() => queue.isEmpty ? null : queue.removeAt(0);

  /// [score] 1 = right, 0..1 = partial (counts as a miss here), 0 = wrong.
  @override
  void answered(Json card, double score) {
    final id = card['id'] as String;
    if (score >= .85) {
      streak[id] = (streak[id] ?? 0) + 1;
      if (streak[id]! >= (target[id] ?? 2)) {
        learned++;
        return;
      }
      queue.insert(min(6, queue.length), card);
    } else {
      streak[id] = 0;
      queue.insert(min(score > 0 ? 4 : 3, queue.length), card);
    }
  }
}

/// Queue for compressed/long mode: due cards (with the assessment's scheduler) plus new cards paced so everything
/// is introduced 2 days before the date (practice exam + final review), best expected marks first, cut to the time.
List<Json> pacedQueue(Scope s, int minutes) {
  final now = nowMs();
  final due = s.cards.where((c) => !isNew(c) && dueOf(c) <= now).toList();
  final news = s.cards.where(isNew).toList()..sort((a, b) => s.value(b).compareTo(s.value(a)));
  final d = s.days;
  final perDay = d == null ? 20 : (news.length / max(1, d - 2)).ceil();
  final pick = [...due, ...news.take(perDay)]..sort((a, b) => s.value(b).compareTo(s.value(a)));
  final out = <Json>[];
  var used = 0.0;
  for (final c in pick) {
    if (used + s.pace.of(c) * (isNew(c) ? 2 : 1) > minutes * 60) break;
    out.add(c);
    used += s.pace.of(c) * (isNew(c) ? 2 : 1);
  }
  return interleave(out);
}

/// Exam-morning check: ~10 minutes of the highest-yield weak cards and misconceptions, nothing new.
List<Json> morningCheck(Scope s) {
  final weak = s.cards.where((c) => !isNew(c) && (c['misconception'] == true || s.recall(c) < .95)).toList()
    ..sort((a, b) => s.value(b).compareTo(s.value(a)));
  final out = <Json>[];
  var used = 0.0;
  for (final c in weak) {
    if (used + s.pace.of(c) > 600) continue;
    out.add(c);
    used += s.pace.of(c);
  }
  return out;
}

class SectionCoverage {
  final String key;
  int cards = 0, seen = 0, mastered = 0;
  SectionCoverage(this.key);
}

class Readiness2 {
  final Map<String, SectionCoverage> sections;
  final double recall; // priority-weighted mean recall, new cards count 0
  final double? practice; // the latest practice exam's score in the last 7 days
  final double low, high; // predicted mark range, 0..1
  final int reviews;
  Readiness2(this.sections, this.recall, this.practice, this.low, this.high, this.reviews);
  double get mid => (low + high) / 2;
}

/// Coverage per section, weighted recall, the last practice exam, and an honest predicted-mark range.
Future<Readiness2> readinessOf(Scope s) async {
  final secs = <String, SectionCoverage>{for (final k in scopeKeys(s.assessment)) k: SectionCoverage(k)};
  var wSum = 0.0, rSum = 0.0;
  for (final c in s.cards) {
    final sc = secs[c['section']] ??= SectionCoverage(c['section'] ?? '');
    sc.cards++;
    if (!isNew(c)) sc.seen++;
    if (s.mastered(c)) sc.mastered++;
    wSum += s.weight(c);
    rSum += s.weight(c) * s.recall(c);
  }
  final recall = wSum == 0 ? 0.0 : rSum / wSum;
  final exams = (await Db.query('exam')).where((e) => e['assessment_id'] == s.assessment['id'] && (e['finished_at'] ?? 0) > nowMs() - 7 * dayMs).toList()
    ..sort((a, b) => (b['finished_at'] as int).compareTo(a['finished_at'] as int));
  final practice = exams.isEmpty ? null : (exams.first['score_pct'] as num).toDouble();
  final ids = {for (final c in s.cards) c['id']};
  final reviews = (await Db.reviewsSince(nowMs() - 30 * dayMs)).where((r) => ids.contains(r['card_id'])).length;
  final point = practice == null ? recall : .5 * recall + .5 * practice;
  // Wider when there's little evidence: +-8 points at best, up to +-33 with no reviews.
  final spread = .08 + .25 / sqrt(reviews / 10 + 1);
  return Readiness2(secs, recall, practice, max(0, point - spread), min(1, point + spread), reviews);
}

const maxDailyMinutes = 120;

class PlanItem {
  final Json assessment;
  final String course;
  final int minutes;
  final Mode mode;
  final bool behind, practiceDay, morning;
  PlanItem(this.assessment, this.course, this.minutes, this.mode, {this.behind = false, this.practiceDay = false, this.morning = false});
}

/// Today's plan across courses: minutes per upcoming assessment (next 3 weeks) so its remaining work is spread over
/// the days left. Behind = yesterday's planned time wasn't studied (the plan and reminders escalate).
Future<List<PlanItem>> todayPlan({DateTime? at}) async {
  final out = <PlanItem>[];
  final names = {for (final c in await courses()) c['id']: (c['code'] ?? c['name'] ?? '').toString()};
  final yesterday = await Db.reviewsSince(startOfToday() - dayMs);
  for (final a in await upcoming()) {
    final s = await Scope.load(a);
    final d = s.days;
    if (d == null || d > 21 || s.cards.isEmpty) continue;
    if (d == 0) {
      out.add(PlanItem(a, names[a['course_id']] ?? '', 10, Mode.sprint, morning: true));
      continue;
    }
    var work = 0.0;
    for (final c in s.cards) {
      if (s.mastered(c)) continue;
      work += isNew(c) ? s.cost(c) : s.pace.of(c) * 1.5;
    }
    // Spread over the days left, at most 2 hours a day: what doesn't fit is triaged by expected marks.
    final minutes = min(maxDailyMinutes, (work / 60 / max(1, d)).ceil());
    if (minutes == 0) continue;
    final ids = {for (final c in s.cards) c['id']};
    final studied = yesterday.where((r) => ids.contains(r['card_id']) && (r['ts'] as int) < startOfToday()).fold<int>(0, (t, r) => t + ((r['duration_ms'] as int?) ?? 0)) / 60000;
    // Behind only if there was a plan all of yesterday (the cards existed) and under half of it got done.
    final hadPlan = s.cards.any((c) => ((c['created_at'] as int?) ?? nowMs()) < startOfToday() - dayMs);
    final behind = hadPlan && d <= 7 && studied < minutes * .5;
    out.add(PlanItem(a, names[a['course_id']] ?? '', max(10, minutes), s.mode, behind: behind, practiceDay: s.mode == Mode.compressed && (d == 2 || d == 7)));
  }
  return out;
}

/// The review log's score for a graded answer: 1 right, 0..1 partial, 0 wrong.
fsrs.Rating ratingForScore(Conf conf, double score, int sureStreak) =>
    score >= .85 ? ratingFor(conf, true, sureStreak) : (score >= .4 ? fsrs.Rating.hard : fsrs.Rating.again);
