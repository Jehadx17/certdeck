import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'ai.dart';
import 'api.dart';
import 'cards.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'widgets.dart';

bool _performance(Json cert) => cert['exam']?['kind'] == 'performance';

/// Picks [n] cards spread over [domains] by official weight. MCQ exams prefer scenario MCQs
/// (falling back to typed cards); performance exams (CKAD) use typed/code tasks.
Future<List<Json>> pickExamCards(Json cert, int n, Set<String> domains) async {
  final perf = _performance(cert);
  final preferred = perf ? {'typed', 'code'} : {'mcq'};
  final fallback = perf ? {'mcq', 'ordering'} : {'typed', 'ordering'};
  final pool = (await Db.cardsFor(cert['id'])).where((c) => !isSuspended(c) && domains.contains(domainOf(c, cert))).toList()..shuffle();
  final weights = {
    for (final d in cert['domains'] as List)
      if (domains.contains(d['id'])) d['id'] as String: (d['weight'] as num).toDouble()
  };
  final total = weights.values.fold(0.0, (a, b) => a + b);
  final quota = {for (final e in weights.entries) e.key: (n * e.value / total).floor()};
  final rest = (weights.keys.toList()..sort((a, b) => ((n * weights[b]! / total) % 1).compareTo((n * weights[a]! / total) % 1)));
  for (var i = 0; i < n - quota.values.fold(0, (a, b) => a + b); i++) {
    quota[rest[i % rest.length]] = quota[rest[i % rest.length]]! + 1;
  }
  final out = <Json>[];
  for (final types in [preferred, fallback]) {
    for (final e in quota.entries) {
      final have = out.where((c) => domainOf(c, cert) == e.key).length;
      out.addAll(pool.where((c) => types.contains(c['type']) && domainOf(c, cert) == e.key && !out.contains(c)).take(max(0, e.value - have)));
    }
  }
  // Still short (a domain has too few cards): fill from any domain.
  for (final types in [preferred, fallback]) {
    out.addAll(pool.where((c) => types.contains(c['type']) && !out.contains(c)).take(max(0, n - out.length)));
  }
  return out..shuffle();
}

class ExamScreen extends StatefulWidget {
  const ExamScreen({super.key});
  @override
  State<ExamScreen> createState() => _ExamScreenState();
}

class _ExamScreenState extends State<ExamScreen> {
  late Json cert = App.cert;
  late final count = TextEditingController(text: '${cert['exam']['questions']}');
  late final minutes = TextEditingController(text: '${cert['exam']['minutes']}');
  final fresh = TextEditingController(text: '0');
  late Set<String> domains = {for (final d in cert['domains'] as List) d['id'] as String};

  // Rebuild when the active cert changes in Settings (this tab is a const child of the shell's IndexedStack).
  void _onChange() => setState(() {});

  @override
  void initState() {
    super.initState();
    changes.addListener(_onChange);
  }

  @override
  void dispose() {
    changes.removeListener(_onChange);
    super.dispose();
  }

