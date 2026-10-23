import 'dart:math';

import 'package:fsrs/fsrs.dart' as fsrs;

import 'college_logic.dart';
import 'db.dart';

const dayMs = 86400000;

enum Conf { guess, unsure, sure }

const defaultSettings = {'new_per_day': 20, 'max_reviews_per_day': 200, 'leech_threshold': 5, 'active_cert': 'DVA-C02', 'session_minutes': 10};

/// Desired-retention shift for what the student is aiming at (the setup question): pass / good grade / top grade.
double goalRetentionAdj(String? goal) => switch (goal) { 'pass' => -.03, 'top' => .02, _ => 0 };

/// Official formats, checked against the exam guides on 2026-10-12 (see DECISIONS.md).
final defaultCerts = <Json>[
  {
    'id': 'DVA-C02',
    'code': 'DVA-C02',
    'name': 'AWS Certified Developer – Associate',
    'exam_date': null,
    'active': true,
    'exam': {'questions': 65, 'minutes': 130, 'pass_pct': 72, 'scaled': true, 'kind': 'mcq'},
    'domains': [
      {'id': '1', 'name': 'Development with AWS Services', 'weight': .32},
      {'id': '2', 'name': 'Security', 'weight': .26},
      {'id': '3', 'name': 'Deployment', 'weight': .24},
      {'id': '4', 'name': 'Troubleshooting and Optimization', 'weight': .18},
    ],
  },
  {
    'id': 'SAA-C03',
    'code': 'SAA-C03',
    'name': 'AWS Certified Solutions Architect – Associate',
    'exam_date': null,
    'active': false,
    'exam': {'questions': 65, 'minutes': 130, 'pass_pct': 72, 'scaled': true, 'kind': 'mcq'},
    'domains': [
      {'id': '1', 'name': 'Design Secure Architectures', 'weight': .30},
      {'id': '2', 'name': 'Design Resilient Architectures', 'weight': .26},
      {'id': '3', 'name': 'Design High-Performing Architectures', 'weight': .24},
      {'id': '4', 'name': 'Design Cost-Optimized Architectures', 'weight': .20},
    ],
  },
  {
    'id': 'CKAD',
    'code': 'CKAD',
    'name': 'Certified Kubernetes Application Developer',
    'exam_date': null,
    'active': false,
    'exam': {'questions': 17, 'minutes': 120, 'pass_pct': 66, 'scaled': false, 'kind': 'performance'},
    'domains': [
      {'id': '1', 'name': 'Application Design and Build', 'weight': .20},
      {'id': '2', 'name': 'Application Deployment', 'weight': .20},
      {'id': '3', 'name': 'Application Observability and Maintenance', 'weight': .15},
      {'id': '4', 'name': 'Application Environment, Configuration and Security', 'weight': .25},
      {'id': '5', 'name': 'Services and Networking', 'weight': .20},
    ],
  },
];

/// In-memory copies of the small config docs; reloaded after local edits and syncs.
class App {
  static Json settings = {...defaultSettings};
  static List<Json> certs = [];
  static List<double>? params;

  /// The server's autopilot doc (session length, new cards/day, retention shift, load): tuned from the student's own
  /// data, never edited by them. The owner can switch it off in Settings.
  static Json autopilot = {};
  static bool get autopilotOn => !isOwner || settings['autopilot'] != false;
  static num? _auto(String k) => autopilotOn ? autopilot[k] as num? : null;

  /// Minutes in one study session: the autopilot's, else the setup answer (default 10).
  /// The student's own pick wins until the autopilot's next update.
  static int get sessionMinutes {
    final chosen = (settings['session_minutes_set_at'] as num?) ?? 0;
    final auto = (autopilot['updated_at'] as num?) ?? 0;
    final fromAuto = auto > chosen ? _auto('session_minutes') : null;
    return (fromAuto ?? settings['session_minutes'] as num? ?? 10).toInt().clamp(5, 30);
  }

