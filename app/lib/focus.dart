import 'package:flutter/material.dart';

import 'ai.dart';
import 'cards.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'study.dart';
import 'weak.dart';
import 'widgets.dart';

/// The one-line evidence under a weak spot's title.
String weakEvidence(WeakSpot w) => switch (w.kind) {
      WeakKind.tag => t('{m} of {a} missed', {'m': w.missed, 'a': w.answered}),
      WeakKind.memorized => t('{n} cards: right on the original, wrong on rewrites', {'n': w.missed}),
      WeakKind.misconception => t('{n} cards you were sure about and missed', {'n': w.missed}),
      WeakKind.leech => t('{n} cards you keep forgetting', {'n': w.missed}),
      WeakKind.ai => '${w.ai?['diagnosis'] ?? ''}'.replaceAll(RegExp(r'[*_#`]'), '').trim(),
    };

String weakTitle(WeakSpot w) => w.kind == WeakKind.tag || w.kind == WeakKind.ai ? w.title : t(w.title);

String _actionLabel(WeakSpot w) => switch (w.kind) {
      WeakKind.leech => t('Open'),
      WeakKind.ai => t('Generate'),
      _ => t('Drill'),
    };

/// The weak spot's action: a short drill session, the leech list, or card generation (AI areas).
bool _drilling = false;

Future<void> drill(BuildContext context, WeakSpot w) async {
  if (_drilling) return;
  _drilling = true;
  try {
    await _drill(context, w);
  } finally {
    _drilling = false;
  }
}

Future<void> _drill(BuildContext context, WeakSpot w) async {
  final nav = Navigator.of(context);
  switch (w.kind) {
    case WeakKind.leech:
      await nav.push(MaterialPageRoute(builder: (_) => const CardsScreen(filter: 'leech')));
      return;
    case WeakKind.ai:
      final a = w.ai ?? {};
      await nav.push(MaterialPageRoute(
          builder: (_) => Scaffold(
              appBar: AppBar(title: Text(t('Generate cards'))),
              body: GenerateTab(domain: a['domain']?.toString(), topic: a['topic']?.toString(), count: (a['count'] as num?)?.toInt() ?? 15))));
      return;
    default:
  }
  final cert = App.cert;
  final days = daysToExam(cert);
  final finalDays = days != null && days >= 0 && days <= 7;
  final q = w.kind == WeakKind.misconception && finalDays ? await buildCramQueue(cert) : drillQueue(w, await Db.cardsFor(cert['id']));
  if (!context.mounted) return;
  if (q.isEmpty) return toast(context, t('Nothing weak to review yet.'));
  await nav.push(MaterialPageRoute(
      builder: (_) => StudyScreen(q, source: 'cram', title: weakTitle(w), rewriteOnly: w.kind == WeakKind.memorized)));
}

class WeakSpotCard extends StatelessWidget {
  final WeakSpot w;
  const WeakSpotCard(this.w, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => drill(context, w),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(weakTitle(w), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(weakEvidence(w), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 8),
            Chip(label: Text(_actionLabel(w)), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
          ]),
        ),
      ),
    );
  }
}

/// "See all": every weak spot, plus a button to run a new AI analysis.
class WeakSpotsScreen extends StatefulWidget {
  const WeakSpotsScreen({super.key});
  @override
  State<WeakSpotsScreen> createState() => _WeakSpotsScreenState();
}

class _WeakSpotsScreenState extends State<WeakSpotsScreen> {
  String? error;

  Future<void> _run() async {
    setState(() => error = null);
    final err = await runAnalysis(context);
    if (!mounted) return;
    setState(() => error = err);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Fix these first'))),
        body: Live<List<WeakSpot>>(
          load: () => loadWeakSpots(App.cert),
          builder: (context, list) => ListView(padding: const EdgeInsets.all(16), children: [
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Text(t('No weak spots in the last 14 days.'), textAlign: TextAlign.center)),
            for (final w in list)
              Card(
                  child: ListTile(
                title: Text(weakTitle(w)),
                subtitle: Text(weakEvidence(w)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (w.kind == WeakKind.tag)
                    IconButton(
                        tooltip: t('See cards'),
                        icon: const Icon(Icons.style_outlined),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardsScreen(tag: w.title)))),
                  ActionChip(label: Text(_actionLabel(w)), onPressed: () => drill(context, w)),
                ]),
                onTap: () => drill(context, w),
              )),
            const SizedBox(height: 8),
            OutlinedButton.icon(
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(t('Weak areas'))), body: const InsightsTab()))),
                icon: const Icon(Icons.query_stats),
                label: Text(t('Full analysis'))),
            FilledButton.icon(onPressed: _run, icon: const Icon(Icons.insights), label: Text(t('Analyze weak areas'))),
            if (error != null) NeedsConnection(error!, onRetry: _run),
          ]),
        ),
      );
}