  Future<void> _start() async {
    final n = int.tryParse(count.text) ?? 65;
    final freshN = min(n, int.tryParse(fresh.text) ?? 0);
    var newCards = <Json>[];
    if (freshN > 0) {
      final r = await busy(context, 'Generating $freshN fresh exam questions…', () async {
        await Api.sync();
        return generateCards({
          'cert': cert['id'],
          'count': freshN,
          'exam_style': true,
          'types': _performance(cert) ? ['typed', 'code'] : ['mcq'],
          if (domains.length < (cert['domains'] as List).length) 'topic': 'Only these domains: ${domains.map((d) => domainName(cert, d)).join(', ')}',
        });
      });
      if (r == null) return;
      newCards = r.$2;
    }
    final picked = await pickExamCards(cert, n - newCards.length, domains);
    final all = [...newCards, ...picked.where((c) => !newCards.any((x) => x['id'] == c['id']))]..shuffle();
    if (all.isEmpty) {
      if (mounted) toast(context, 'No suitable cards for this exam yet. Generate some first.');
      return;
    }
    if (!mounted) return;
    final m = int.tryParse(minutes.text) ?? 130;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ExamRun(all, m, results: (states, flagged, started) => ExamResults(cert, states, flagged, started, m))));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (cert['id'] != App.cert['id']) {
      cert = App.cert;
      count.text = '${cert['exam']['questions']}';
      minutes.text = '${cert['exam']['minutes']}';
      domains = {for (final d in cert['domains'] as List) d['id'] as String};
    }
    final ex = cert['exam'] as Map;
    return Scaffold(
      appBar: AppBar(title: Text('Exam simulation · ${cert['code']}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            _performance(cert)
                ? 'Official format: performance-based tasks, ${ex['minutes']} min, pass ${ex['pass_pct']}%. Simulated with typed-command and YAML tasks.'
                : 'Official format: ${ex['questions']} questions, ${ex['minutes']} min, scaled 100–1000, pass 720 (≈${ex['pass_pct']}%).',
            style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: count,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Questions', border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          Expanded(
              child: TextField(
                  controller: minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Minutes', border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          Expanded(
              child: TextField(
                  controller: fresh,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Fresh AI Qs', border: OutlineInputBorder()))),
        ]),
        const SizedBox(height: 8),
        for (final d in cert['domains'] as List)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: domains.contains(d['id']),
            title: Text('${d['name']} (${((d['weight'] as num) * 100).round()}%)'),
            onChanged: (v) => setState(() => v == true ? domains.add(d['id']) : domains.remove(d['id'])),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: domains.isEmpty ? null : _start, icon: const Icon(Icons.timer_outlined), label: const Text('Start exam')),
        const SizedBox(height: 24),
        Text('Past simulations', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
        Live(
          load: () => Db.query('exam'),
          builder: (_, exams) {
            final list = exams.where((e) => e['cert'] == cert['id']).toList()
              ..sort((a, b) => (b['started_at'] as int).compareTo(a['started_at'] as int));
            if (list.isEmpty) return const Padding(padding: EdgeInsets.all(8), child: Text('None yet', style: TextStyle(color: Colors.white54)));
            return Column(children: [
              for (final e in list)
                ListTile(
                  leading: Icon(e['passed'] == true ? Icons.emoji_events : Icons.trending_up, color: e['passed'] == true ? Colors.amber : null),
                  title: Text('${(100 * (e['score_pct'] as num)).round()}%${e['scaled'] != null ? ' · ${e['scaled']}/1000' : ''}'),
                  subtitle: Text(
                      '${DateTime.fromMillisecondsSinceEpoch(e['started_at']).toString().substring(0, 16)} · ${(e['questions'] as List).length} Qs'),
                  onTap: () async {
                    final states = <AnswerState>[];
                    final flagged = <int>{};
                    for (final q in (e['questions'] as List).cast<Map>()) {
                      final c = await Db.get(q['card_id']);
                      if (c == null) continue;
                      final s = AnswerState(c);
                      final a = q['answer'];
                      if (a is List && c['type'] == 'mcq') s.selected.addAll(a.cast<int>());
                      if (a is List && c['type'] == 'ordering') s.order = a.cast<String>();
                      if (a is String) s.typed = a;
                      if (a is bool) s.selfGrade = a;
                      s.overrideCorrect = q['correct'] == true;
                      if (q['flagged'] == true) flagged.add(states.length);
                      states.add(s);
                    }
                    if (context.mounted) {
                      Navigator.push(
                          context, MaterialPageRoute(builder: (_) => ExamResults(cert, states, flagged, e['started_at'], e['minutes'], saved: true)));
                    }
                  },
                ),
            ]);
          },
        ),
      ]),
    );
  }
}

/// A timed exam over [cards] with flags and a review grid; [results] builds the screen shown on submit
/// (certs: pass mark and domains; college: partial credit and AI grading).
class ExamRun extends StatefulWidget {
  final List<Json> cards;
  final int minutes;
  final Widget Function(List<AnswerState> states, Set<int> flagged, int started) results;
  const ExamRun(this.cards, this.minutes, {super.key, required this.results});
  @override
  State<ExamRun> createState() => _ExamRunState();
}

class _ExamRunState extends State<ExamRun> {
  late final states = [for (final c in widget.cards) AnswerState(c)];
  final flagged = <int>{};
  final started = nowMs();
  late final endsAt = started + widget.minutes * 60000;
  late final Timer timer;
  int i = 0;
  bool reviewing = false;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (nowMs() >= endsAt) _submit();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  bool _answered(AnswerState s) => switch (s.type) {
        'mcq' => s.selected.isNotEmpty,
        'ordering' => true,
        _ => s.typed.trim().isNotEmpty || s.photos.isNotEmpty,
      };