  /// The AI supervisor's multiplier on the amount of work (0.8..1.2): applied to new cards and to the session's minutes.
  static double get loadFactor => (_auto('load_factor')?.toDouble() ?? 1.0).clamp(.8, 1.2);
  /// New cards per day: the owner's own number wins until the autopilot's next update (then the autopilot starts from it).
  static int get newPerDay {
    final chosen = (settings['new_per_day_set_at'] as num?) ?? 0;
    final auto = (autopilot['updated_at'] as num?) ?? 0;
    final fromAuto = auto > chosen ? _auto('new_per_day') : null;
    return fromAuto == null ? setting('new_per_day') : (fromAuto * loadFactor).round().clamp(1, 100);
  }
  /// [sessionMinutes] scaled by [loadFactor], the time a session is built for.
  static int get sessionBudget => (sessionMinutes * loadFactor).round().clamp(3, 36);
  /// Goal shift plus the autopilot's, kept inside 0.80..0.97 when applied in [schedulerFor].
  static double get retentionAdj => goalRetentionAdj(settings['goal'] as String?) + (_auto('retention_adj')?.toDouble() ?? 0);

  /// 'owner' (certs + college) or 'student' (college only), from GET me; owner until the server says otherwise.
  static String role = 'owner';
  static bool get isOwner => role != 'student';
  static String get lang => settings['lang'] == 'ar' ? 'ar' : 'en';

  static Future<void> init() async {
    await Db.seed('settings', {'id': 'settings', ...defaultSettings});
    for (final c in defaultCerts) {
      await Db.seed('cert', c);
    }
    role = await Db.meta('role') ?? 'owner';
    await reload();
  }

  static Future<void> reload() async {
    settings = {...defaultSettings, ...?await Db.get('settings')};
    certs = await Db.query('cert', orderBy: 'id');
    autopilot = await Db.get('autopilot') ?? {};
    final p =(await Db.get('fsrs_params'))?['parameters'];
    params = p is List && p.length == fsrs.defaultParameters.length ? p.map((e) => (e as num).toDouble()).toList() : null;
  }

  static Json get cert => certs.firstWhere((c) => c['id'] == settings['active_cert'], orElse: () => certs.first);
  static int setting(String k) => (settings[k] as num?)?.toInt() ?? defaultSettings[k] as int;

  static Future<void> saveSettings() async {
    await Db.put('settings', settings..['id'] = 'settings');
    await reload();
  }
}

String domainOf(Json card, Json cert) => ((card['certs'] as Map?) ?? {})[cert['id']]?.toString() ?? '';
String domainName(Json cert, String id) =>
    ((cert['domains'] as List).cast<Map>().firstWhere((d) => d['id'] == id, orElse: () => {'name': 'Untagged'}))['name'];
bool isNew(Json c) => c['fsrs'] == null;

/// "Rotate card versions": the original and its rewritten versions take turns, one per review
/// (card['ver'] = the one shown last; a missed card's retry gets the next). Scheduling stays on the original.
(int, Json) pickVersion(Json card, List versions) {
  if (versions.isEmpty) return (0, card);
  final i = (((card['ver'] as int?) ?? -1) + 1) % (versions.length + 1);
  return (i, i == 0 ? card : {...card, ...Map<String, dynamic>.from(versions[i - 1] as Map)});
}
bool isSuspended(Json c) => c['suspended'] == true;
int dueOf(Json c) => (c['fsrs']?['due'] as int?) ?? 0;

int? daysToExam(Json cert) {
  final d = DateTime.tryParse(cert['exam_date'] ?? '');
  if (d == null) return null;
  final now = DateTime.now();
  return d.difference(DateTime(now.year, now.month, now.day)).inDays;
}

/// Desired retention climbs from 0.90 (≥60 days out) to 0.95 on exam day;
/// intervals are capped so every card comes back before the exam.
fsrs.Scheduler schedulerFor(Json cert) {
  final d = daysToExam(cert);
  final retention = ((d == null ? 0.9 : 0.95 - 0.05 * min(max(d, 0), 60) / 60) + App.retentionAdj).clamp(.80, .97);
  final maxIv = d != null && d > 0 ? d : 36500;
  try {
    return fsrs.Scheduler(parameters: App.params ?? fsrs.defaultParameters, desiredRetention: retention, maximumInterval: maxIv);
  } catch (_) {
    return fsrs.Scheduler(desiredRetention: retention, maximumInterval: maxIv); // optimizer output out of bounds
  }
}

