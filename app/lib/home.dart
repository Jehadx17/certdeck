import 'package:flutter/material.dart';

import 'api.dart';
import 'ai.dart';
import 'exam.dart';
import 'focus.dart';
import 'i18n.dart';
import 'weak.dart';
import 'db.dart';
import 'logic.dart';
import 'stats.dart';
import 'study.dart';
import 'widgets.dart';

/// One cert session (about [App.sessionMinutes] minutes); "Do more" at the end builds the next batch.
Future<void> studyCert(BuildContext context, List<Json> queue) => Navigator.push(
    context,
    MaterialPageRoute(
        builder: (_) => StudyScreen(queue, onMore: () async {
              var (next, _) = await buildQueue(App.cert);
              if (next.isEmpty) next = await buildExtraQueue(App.cert); // today's plan is done: keep going if you want
              if (!context.mounted) return;
              if (next.isEmpty) return toast(context, 'Nothing left to study. Everything is fresh.');
              studyCert(context, next);
            })));

/// A session of unseen cards only, re-ranked on every "Do more".
Future<void> studyNewCards(BuildContext context) async {
  final q = await buildNewQueue(App.cert);
  if (!context.mounted) return;
  if (q.isEmpty) return toast(context, t('Nothing left to study. Everything is fresh.'));
  await Navigator.push(
      context, MaterialPageRoute(builder: (_) => StudyScreen(q, title: t('New cards only'), newOnly: true, onMore: () => studyNewCards(context))));
}

/// Ticks the topic tags covered in today's course sections: their unseen cards come first today, past the daily limit.
Future<void> pickStudiedTags(BuildContext context) async {
  final tags = {for (final c in await Db.cardsFor(App.cert['id'])) ...((c['tags'] as List?) ?? []).cast<String>()}.toList()..sort();
  final picked = App.studiedTags;
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
                title: Text(t('What did you study today?')),
                content: SingleChildScrollView(
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final g in tags)
                    FilterChip(
                        label: Text(g),
                        selected: picked.contains(g),
                        onSelected: (on) => setState(() => on ? picked.add(g) : picked.remove(g))),
                ])),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Save'))),
                ],
              )));
  if (ok != true) return;
  App.settings['studied_tags'] = picked.toList();
  App.settings['studied_on'] = startOfToday();
  await App.saveSettings();
}

