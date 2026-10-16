import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';
import 'billing.dart';
import 'college.dart';
import 'db.dart';
import 'exam.dart';
import 'help.dart';
import 'i18n.dart';
import 'logic.dart';
import 'packs.dart';
import 'settings.dart';
import 'study.dart';
import 'weighted.dart';
import 'widgets.dart';

/// Darb's home, one per segment (docs/GOAL-DARB.md → Product): the exam and the plan, one big "Study now", practice
/// tests and mistakes for exam students, the student's packs, and uploads for university and certification students.
class DarbHome extends StatefulWidget {
  const DarbHome({super.key});
  @override
  State<DarbHome> createState() => _DarbHomeState();
}

/// A pack installed on this phone, as the study machinery's "cert": its topics are the weighted domains.
Json packCert(Json meta) => {
      'id': meta['slug'],
      'code': meta['slug'],
      'name': App.lang == 'ar' ? meta['title_ar'] : meta['title_en'],
      'domains': [
        for (final tp in (meta['topics'] as List? ?? const []))
          {'id': tp['id'], 'name': App.lang == 'ar' ? tp['title_ar'] : (tp['title_en'] ?? tp['title_ar']), 'weight': tp['weight'] ?? .1}
      ],
      'exam_date': App.settings['exam_date'],
      'exam': {'questions': 24, 'minutes': 25, 'kind': 'mcq', 'pass_pct': 0, 'scaled': false},
    };

/// Packs that fit the onboarding answers: this segment, this grade (or every grade), the chosen exam first.
List<Json> relevant(List<Json> manifest) {
  final seg = App.settings['segment'], grade = App.settings['grade'], exam = App.settings['exam'];
  final list = manifest.where((p) => (p['segments'] as List).contains(seg) &&
      ((p['grades'] as List).isEmpty || (p['grades'] as List).contains(grade))).toList();
  list.sort((a, b) => ((b['exams'] as List).contains(exam) ? 1 : 0) - ((a['exams'] as List).contains(exam) ? 1 : 0));
  return list;
}

class _HomeData {
  final List<Json> packs, installed;
  final List<Json> queue;
  final int due, newLeft;
  final ({int limit, int paced, int remaining, int? days})? plan;
  final double? predicted;
  final Json? notice;
  _HomeData(this.packs, this.installed, this.queue, this.due, this.newLeft, this.plan, this.predicted, this.notice);
}

class _DarbHomeState extends State<DarbHome> {
  final _state = <String, String>{}; // slug -> full | sample | old (an older version than the manifest's)

  /// The manifest, cached so the home works offline.
  Future<List<Json>> _manifest() async {
    try {
      final m = await Packs.manifest();
      await Db.setMeta('manifest', jsonEncode(m));
      return m;
    } on ApiError {
      return [for (final p in jsonDecode(await Db.meta('manifest') ?? '[]') as List) Map<String, dynamic>.from(p as Map)];
    }
  }

  Future<_HomeData> _load() async {
    final manifest = await _manifest();
    final packs = relevant(manifest);
    // A lapsed subscription keeps only the free samples (docs/DARB-PACKS.md).
    if (Api.meFresh && !Billing.premium) await Packs.lapse(manifest); // only when the server just said so, never offline
    final installed = <Json>[];
    _state.clear();
    for (final p in packs) {
      final m = await Db.meta('pack:${p['slug']}');
      if (m == null) continue;
      installed.add(p);
      _state[p['slug'] as String] = m.endsWith(':sample') ? 'sample' : (m == '${p['version']}' ? 'full' : 'old');
    }
    // Today's plan across the installed packs: each gets an equal share of the session.
    final queue = <Json>[];
    var due = 0, newLeft = 0;
    ({int limit, int paced, int remaining, int? days})? plan;
    double? predicted;
    for (final p in installed) {
      final cert = packCert(p);
      final (q, st) = await buildQueue(cert, minutes: (App.sessionBudget / installed.length).ceil());
      queue.addAll(q);
      due += st.due;
      newLeft += st.plan.remaining;
      plan ??= st.plan;
      final r = readiness(cert, await Db.cardsFor(p['slug'] as String));
      predicted = (predicted ?? 0) + r.predicted / installed.length;
    }
    final notices = (await Db.query('notice')).where((n) => n['seen'] != true).toList();
    return _HomeData(packs, installed, queue, due, newLeft, plan, predicted, notices.firstOrNull);
  }

