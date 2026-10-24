import 'package:flutter/material.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'widgets.dart';

/// Time spent studying the current cert: today, the last 14 days, seconds per card by confidence, each session.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  static const _days = 14;

  Future<StudyStatsData> _load() async {
    final today = startOfToday(), since = today - 29 * dayMs;
    final ids = {for (final c in await Db.cardsFor(App.cert['id'])) c['id']};
    final reviews = (await Db.reviewsSince(since)).where((r) => ids.contains(r['card_id'])).toList();
    final sessions = (await Db.query('session')).where((s) => (s['started_at'] as int? ?? 0) >= since).toList();
    return studyStats(reviews, sessions, today: today, days: _days);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Stats'))),
        body: Live(
          load: _load,
          builder: (context, s) {
            final today = startOfToday();
            final sessionsToday = s.sessions.where((x) => x.startedAt >= today).length;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                _Tile(_minutes(s.todayMs), t('studied today')),
                const SizedBox(width: 8),
                _Tile('${s.todayAnswered}', t('cards today')),
                const SizedBox(width: 8),
                _Tile('$sessionsToday', t('sessions today')),
                const SizedBox(width: 8),
                _Tile(s.todayCards == 0 ? '–' : '${(s.todayMs / s.todayCards / 1000).round()}s', t('per card today')),
              ]),
              const SizedBox(height: 12),
              _Panel(t('Minutes per day · last {n} days', {'n': _days}), _DayBars(s.perDayMs)),
              _Panel(t('Seconds per card by how sure you were · last 30 days'), _ConfBars(s.avgMsByConf)),
              _Panel(
                  t('Sessions'),
                  s.sessions.isEmpty
                      ? Text(t('No sessions yet.'))
                      : Column(children: [
                          for (final x in s.sessions)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(_when(context, x.startedAt)),
                              trailing: Text(t('{m} · {n} cards', {'m': _minutes(x.ms), 'n': x.cards})),
                            ),
                        ])),
            ]);
          },
        ),
      );

  static String _minutes(int ms) {
    final m = (ms / 60000).round();
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  static String _when(BuildContext context, int ms) {
    final l = MaterialLocalizations.of(context), d = DateTime.fromMillisecondsSinceEpoch(ms);
    final time = l.formatTimeOfDay(TimeOfDay.fromDateTime(d));
    final today = startOfToday();
    final day = ms >= today ? t('Today') : (ms >= today - dayMs ? t('Yesterday') : l.formatShortMonthDay(d));
    return '$day $time';
  }
}

class _Tile extends StatelessWidget {
  final String value, label;
  const _Tile(this.value, this.label);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  const _Panel(this.title, this.child);

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

/// One rounded bar per day, today's in the accent colour; tap a bar for its minutes.
class _DayBars extends StatelessWidget {
  final List<int> ms;
  const _DayBars(this.ms);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final top = ms.fold(1, (a, b) => a > b ? a : b);
    final first = DateTime.fromMillisecondsSinceEpoch(startOfToday()).subtract(Duration(days: ms.length - 1));
    return SizedBox(
      height: 140,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < ms.length; i++)
          Expanded(
            child: Tooltip(
              message: StatsScreen._minutes(ms[i]),
              triggerMode: TooltipTriggerMode.tap,
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: ms[i] == 0 ? 0.02 : ms[i] / top,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i == ms.length - 1 ? cs.tertiary : cs.primary.withOpacity(ms[i] == 0 ? .25 : 1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${DateTime(first.year, first.month, first.day + i).day}', style: Theme.of(context).textTheme.labelSmall),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Average seconds per card for Guess / Unsure / Sure, a right bar and a wrong bar each.
class _ConfBars extends StatelessWidget {
  final Map<(String, bool), int> avg;
  const _ConfBars(this.avg);

  static const _right = Color(0xFF34A853), _wrong = Color(0xFFE5534B);

  @override
  Widget build(BuildContext context) {
    if (avg.isEmpty) return Text(t('No timed answers yet.'));
    final top = avg.values.fold(1, (a, b) => a > b ? a : b);
    final text = Theme.of(context).textTheme;
    Widget bar(int? ms, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: ms == null ? 0.01 : ms / top,
                  child: Container(height: 12, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6))),
                ),
              ),
            ),
            SizedBox(width: 40, child: Text(ms == null ? '–' : '${(ms / 1000).round()}s', textAlign: TextAlign.end, style: text.labelMedium)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final c in Conf.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            SizedBox(width: 64, child: Text(t({'guess': 'Guess', 'unsure': 'Unsure', 'sure': 'Sure'}[c.name]!), style: text.bodyMedium)),
            Expanded(child: Column(children: [bar(avg[(c.name, true)], _right), bar(avg[(c.name, false)], _wrong)])),
          ]),
        ),
      Row(children: [
        _key(_right, t('right'), text),
        const SizedBox(width: 16),
        _key(_wrong, t('wrong'), text),
      ]),
    ]);
  }

  static Widget _key(Color c, String label, TextTheme text) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(label, style: text.labelSmall),
      ]);
}