DateTime _utc(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

fsrs.Card toFsrs(Json c) {
  final f = c['fsrs'] as Map?;
  if (f == null) return fsrs.Card(cardId: 0, due: DateTime.now().toUtc());
  return fsrs.Card(
    cardId: 0,
    state: fsrs.State.fromValue(f['state'] as int),
    step: f['step'] as int?,
    stability: (f['stability'] as num?)?.toDouble(),
    difficulty: (f['difficulty'] as num?)?.toDouble(),
    due: _utc(f['due'] as int),
    lastReview: f['last_review'] == null ? null : _utc(f['last_review'] as int),
  );
}

Json fromFsrs(fsrs.Card k) => {
      'state': k.state.value,
      'step': k.step,
      'stability': k.stability,
      'difficulty': k.difficulty,
      'due': k.due.millisecondsSinceEpoch,
      'last_review': k.lastReview?.millisecondsSinceEpoch,
    };

double retrievability(fsrs.Scheduler s, Json c, [DateTime? at]) =>
    isNew(c) ? 0 : s.getCardRetrievability(toFsrs(c), currentDateTime: (at ?? DateTime.now()).toUtc());

/// Confidence + correctness → FSRS rating (SPEC "Study session").
/// Sure+correct is Good, or Easy when the previous answer was also Sure+correct.
fsrs.Rating ratingFor(Conf conf, bool correct, int sureStreak) {
  if (!correct) return fsrs.Rating.again;
  if (conf != Conf.sure) return fsrs.Rating.hard;
  return sureStreak >= 1 ? fsrs.Rating.easy : fsrs.Rating.good;
}

/// A new card for a student who said they are new to the subject (setup): read it first, then it comes back as a
/// question. Everyone else guesses first (the pretesting effect).
bool studyFirst(Json card) => isNew(card) && App.settings['expertise'] == 'new';

/// How many answers were rated Sure, and how many of those were right (the calibration line at the end of a session).
({int sure, int sureRight}) sureStats(Iterable<(Conf, bool)> answers) {
  final sure = answers.where((a) => a.$1 == Conf.sure);
  return (sure: sure.length, sureRight: sure.where((a) => a.$2).length);
}

/// Schedules the card, appends a review log, saves both. Returns the updated card.
/// [score] (0..1) is set for graded answers (short answers, problems): partial credit rates Hard.
/// Course cards are scheduled for the assessment they're studied for (its date caps the intervals).
Future<Json> recordAnswer(Json card,
    {required Conf conf, required bool correct, required String source, int? durationMs, Object? answer, double? score, fsrs.Scheduler? scheduler, bool studyFirst = false, String? errorType}) async {
  final now = DateTime.now().toUtc();
  final streak = (card['sure_streak'] as int?) ?? 0;
  final rating = score == null ? ratingFor(conf, correct, streak) : ratingForScore(conf, score, streak);
  correct = score == null ? correct : score >= .85;
  final before = toFsrs(card);
  final wasNew = isNew(card);
  final misconception = conf == Conf.sure && (score == null ? !correct : score < .4);
  scheduler ??= card['course'] != null ? schedulerForDate((await assessmentForCard(card))?['date']) : schedulerFor(App.cert);
  final f = fromFsrs(scheduler.reviewCard(before, rating, reviewDateTime: now).card);

  if (rating == fsrs.Rating.again && before.state == fsrs.State.review) card['lapses'] = ((card['lapses'] as int?) ?? 0) + 1;
  card['sure_streak'] = conf == Conf.sure && correct ? streak + 1 : 0;
  if (misconception) {
    card['misconception'] = true;
  } else if (card['sure_streak'] >= 2) {
    card['misconception'] = false;
  }
  // Misconceptions come back within a day until answered Sure+correct twice in a row.
  if (card['misconception'] == true) f['due'] = min(f['due'] as int, now.millisecondsSinceEpoch + dayMs);
  card['fsrs'] = f;
  card['new'] = false;
  if (((card['lapses'] as int?) ?? 0) >= App.setting('leech_threshold')) card['leech'] = true;

  await Db.put('card', card);
  await Db.put('review', {
    'card_id': card['id'],
    'ts': now.millisecondsSinceEpoch,
    'rating': rating.value,
    'confidence': conf.name,
    'correct': correct,
    'misconception': misconception,
    'duration_ms': durationMs,
    'source': source,
    'was_new': wasNew,
    if (studyFirst) 'study_first': true,
    if (errorType != null && errorType.isNotEmpty) 'error_type': errorType,
    if (answer != null) 'answer': answer,
    if (score != null) 'score': score,
  });
  return card;
}

/// What a study screen pulls cards from: the cert/FSRS session or the college sprint loop.
abstract class StudyQueue {
  Json? next();
  /// [score] 1 = right, 0..1 partial, 0 wrong.
  void answered(Json card, double score);
  int get remaining;
}

int startOfToday() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
}