  Future<void> _install(Json p) async {
    final err = await Packs.install(p, premium: Billing.premium);
    if (mounted && err != null) toast(context, t(err));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final seg = App.settings['segment'];
    return Scaffold(
      appBar: AppBar(
        title: Text('درب', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(tooltip: t('Help'), icon: const Icon(Icons.help_outline), onPressed: () => openHelp(context)),
          IconButton(
              tooltip: t('Settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: Live<_HomeData>(
        load: _load,
        builder: (context, d) => RefreshIndicator(
          onRefresh: () async => Api.sync(),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const OnlineBanner(),
            if (d.notice != null) _notice(context, d.notice!),
            _planCard(context, d),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64), textStyle: const TextStyle(fontSize: 20)),
              icon: const Icon(Icons.play_arrow_rounded, size: 32),
              label: Text(d.installed.isEmpty
                  ? t('Download a pack to start')
                  : t('Study now (about {m} min)', {'m': App.sessionMinutes})),
              onPressed: d.installed.isEmpty || d.queue.isEmpty
                  ? (d.installed.isEmpty ? null : () => toast(context, t('All done for today. Come back tomorrow, or practice below.')))
                  : () => _study(context, d.queue),
            ),
            const SizedBox(height: 8),
            if (d.installed.isNotEmpty)
              Row(children: [
                Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.timer_outlined), label: Text((d.predicted ?? 0) == 0 ? t('Placement test') : t('Practice test')),
                    onPressed: () => _practice(context, d.installed))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.replay), label: Text(t('My mistakes')),
                    onPressed: () => _mistakes(context, d.installed))),
              ]),
            if (seg == 'university' || seg == 'cert') ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.upload_file_outlined),
                  title: Text(t('My material')),
                  subtitle: Text(t('Upload PDFs or photos and get cards for your exam')),
                  trailing: Billing.premium ? null : const Icon(Icons.lock_outline),
                  onTap: () async {
                    if (!Billing.premium && !await openPaywall(context)) return;
                    if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const CollegeScreen()));
                  },
                ),
              ),
            ],
            if (seg == 'high') ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.calculate_outlined),
                  title: Text(t('Weighted percentage')),
                  subtitle: Text(t('Calculate it from your three results')),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WeightedScreen())),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(t('Your packs'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            if (d.packs.isEmpty) Text(t('Packs for your grade are on the way. Pull down to check again.'), style: TextStyle(color: muted(context))),
            for (final p in d.packs) _packTile(context, p, d.installed.contains(p)),
            if (!Billing.premium && d.packs.isNotEmpty)
              Card(
                color: cs.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.workspace_premium, color: cs.onPrimaryContainer),
                  title: Text(t('Free: a sample of every pack'), style: TextStyle(color: cs.onPrimaryContainer)),
                  subtitle: Text(t('Darb Plus opens every question bank.'), style: TextStyle(color: cs.onPrimaryContainer)),
                  onTap: () async {
                    if (await openPaywall(context)) setState(() {});
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// The exam, its countdown and the plan: "on track" when the new cards fit before the exam (with a buffer).
  Widget _planCard(BuildContext context, _HomeData d) {
    final days = daysToExam(App.cert);
    final plan = d.plan;
    String line;
    if (d.installed.isEmpty) {
      line = t('Pick a pack below. A short session every day beats a long one now and then.');
    } else if (days == null) {
      line = t('{n} cards to learn. Add your exam date in Settings for a day-by-day plan.', {'n': d.newLeft});
    } else if (plan != null && plan.paced <= plan.limit) {
      line = t('On track: {n} new cards a day finishes everything a week or more before your exam.', {'n': plan.paced});
    } else {
      line = t('{n} new cards a day to finish before your exam. Short daily sessions get you there.', {'n': plan?.paced ?? 0});
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(days == null ? t('Your plan') : (days == 0 ? t('Your exam is today. You can do it!') : t('{n} days to your exam', {'n': days})),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(line),
          if (d.due > 0) Text(t('{n} cards to review today.', {'n': d.due}), style: TextStyle(color: muted(context))),
          if ((d.predicted ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('You remember about {p}% of your packs right now.', {'p': ((d.predicted ?? 0) * 100).round()}),
                  style: TextStyle(color: muted(context))),
            ),
        ]),
      ),
    );
  }

  Widget _notice(BuildContext context, Json n) => Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: Text(t('Thanks! The question you reported was fixed.')),
          trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () async {
                await Db.put('notice', n..['seen'] = true);
                setState(() {});
              }),
        ),
      );

  Widget _packTile(BuildContext context, Json p, bool installed) => ValueListenableBuilder(
        valueListenable: Packs.progress,
        builder: (_, prog, __) {
          final f = prog[p['slug']];
          final state = _state[p['slug']];
          // Plus with only the sample or an older version: one tap gets the full, current pack.
          final get = !installed || (Billing.premium && state != 'full');
          return Card(
            child: ListTile(
              title: Text(App.lang == 'ar' ? p['title_ar'] : p['title_en']),
              subtitle: f != null
                  ? LinearProgressIndicator(value: f)
                  : Text(state == 'full'
                      ? t('{n} questions on this phone', {'n': p['items']})
                      : state == 'old' ? t('An update is ready') : state == 'sample' && !Billing.premium
                          ? t('Free sample on this phone')
                          : t('{n} questions · {mb} MB', {'n': p['items'], 'mb': ((p['size'] as int) / 1e6).toStringAsFixed(1)})),
              trailing: get ? const Icon(Icons.download_outlined) : const Icon(Icons.offline_pin_outlined),
              onTap: f != null ? null : () => get ? _install(p) : _studyPack(context, p),
            ),
          );
        },
      );

  Future<void> _study(BuildContext context, List<Json> queue) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => StudyScreen(queue, easy: true, onMore: () => setState(() {}))));
    if (mounted) setState(() {});
  }

  Future<void> _studyPack(BuildContext context, Json p) async {
    final (q, _) = await buildQueue(packCert(p));
    final queue = q.isNotEmpty ? q : await buildExtraQueue(packCert(p));
    if (!context.mounted) return;
    if (queue.isEmpty) return toast(context, t('Nothing left in this pack for now.'));
    await _study(context, queue);
  }

  /// A timed practice test: questions drawn by topic weight, a score per topic at the end, then the missed ones.
  Future<void> _practice(BuildContext context, List<Json> installed) async {
    final p = installed.first;
    final cert = packCert(p);
    final cards = await pickExamCards(cert, cert['exam']['questions'] as int, {for (final d in cert['domains'] as List) d['id'] as String});
    if (!context.mounted || cards.isEmpty) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => StudyScreen(cards, easy: true, practice: true, source: 'exam',
        title: t('Practice test'), timedMinutes: cert['exam']['minutes'] as int)));
    if (mounted) setState(() {});
  }

  /// Misconceptions first, then the weakest topics' least remembered cards.
  Future<void> _mistakes(BuildContext context, List<Json> installed) async {
    final queue = <Json>[];
    for (final p in installed) {
      queue.addAll(await buildCramQueue(packCert(p), limit: 20));
    }
    if (!context.mounted) return;
    if (queue.isEmpty) return toast(context, t('No mistakes to redo yet.'));
    await _study(context, queue.take(30).toList());
  }
}