  void _submit() {
    timer.cancel();
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => widget.results(states, flagged, started)));
  }

  Future<void> _confirmSubmit() async {
    final open = states.where((s) => !_answered(s)).length;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(t('Submit exam?')),
              content: Text(open > 0 ? t('{n} unanswered (scored as incorrect).', {'n': open}) : t('All questions answered.')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Keep going'))),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Submit'))),
              ],
            ));
    if (ok == true) _submit();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final left = Duration(milliseconds: max(0, endsAt - nowMs()));
    final clock =
        '${left.inHours > 0 ? '${left.inHours}:' : ''}${(left.inMinutes % 60).toString().padLeft(2, '0')}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    final s = states[i];
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) setState(() => reviewing = !reviewing);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(reviewing ? t('Review answers') : t('Question {i} / {n}', {'i': i + 1, 'n': states.length})),
          actions: [
            Center(
                child:
                    Text(clock, style: TextStyle(fontFeatures: const [FontFeature.tabularFigures()], color: left.inMinutes < 5 ? cs.error : null))),
            if (!reviewing)
              IconButton(
                  tooltip: t('Flag for review'),
                  icon: Icon(flagged.contains(i) ? Icons.flag : Icons.outlined_flag, color: flagged.contains(i) ? Colors.amber : null),
                  onPressed: () => setState(() => flagged.contains(i) ? flagged.remove(i) : flagged.add(i))),
            IconButton(icon: Icon(reviewing ? Icons.close : Icons.grid_view), onPressed: () => setState(() => reviewing = !reviewing)),
          ],
        ),
        body: reviewing
            ? _review(cs)
            : ListView(key: ValueKey(i), padding: const EdgeInsets.all(16), children: [
                CardView(s, key: ObjectKey(s), onChanged: () => setState(() {})),
                if (!s.autoGraded && s.type != 'mcq' && !s.written)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextFormField(
                      initialValue: s.typed,
                      minLines: s.type == 'code' ? 8 : 2,
                      maxLines: 30,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: InputDecoration(
                          labelText: s.type == 'code' ? 'Your YAML / commands' : 'Your answer',
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true),
                      onChanged: (v) => s.typed = v,
                    ),
                  ),
                const SizedBox(height: 80),
              ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: reviewing
                ? FilledButton(onPressed: _confirmSubmit, child: Text(t('Submit exam')))
                : Row(children: [
                    Expanded(child: OutlinedButton(onPressed: i == 0 ? null : () => setState(() => i--), child: Text(t('Previous')))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: FilledButton(
                            onPressed: () => setState(() => i < states.length - 1 ? i++ : reviewing = true),
                            child: Text(i < states.length - 1 ? t('Next') : t('Review')))),
                  ]),
          ),
        ),
      ),
    );
  }

  Widget _review(ColorScheme cs) => ListView(padding: const EdgeInsets.all(16), children: [
        Text(t('{a} answered · {f} flagged · {u} unanswered', {'a': states.where(_answered).length, 'f': flagged.length, 'u': states.where((s) => !_answered(s)).length})),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var j = 0; j < states.length; j++)
            InkWell(
              onTap: () => setState(() {
                i = j;
                reviewing = false;
              }),
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _answered(states[j]) ? cs.primaryContainer : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  border: flagged.contains(j) ? Border.all(color: Colors.amber, width: 2) : null,
                ),
                child: Text('${j + 1}'),
              ),
            ),
        ]),
      ]);
}

class ExamResults extends StatefulWidget {
  final Json cert;
  final List<AnswerState> states;
  final Set<int> flagged;
  final int started, minutes;
  final bool saved;
  const ExamResults(this.cert, this.states, this.flagged, this.started, this.minutes, {super.key, this.saved = false});
  @override
  State<ExamResults> createState() => _ExamResultsState();
}

class _ExamResultsState extends State<ExamResults> {
  late bool saved = widget.saved;

  /// Self-graded (code/basic/cloze) answers need the user's verdict before saving.
  List<AnswerState> get ungraded => widget.states.where((s) => !s.autoGraded && s.overrideCorrect == null && s.selfGrade == null).toList();

  @override
  void initState() {
    super.initState();
    if (!saved && ungraded.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _save());
  }

  double get pct => widget.states.isEmpty ? 0 : widget.states.where((s) => s.correct).length / widget.states.length;

  /// Piecewise-linear so the pass percentage maps exactly to 720.
  int? get scaled {
    final ex = widget.cert['exam'] as Map;
    if (ex['scaled'] != true) return null;
    final pass = (ex['pass_pct'] as num) / 100;
    return (pct < pass ? 100 + 620 * pct / pass : 720 + 280 * (pct - pass) / (1 - pass)).round();
  }

