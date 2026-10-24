import 'db.dart';
import 'logic.dart';

enum WeakKind { tag, memorized, misconception, leech, ai }

class WeakSpot {
  final WeakKind kind;
  final String title;
  final int missed, answered; // tag: misses/answers; others: missed = count, answered = 0
  final List<String> cardIds; // what a Drill/open uses; empty for ai
  final Json? ai; // the analysis weak_areas entry for kind == ai
  const WeakSpot(this.kind, this.title, this.missed, this.answered, this.cardIds, {this.ai});

  double get severity => switch (kind) {
        WeakKind.tag => missed.toDouble(), // missRate * answered
        WeakKind.ai => (6 - ((ai?['rank'] as num?) ?? 5).toInt()).clamp(1, 5).toDouble(), // rank 1 -> 5, competes with counts
        _ => cardIds.length.toDouble(),
      };
}

const weakWindowDays = 14;

List<WeakSpot> weakSpots(List<Json> cards, List<Json> reviews, {Json? analysis}) {
  final byId = {for (final c in cards) c['id'] as String: c};
  final answered = <String, int>{}, missed = <String, int>{};
  final tagCards = <String, Set<String>>{};
  final rightOrig = <String>{}, wrongRewrite = <String>{};
  for (final rv in reviews) {
    final id = rv['card_id'];
    final card = byId[id];
    if (card == null) continue;
    final ok = rv['correct'] == true;
    for (final t in ((card['tags'] as List?) ?? []).cast<String>()) {
      answered[t] = (answered[t] ?? 0) + 1;
      if (!ok) missed[t] = (missed[t] ?? 0) + 1;
      (tagCards[t] ??= {}).add(id);
    }
    final ver = rv['ver'];
    if (ver is int) {
      if (ver == 0 && ok) rightOrig.add(id);
      if (ver >= 1 && !ok) wrongRewrite.add(id);
    }
  }
  final out = <WeakSpot>[
    for (final t in answered.keys)
      if (answered[t]! >= 4 && (missed[t] ?? 0) / answered[t]! >= .35) WeakSpot(WeakKind.tag, t, missed[t] ?? 0, answered[t]!, tagCards[t]!.toList()),
  ];
  void group(WeakKind k, String title, Iterable<String> ids) {
    final l = ids.toList();
    if (l.isNotEmpty) out.add(WeakSpot(k, title, l.length, 0, l));
  }

  group(WeakKind.memorized, 'Memorized', rightOrig.intersection(wrongRewrite));
  group(WeakKind.misconception, 'Misconceptions', [for (final c in cards) if (c['misconception'] == true) c['id'] as String]);
  group(WeakKind.leech, 'Leeches', [for (final c in cards) if (c['leech'] == true && !isSuspended(c)) c['id'] as String]);
  for (final a in ((analysis?['weak_areas'] as List?) ?? []).cast<Json>()) {
    out.add(WeakSpot(WeakKind.ai, '${a['topic']}', 0, 0, const [], ai: a));
  }
  return out..sort((a, b) => b.severity.compareTo(a.severity)); // stable: ties keep tag, memorized, ... order
}

Future<List<WeakSpot>> loadWeakSpots(Json cert) async {
  final cards = await Db.cardsFor(cert['id']);
  final reviews = await Db.reviewsSince(nowMs() - weakWindowDays * dayMs);
  final list = (await Db.query('analysis')).where((a) => a['cert'] == cert['id']).toList()
    ..sort((a, b) => ((b['created_at'] as int?) ?? 0).compareTo((a['created_at'] as int?) ?? 0));
  return weakSpots(cards, reviews, analysis: list.isEmpty ? null : list.first);
}

/// Cards of a weak spot to drill: due (or new) first, then soonest due (least retained); suspended out.
List<Json> drillQueue(WeakSpot w, List<Json> cards, {int limit = 20}) {
  final ids = w.cardIds.toSet();
  final l = cards.where((c) => ids.contains(c['id']) && !isSuspended(c)).toList()
    ..sort((a, b) => dueOf(a).compareTo(dueOf(b))); // due ones have dueOf <= now, so they sort first
  return l.take(limit).toList();
}