/// New-card pacing: the user's daily limit, raised when needed so every new card of the
/// active cert is introduced a buffer (≤14 days) before the exam. Domains are interleaved by
/// official weight in [orderNew].
({int limit, int paced, int remaining, int? days}) newPlan(Json cert, List<Json> cards) {
  final base = App.newPerDay;
  final remaining = cards.where((c) => isNew(c) && !isSuspended(c)).length;
  final d = daysToExam(cert);
  if (d == null || d <= 0 || remaining == 0) return (limit: base, paced: 0, remaining: remaining, days: d);
  final buffer = min(14, d ~/ 4);
  final paced = (remaining / max(1, d - buffer)).ceil();
  return (limit: max(base, paced), paced: paced, remaining: remaining, days: d);
}

/// Greedy weighted interleave: next new card comes from the domain whose introduced share
/// lags its exam weight the most.
List<Json> orderNew(List<Json> cards, Json cert) {
  final pools = <String, List<Json>>{};
  final introduced = <String, int>{};
  for (final c in cards.where((c) => !isSuspended(c))) {
    final d = domainOf(c, cert);
    if (isNew(c)) {
      (pools[d] ??= []).add(c);
    } else {
      introduced[d] = (introduced[d] ?? 0) + 1;
    }
  }
  for (final p in pools.values) {
    p.sort((a, b) => ((a['created_at'] as int?) ?? 0).compareTo((b['created_at'] as int?) ?? 0));
  }
  final weight = {for (final d in (cert['domains'] as List)) d['id'] as String: (d['weight'] as num).toDouble()};
  final out = <Json>[];
  while (pools.values.any((p) => p.isNotEmpty)) {
    final d = pools.keys
        .where((k) => pools[k]!.isNotEmpty)
        .reduce((a, b) => (introduced[a] ?? 0) / (weight[a] ?? .05) <= (introduced[b] ?? 0) / (weight[b] ?? .05) ? a : b);
    out.add(pools[d]!.removeAt(0));
    introduced[d] = (introduced[d] ?? 0) + 1;
  }
  return out;
}

class TodayStats {
  final int due, newAvailable, newDone, reviewsDone;
  final ({int limit, int paced, int remaining, int? days}) plan;
  TodayStats(this.due, this.newAvailable, this.newDone, this.reviewsDone, this.plan);
}

/// Seconds one card usually takes this student (median of their own answers in the last 60 days), 30 if unknown.
Future<double> avgCardSeconds() async {
  final ds = [
    for (final r in await Db.reviewsSince(nowMs() - 60 * dayMs))
      if (r['duration_ms'] is int && r['duration_ms'] > 2000 && r['duration_ms'] < 20 * 60000) r['duration_ms'] as int
  ]..sort();
  return ds.length < 10 ? 30 : ds[ds.length ~/ 2] / 1000;
}

/// The first cards of [queue] that fit in [minutes] (a new card takes about twice as long), order kept; always at least one.
List<Json> capByTime(List<Json> queue, int minutes, double secondsPerCard) {
  final out = <Json>[];
  var used = 0.0;
  for (final c in queue) {
    final cost = secondsPerCard * (isNew(c) ? 2 : 1);
    if (out.isNotEmpty && used + cost > minutes * 60) break;
    out.add(c);
    used += cost;
  }
  return out;
}