  bool get passed => pct * 100 >= (widget.cert['exam']['pass_pct'] as num);

  Future<void> _save() async {
    final qs = <Json>[];
    for (final (i, s) in widget.states.indexed) {
      final answered = switch (s.type) { 'mcq' => s.selected.isNotEmpty, 'ordering' => true, _ => s.typed.trim().isNotEmpty || s.selfGrade != null };
      // Flagged = unsure; unanswered questions aren't fed to FSRS.
      if (answered) {
        await recordAnswer(s.card, conf: widget.flagged.contains(i) ? Conf.unsure : Conf.sure, correct: s.correct, source: 'exam', answer: s.answer);
      }
      qs.add({
        'card_id': s.card['id'],
        'domain': domainOf(s.card, widget.cert),
        'answer': s.type == 'mcq' || s.type == 'ordering' ? s.answer : (s.typed.isEmpty ? s.selfGrade : s.typed),
        'correct': s.correct,
        'flagged': widget.flagged.contains(i)
      });
    }
    await Db.put('exam', {
      'cert': widget.cert['id'],
      'started_at': widget.started,
      'finished_at': nowMs(),
      'minutes': widget.minutes,
      'questions': qs,
      'score_pct': pct,
      'scaled': scaled,
      'passed': passed,
    });
    if (mounted) setState(() => saved = true);
    Api.sync().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cert = widget.cert;
    final byDomain = <String, List<AnswerState>>{};
    for (final s in widget.states) {
      (byDomain[domainOf(s.card, cert)] ??= []).add(s);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Exam results')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (ungraded.isNotEmpty && !saved)
          Card(
              color: cs.tertiaryContainer,
              child: const Padding(
                  padding: EdgeInsets.all(12), child: Text('Grade your hands-on answers below against the reference solutions, then save.'))),
        Center(
          child: Column(children: [
            Text('${(pct * 100).round()}%', style: Theme.of(context).textTheme.displayMedium),
            if (scaled != null) Text('Scaled ≈ $scaled / 1000', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Chip(
                avatar: Icon(passed ? Icons.check_circle : Icons.cancel, color: passed ? Colors.green : cs.error),
                label: Text(passed ? 'PASS' : 'FAIL (need ${cert['exam']['pass_pct']}%)')),
          ]),
        ),
        const SizedBox(height: 12),
        for (final d in cert['domains'] as List)
          if (byDomain[d['id']] != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name']}: ${byDomain[d['id']]!.where((s) => s.correct).length}/${byDomain[d['id']]!.length}'),
                LinearProgressIndicator(value: byDomain[d['id']]!.where((s) => s.correct).length / byDomain[d['id']]!.length, minHeight: 6),
              ]),
            ),
        if (!saved && widget.states.every((s) => s.autoGraded)) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
        if (!saved && ungraded.isEmpty && widget.states.any((s) => !s.autoGraded))
          FilledButton(onPressed: _save, child: const Text('Save results & update study schedule')),
        const Divider(height: 32),
        for (final (i, s) in widget.states.indexed)
          ExpansionTile(
            leading: Icon(
                s.correct ? Icons.check_circle : (!s.autoGraded && s.overrideCorrect == null && s.selfGrade == null ? Icons.help : Icons.cancel),
                color: s.correct ? Colors.green : cs.error),
            title: Text('${i + 1}. ${plain(s.card['question'])}', maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: widget.flagged.contains(i) ? const Text('flagged', style: TextStyle(color: Colors.amber)) : null,
            childrenPadding: const EdgeInsets.all(12),
            children: [
              CardView(s, revealed: true),
              if (!s.autoGraded) ...[
                if (s.typed.isNotEmpty) ...[const Text('Your answer:'), CodeView(s.typed, language: s.card['language'])],
                if (!saved)
                  SegmentedButton<bool>(
                    segments: const [ButtonSegment(value: false, label: Text('Wrong')), ButtonSegment(value: true, label: Text('Right'))],
                    selected: {if (s.overrideCorrect != null) s.overrideCorrect!},
                    emptySelectionAllowed: true,
                    onSelectionChanged: (v) => setState(() => s.overrideCorrect = v.isEmpty ? null : v.first),
                  ),
              ],
            ],
          ),
      ]),
    );
  }
}