/// Today: progress ring, exam countdown, the study button, and the weak spots to fix first.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  Future<(List<Json>, TodayStats, int, List<WeakSpot>)> _load() async {
    final cert = App.cert;
    final (queue, stats) = await buildQueue(cert);
    final done = (await Db.reviewsSince(startOfToday())).where((r) => r['source'] == 'study').map((r) => r['card_id']).toSet().length;
    return (queue, stats, done, await loadWeakSpots(cert));
  }

  void _push(BuildContext context, Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(color: cs.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('CertDeck'), actions: [
        IconButton(tooltip: t('Stats'), icon: const Icon(Icons.insights), onPressed: () => _push(context, const StatsScreen())),
      ]),
      body: Live(
        load: _load,
        builder: (context, data) {
          final (queue, st, done, weak) = data;
          final cert = App.cert;
          final days = daysToExam(cert);
          final finalDays = days != null && days >= 0 && days <= 7;
          final total = done + queue.length;
          return RefreshIndicator(
            onRefresh: () async {
              final err = await Api.sync();
              if (err != null && context.mounted) toast(context, err);
            },
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const OnlineBanner(),
              if (!Api.configured)
                Card(
                    child: ListTile(
                        leading: const Icon(Icons.cloud_off),
                        title: Text(t('Not connected')),
                        subtitle: Text(t('Sign in from Settings to back up, restore and use AI.')))),
              Center(
                child: SizedBox(
                  width: 130,
                  height: 130,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox.expand(
                        child: CircularProgressIndicator(
                            value: total == 0 ? 1 : done / total, strokeWidth: 10, strokeCap: StrokeCap.round, backgroundColor: cs.surfaceContainerHighest)),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('$done', style: Theme.of(context).textTheme.headlineMedium),
                      Text(t('of {n} today', {'n': total}), style: muted.copyWith(fontSize: 12)),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: days == null
                    ? TextButton(onPressed: () => ownerTab.value = 2, child: Text('${cert['code']} · ${t('No exam date set')}'))
                    : Text(
                        days < 0
                            ? '${cert['code']} · ${t('Exam date passed')}'
                            : '${cert['code']} · ${t(days == 1 ? 'exam in {n} day' : 'exam in {n} days', {'n': days})}',
                        style: TextStyle(color: finalDays ? Colors.amber : cs.onSurfaceVariant)),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.all(18)),
                onPressed: () async {
                  var q = queue;
                  if (q.isEmpty) q = await buildExtraQueue(cert); // all done for today: study ahead
                  if (!context.mounted) return;
                  if (q.isEmpty) return toast(context, t('Nothing left to study. Everything is fresh.'));
                  studyCert(context, q);
                },
                icon: const Icon(Icons.play_arrow),
                label: Text(queue.isEmpty
                    ? t('Done for today · study ahead')
                    : done > 0
                        ? t('Continue · {n} left', {'n': queue.length})
                        : t('Study ({n}) · about {m} min', {'n': queue.length, 'm': App.sessionMinutes})),
              ),
              if (st.plan.remaining > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                      onPressed: () => studyNewCards(context),
                      icon: const Icon(Icons.fiber_new_outlined),
                      label: Text(t('New cards only ({n} left)', {'n': st.plan.remaining}))),
                ),
              TextButton.icon(
                  onPressed: () => pickStudiedTags(context),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(App.studiedTags.isEmpty
                      ? t('I studied… (pick today\'s course topics)')
                      : t('Studied today: {tags}', {'tags': (App.studiedTags.toList()..sort()).join(', ')}))),
              if (st.plan.paced > App.newPerDay)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      t('Exam pacing: {p} new/day to introduce all {r} unseen cards before the final review window.',
                          {'p': st.plan.paced, 'r': st.plan.remaining}),
                      style: const TextStyle(color: Colors.amber, fontSize: 13)),
                ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () => _push(context, const ExamScreen()), icon: const Icon(Icons.timer_outlined), label: Text(t('Exam sim')))),
                const SizedBox(width: 8),
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () => _push(context, generateScreen()),
                        icon: const Icon(Icons.auto_awesome),
                        label: Text(t('Generate')))),
              ]),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                    child: Text(finalDays ? t('Final review') : t('Fix these first'),
                        style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold))),
                if (finalDays)
                  TextButton(
                      onPressed: () async {
                        final q = await buildCramQueue(cert);
                        if (!context.mounted) return;
                        if (q.isEmpty) return toast(context, t('Nothing weak to review yet.'));
                        _push(context, StudyScreen(q, source: 'cram', title: t('Final review')));
                      },
                      child: Text(t('Review all'))),
                TextButton(onPressed: () => _push(context, const WeakSpotsScreen()), child: Text(t('See all'))),
              ]),
              if (weak.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t('No weak spots in the last 14 days.'), style: muted))
              else
                SizedBox(
                  height: 160,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    for (final w in weak.take(5)) SizedBox(width: 220, child: WeakSpotCard(w)),
                  ]),
                ),
              const SizedBox(height: 12),
              Text(t('{d} due · {n} new · {u} unseen', {'d': st.due, 'n': st.newAvailable, 'u': st.plan.remaining}), style: muted.copyWith(fontSize: 13)),
            ]),
          );
        },
      ),
    );
  }
}

class SyncButton extends StatelessWidget {
  const SyncButton({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Api.syncing,
        builder: (_, syncing, __) => syncing
            ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(
                tooltip: 'Sync now',
                icon: const Icon(Icons.sync),
                onPressed: () async {
                  final err = await Api.sync();
                  if (context.mounted) toast(context, err ?? 'Synced');
                },
              ),
      );
}