/// Today's cards, one session at a time: [minutes] of work (the session length), the most valuable first. Studying again
/// builds the next batch, because answered cards are no longer due and new ones are counted in newDone.
Future<(List<Json>, TodayStats)> buildQueue(Json cert, {int? minutes}) async {
  final cards = await Db.cardsFor(cert['id']);
  final today = await Db.reviewsSince(startOfToday());
  final newDone = today.where((r) => r['was_new'] == true && r['source'] != 'exam').length;
  final reviewsDone = today.where((r) => r['was_new'] != true && r['source'] == 'study').length;
  final now = nowMs();
  final sched = schedulerFor(cert);
  final imp = await importanceFor(cert['id']);
  // Learning cards first, then what is worth most now: importance x forgotten (a big backlog is cut to the best, not the oldest).
  double value(Json c) =>
      (imp[c['id']] ?? 5) / 10 * (1 - retrievability(sched, c)) + (c['misconception'] == true ? .5 : 0) + ((c['priority'] as int?) ?? 0) * .05;
  int rank(Json c) => c['fsrs']['state'] != 2 ? 1 : 0;
  final due = cards.where((c) => !isNew(c) && !isSuspended(c) && dueOf(c) <= now).toList()
    ..sort((a, b) {
      final r = rank(b) - rank(a);
      return r != 0 ? r : value(b).compareTo(value(a));
    });
  final reviews = due.take(max(0, App.setting('max_reviews_per_day') - reviewsDone)).toList();
  final plan = newPlan(cert, cards);
  final news = orderNew(cards, cert).take(max(0, plan.limit - newDone)).toList();
  final queue = mixByTime(reviews, news, minutes ?? App.sessionBudget, await avgCardSeconds());
  return (queue, TodayStats(due.length, news.length, newDone, reviewsDone, plan));
}

/// A session of [minutes] where unseen cards get at least [newShare] of the time (they hold what the student does not
/// know yet, so known cards must not push them out), the rest going to [reviews] in their order. New cards come first. A new card takes about twice as long as a review.
List<Json> mixByTime(List<Json> reviews, List<Json> news, int minutes, double secondsPerCard, {double newShare = .8}) {
  final budget = minutes * 60.0, newCost = secondsPerCard * 2;
  final takeNew = <Json>[];
  var used = 0.0;
  for (final c in news) {
    if (takeNew.isNotEmpty && used + newCost > budget * newShare) break;
    takeNew.add(c);
    used += newCost;
  }
  final takeRev = <Json>[];
  for (final c in reviews) {
    if (takeRev.isNotEmpty && used + secondsPerCard > budget) break;
    takeRev.add(c);
    used += secondsPerCard;
  }
  // Time the reviews could not use (few due) goes to more new cards.
  for (final c in news.skip(takeNew.length)) {
    if (used + newCost > budget) break;
    takeNew.add(c);
    used += newCost;
  }
  return [...takeNew, ...takeRev];
}

/// Studying more than today's plan: the daily new-card limit is ignored and cards that are not due yet come in, the most
/// forgotten first (an early review is fine for FSRS). Never empty while the cert has cards that are not at 97% recall.
Future<List<Json>> buildExtraQueue(Json cert, {int? minutes}) async {
  final cards = await Db.cardsFor(cert['id']);
  final s = schedulerFor(cert);
  final imp = await importanceFor(cert['id']);
  final now = nowMs();
  double value(Json c) => (imp[c['id']] ?? 5) / 10 * (1 - retrievability(s, c)) + (c['misconception'] == true ? .5 : 0);
  final ahead = cards.where((c) => !isNew(c) && !isSuspended(c) && dueOf(c) > now && retrievability(s, c) < .97).toList()
    ..sort((a, b) => value(b).compareTo(value(a)));
  final news = orderNew(cards, cert);
  // Two reviews, then a new card, so extra time still goes mostly to what is slipping.
  final queue = <Json>[];
  var ni = 0;
  for (var i = 0; i < ahead.length; i++) {
    queue.add(ahead[i]);
    if ((i + 1) % 2 == 0 && ni < news.length) queue.add(news[ni++]);
  }
  queue.addAll(news.skip(ni));
  return capByTime(queue, minutes ?? App.sessionBudget, await avgCardSeconds());
}

