import 'package:flutter/material.dart';

import 'api.dart';
import 'cards.dart';
import 'db.dart';
import 'logic.dart';
import 'study.dart';
import 'widgets.dart';

/// Today + the minimal stats: due/new, per-domain readiness, predicted score vs exam date,
/// leeches and misconceptions.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  Future<(List<Json>, TodayStats, Readiness, List<Json>, Json?)> _load() async {
    final cert = App.cert;
    final (queue, stats) = await buildQueue(cert);
    final cards = await Db.cardsFor(cert['id']);
    final exams = (await Db.query('exam')).where((e) => e['cert'] == cert['id']).toList()
      ..sort((a, b) => (b['started_at'] as int).compareTo(a['started_at'] as int));
    return (queue, stats, readiness(cert, cards), cards, exams.firstOrNull);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('CertDeck'), actions: const [SyncButton()]),
      body: Live(
        load: _load,
        builder: (context, data) {
          final (queue, st, r, cards, lastExam) = data;
          final cert = App.cert;
          final days = daysToExam(cert);
          final pass = (cert['exam']['pass_pct'] as num) / 100;
          final leeches = cards.where((c) => c['leech'] == true && !isSuspended(c)).length;
          final misconceptions = cards.where((c) => c['misconception'] == true).length;
          final finalDays = days != null && days >= 0 && days <= 7;
          return RefreshIndicator(
            onRefresh: () async {
              final err = await Api.sync();
              if (err != null && context.mounted) toast(context, err);
            },
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const OnlineBanner(),
              if (!Api.configured)
                const Card(
                    child: ListTile(
                        leading: Icon(Icons.cloud_off),
                        title: Text('Not connected'),
                        subtitle: Text('Add your server token in Settings to back up, restore and use AI.'))),
              Text(cert['name'], style: Theme.of(context).textTheme.titleLarge),
              Text(
                  days == null
                      ? 'No exam date set (Settings)'
                      : days < 0
                          ? 'Exam date passed'
                          : 'Exam in $days day${days == 1 ? '' : 's'} · ${cert['exam_date']}',
                  style: TextStyle(color: finalDays ? Colors.amber : Colors.white60)),
              const SizedBox(height: 16),
              Row(children: [
                _stat(context, '${st.due}', 'due'),
                _stat(context, '${st.newAvailable}', 'new today'),
                _stat(context, '${st.plan.remaining}', 'unseen'),
              ]),
              if (st.plan.paced > App.setting('new_per_day'))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      'Exam pacing: ${st.plan.paced} new/day to introduce all ${st.plan.remaining} unseen cards before the final review window.',
                      style: const TextStyle(color: Colors.amber, fontSize: 13)),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.all(18)),
                onPressed: queue.isEmpty ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => StudyScreen(queue))),
                icon: const Icon(Icons.play_arrow),
                label: Text(queue.isEmpty ? 'All done for today' : 'Study (${queue.length})'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                style: finalDays ? null : FilledButton.styleFrom(backgroundColor: Colors.transparent, side: const BorderSide(color: Colors.white24)),
                onPressed: () async {
                  final q = await buildCramQueue(cert);
                  if (!context.mounted) return;
                  if (q.isEmpty) return toast(context, 'Nothing weak to review yet.');
                  Navigator.push(
                      context, MaterialPageRoute(builder: (_) => StudyScreen(q, source: 'cram', title: finalDays ? 'Final review' : 'Weak areas')));
                },
                icon: const Icon(Icons.local_fire_department_outlined),
                label: Text(finalDays ? 'Final review: weak domains & misconceptions' : 'Weak-area review'),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: Text('Readiness', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold))),
                Text('Predicted ${(r.predicted * 100).round()}%  ·  pass ${(pass * 100).round()}%',
                    style: TextStyle(color: r.predicted >= pass ? Colors.green : Colors.orange)),
              ]),
              if (lastExam != null)
                Text(
                    'Last simulation: ${((lastExam['score_pct'] as num) * 100).round()}%${lastExam['scaled'] != null ? ' (${lastExam['scaled']})' : ''}',
                    style: const TextStyle(color: Colors.white60, fontSize: 13)),
              const SizedBox(height: 8),
              for (final d in cert['domains'] as List)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${d['name']}', style: const TextStyle(fontSize: 13))),
                      Text(
                          '${((r.byDomain[d['id']] ?? 0) * 100).round()}% · ${r.counts[d['id']]} cards · ${((d['weight'] as num) * 100).round()}% of exam',
                          style: const TextStyle(fontSize: 12, color: Colors.white60)),
                    ]),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                        value: r.byDomain[d['id']] ?? 0,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        color: (r.byDomain[d['id']] ?? 0) >= pass ? Colors.green : cs.primary),
                  ]),
                ),
              const SizedBox(height: 16),
              Wrap(spacing: 8, children: [
                ActionChip(
                    avatar: const Icon(Icons.bug_report_outlined, color: Colors.orange),
                    label: Text('Leeches ($leeches)'),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CardsScreen(filter: 'leech')))),
                ActionChip(
                    avatar: const Icon(Icons.warning_amber, color: Colors.redAccent),
                    label: Text('Misconceptions ($misconceptions)'),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CardsScreen(filter: 'misconception')))),
              ]),
            ]),
          );
        },
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Text(value, style: Theme.of(context).textTheme.headlineMedium),
              Text(label, style: const TextStyle(color: Colors.white60)),
            ]),
          ),
        ),
      );
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