/// Weak-area / final-days review: misconceptions first, then the weakest domains' least
/// retained cards, regardless of due date.
Future<List<Json>> buildCramQueue(Json cert, {int limit = 40}) async {
  final cards = (await Db.cardsFor(cert['id'])).where((c) => !isNew(c) && !isSuspended(c)).toList();
  final s = schedulerFor(cert);
  final r = readiness(cert, await Db.cardsFor(cert['id']), importance: await importanceFor(cert['id']));
  final weakDomains = (r.byDomain.entries.toList()..sort((a, b) => a.value.compareTo(b.value))).take(2).map((e) => e.key).toSet();
  double score(Json c) =>
      (c['misconception'] == true ? -2 : 0) +
      (c['leech'] == true ? -1 : 0) +
      (weakDomains.contains(domainOf(c, cert)) ? -.5 : 0) +
      retrievability(s, c);
  cards.sort((a, b) => score(a).compareTo(score(b)));
  return cards.where((c) => retrievability(s, c) < .95 || c['misconception'] == true).take(limit).toList();
}

class Readiness {
  final Map<String, double> byDomain;
  final Map<String, int> counts;
  final double predicted;
  Readiness(this.byDomain, this.counts, this.predicted);
}

/// The AI's exam importance per card (1..10, `importance-<cert>` doc from the server); empty until rated.
Future<Map<String, int>> importanceFor(String certId) async => {
      for (final e in (((await Db.get('importance-$certId'))?['scores'] as Map?) ?? {}).entries)
        e.key as String: ((e.value as List).first as num).toInt(),
    };

/// Per-domain readiness = mean recall probability of the domain's cards (new cards count 0), each card weighted by
/// its exam importance (unrated: 5 of 10); predicted score = exam-weighted sum.
Readiness readiness(Json cert, List<Json> cards, {DateTime? at, Map<String, int> importance = const {}}) {
  final s = schedulerFor(cert);
  final by = <String, double>{}, counts = <String, int>{};
  var predicted = 0.0;
  for (final d in cert['domains'] as List) {
    final list = cards.where((c) => !isSuspended(c) && domainOf(c, cert) == d['id']).toList();
    var wSum = 0.0, rSum = 0.0;
    for (final c in list) {
      final w = (importance[c['id']] ?? 5).toDouble();
      wSum += w;
      rSum += w * retrievability(s, c, at);
    }
    final r = wSum == 0 ? 0.0 : rSum / wSum;
    by[d['id']] = r;
    counts[d['id']] = list.length;
    predicted += r * (d['weight'] as num);
  }
  return Readiness(by, counts, predicted);
}

// ---- AI overrides: bounded, logged, reversible ----

Future<void> applyPendingOverrides() async {
  for (final o in await Db.query('override')) {
    if (o['applied_at'] == null && o['reverted_at'] == null) await applyOverride(o);
  }
}

Future<void> applyOverride(Json o) async {
  final now = nowMs();
  final before = <String, dynamic>{};
  final d = daysToExam(App.cert);
  for (final id in ((o['card_ids'] as List?) ?? []).cast<String>()) {
    final c = await Db.get(id);
    if (c == null) continue;
    before[id] = {'due': c['fsrs']?['due'], 'priority': c['priority'] ?? 0};
    if (c['fsrs'] != null) {
      var due = dueOf(c);
      if (o['due_now'] == true) due = now;
      final shift = o['due_shift_days'] as int?;
      if (shift != null) {
        due = max(now, due + shift.clamp(-30, 30) * dayMs);
        if (shift > 0 && d != null && d > 1) due = min(due, now + (d - 1) * dayMs); // never past the exam
      }
      c['fsrs']['due'] = due;
    }
    if (o['priority'] != null) c['priority'] = (o['priority'] as int).clamp(-2, 2);
    c['overrides'] = [...((c['overrides'] as List?) ?? []), o['id']];
    await Db.put('card', c);
  }
  await Db.put(
      'override',
      o
        ..['applied_at'] = now
        ..['before'] = before);
}

Future<void> revertOverride(Json o) async {
  final applied = (o['applied_at'] as int?) ?? 0;
  for (final MapEntry(:key, :value) in ((o['before'] as Map?) ?? {}).entries) {
    final c = await Db.get(key);
    if (c == null) continue;
    final reviewedSince = ((c['fsrs']?['last_review'] as int?) ?? 0) > applied;
    if (c['fsrs'] != null && !reviewedSince && value['due'] != null) c['fsrs']['due'] = value['due'];
    c['priority'] = value['priority'] ?? 0;
    await Db.put('card', c);
  }
  await Db.put('override', o..['reverted_at'] = nowMs());
}

// ---- lenient typed-answer matching ----

String normAnswer(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'''[`"'“”‘’]'''), '')
    .replaceAll(RegExp(r'[_\-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'[.;,!?:]+$'), '');

int levenshtein(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = [i, ...List.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Case/quote/punctuation-insensitive, hyphen≈space, and ~12% typo tolerance (exact for ≤4 chars).
bool lenientMatch(String input, Iterable<String> answers) {
  final a = normAnswer(input);
  if (a.isEmpty) return false;
  return answers.any((ans) {
    // Spaces are ignored too, so "generate data key" matches GenerateDataKey.
    final b = normAnswer(ans).replaceAll(' ', ''), x = a.replaceAll(' ', '');
    return x == b || (b.length > 4 && levenshtein(x, b) <= max(1, (b.length * .12).floor()));
  });
}

// ---- AI generation follow-ups (the app is the only writer of existing cards) ----

/// Adds the cert/domain the AI suggested to existing cards, so they count for that cert and aren't re-taught.
Future<int> applyRetags(List? retag) async {
  var n = 0;
  for (final r in (retag ?? []).cast<Map>()) {
    final c = await Db.get(r['card_id']);
    if (c == null) continue;
    c['certs'] = {...((c['certs'] as Map?) ?? {}), r['cert']: r['domain']};
    await Db.put('card', c);
    n++;
  }
  return n;
}

/// Background (Batch API) jobs the server finished: apply their retags and diagrams once.
Future<void> applyFinishedJobs() async {
  for (final j in await Db.query('job')) {
    if (j['status'] != 'done') continue;
    if (j['applied_at'] == null) {
      await applyRetags(j['retag'] as List?);
      await Db.put('job', j..['applied_at'] = nowMs());
    }
    // Own marker: builds from before diagrams set applied_at without attaching them.
    if (j['diagrams'] != null && j['diagrams_applied_at'] == null) {
      await applyDiagrams(j['diagrams'] as List?);
      await Db.put('job', j..['diagrams_applied_at'] = nowMs());
    }
  }
}

/// Adds server-drawn diagrams to their cards' answer images.
Future<void> applyDiagrams(List? diagrams) async {
  for (final d in (diagrams ?? []).cast<Map>()) {
    final c = await Db.get(d['card_id']);
    final images = ((c?['answer_images'] as List?) ?? []).cast<String>();
    if (c == null || images.contains(d['image'])) continue;
    await Db.put('card', c..['answer_images'] = [...images, d['image']]);
  }
}

Future<bool> hasQueuedJobs() async => (await Db.query('job')).any((j) => j['status'] == 'queued');

/// The server is working for us right now (a material being processed, an assessment being prepared): its
/// progress and results arrive by sync, so poll often.
Future<bool> serverBusy() async =>
    (await Db.query('prep')).any((p) => const {'queued', 'running'}.contains(p['status'])) ||
    (await Db.query('ingest')).any((i) => const {'queued', 'converting', 'mapping'}.contains(i['status']));

/// Waiting on the Batch API (background cards or a preparation): results come within the hour, poll gently.
Future<bool> serverWaiting() async => await hasQueuedJobs() || (await Db.query('prep')).any((p) => p['status'] == 'waiting');
