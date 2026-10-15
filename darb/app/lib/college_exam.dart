import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'cards.dart';
import 'college_logic.dart';
import 'db.dart';
import 'exam.dart';
import 'i18n.dart';
import 'logic.dart';
import 'widgets.dart';

/// [n] scope cards in the professor's format mix (from past papers, else an even mix), likelier points first,
/// with some randomness so two practice exams differ.
List<Json> pickPractice(Scope s, Json? profile, int n, {Random? rng}) {
  rng ??= Random();
  final formats = ((profile?['formats'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
  final by = <String, List<Json>>{};
  for (final c in s.cards) {
    (by[formatOf(c)] ??= []).add(c);
  }
  for (final l in by.values) {
    l.sort((a, b) => (s.weight(b) + rng!.nextDouble() * .4).compareTo(s.weight(a) + rng.nextDouble() * .4));
  }
  final share = {for (final f in by.keys) f: formats.isEmpty ? 1.0 : (formats[f] ?? 0)};
  final total = share.values.fold(0.0, (a, b) => a + b);
  final out = <Json>[];
  if (total > 0) {
    for (final e in share.entries) {
      out.addAll(by[e.key]!.take((n * e.value / total).round()));
    }
  }
  final rest = s.cards.where((c) => !out.contains(c)).toList()..shuffle(rng);
  out.addAll(rest.take(max(0, n - out.length)));
  return (out.take(n).toList())..shuffle(rng);
}

class PracticeSetup extends StatefulWidget {
  final Json a;
  const PracticeSetup(this.a, {super.key});
  @override
  State<PracticeSetup> createState() => _PracticeSetupState();
}

class _PracticeSetupState extends State<PracticeSetup> {
  late final count = TextEditingController();
  late final minutes = TextEditingController();
  final fresh = TextEditingController(text: '0');
  Json? profile;

  @override
  void initState() {
    super.initState();
    Db.get('profile-${widget.a['course_id']}').then((p) {
      final kind = widget.a['kind'];
      final n = (p?['typical_questions'] as int?) ?? switch (kind) { 'quiz' => 10, 'midterm' => 25, 'final' => 40, _ => 20 };
      final m = (widget.a['minutes'] as int?) ?? (p?['typical_minutes'] as int?) ?? switch (kind) { 'quiz' => 20, 'midterm' => 60, 'final' => 120, _ => 45 };
      setState(() {
        profile = p;
        count.text = '$n';
        minutes.text = '$m';
        fresh.text = '${min(10, n ~/ 2)}';
      });
    });
  }

  Future<void> _start() async {
    final s = await Scope.load(widget.a);
    final n = int.tryParse(count.text) ?? 10;
    final f = min(n, int.tryParse(fresh.text) ?? 0);
    var made = <Json>[];
    if (f > 0) {
      await Api.sync();
      if (!mounted) return;
      final r = await busy(context, t('Writing {n} fresh questions in your professor\'s style…', {'n': f}),
          () => Api.ai('college/practice', {'assessment_id': widget.a['id'], 'count': f}));
      if (r == null) return;
      made = ((r['cards'] as List?) ?? []).map((c) => Map<String, dynamic>.from(c as Map)).toList();
      await Db.putAll('card', made, dirty: false); // already on the server
    }
    final cards = [...made, ...pickPractice(s, profile, n - made.length)]..shuffle();
    if (!mounted) return;
    if (cards.isEmpty) return toast(context, t('No cards yet: prepare this assessment first.'));
    final m = int.tryParse(minutes.text) ?? 30;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ExamRun(cards, m, results: (states, flagged, started) => PracticeResults(widget.a, states, flagged, started, m))));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Practice exam'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(
              profile == null
                  ? t('Questions from your cards, in an even mix of formats. Upload past papers to match your professor\'s style.')
                  : t('Questions in your professor\'s format mix: {mix}.', {
                      'mix': (profile!['formats'] as Map)
                          .entries
                          .where((e) => (e.value as num) > 0)
                          .map((e) => '${t(e.key.toString())} ${((e.value as num) * 100).round()}%')
                          .join(', ')
                    }),
              style: TextStyle(color: muted(context))),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: TextField(controller: count, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Questions'), border: const OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: minutes, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Minutes'), border: const OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: fresh, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('New AI questions'), border: const OutlineInputBorder()))),
          ]),
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('New questions you haven\'t seen cost about \$0.05 each and need a connection; the rest come from your cards.'),
                  style: TextStyle(color: muted(context), fontSize: 12))),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _start, icon: const Icon(Icons.timer_outlined), label: Text(t('Start'))),
          const SizedBox(height: 24),
          Text(t('Past attempts'), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
          Live(
            load: () async => (await Db.query('exam')).where((e) => e['assessment_id'] == widget.a['id']).toList()
              ..sort((a, b) => (b['started_at'] as int).compareTo(a['started_at'] as int)),
            builder: (_, list) => Column(children: [
              if (list.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(t('None yet'), style: TextStyle(color: muted(context)))),
              for (final e in list)
                ListTile(
                  leading: const Icon(Icons.assignment_turned_in_outlined),
                  title: Text('${((e['score_pct'] as num) * 100).round()}%'),
                  subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(e['started_at']).toString().substring(0, 16)} · ${t('{n} questions', {'n': (e['questions'] as List).length})}'),
                ),
            ]),
          ),
        ]),
      );
}

/// Partial credit per question, AI grading for written answers (or the student's own), a breakdown by section,
/// then the answers feed the study schedule.
class PracticeResults extends StatefulWidget {
  final Json a;
  final List<AnswerState> states;
  final Set<int> flagged;
  final int started, minutes;
  const PracticeResults(this.a, this.states, this.flagged, this.started, this.minutes, {super.key});
  @override
  State<PracticeResults> createState() => _PracticeResultsState();
}

class _PracticeResultsState extends State<PracticeResults> {
  bool saved = false;

  bool _answered(AnswerState s) => switch (s.type) { 'mcq' => s.selected.isNotEmpty, 'ordering' => true, _ => s.typed.trim().isNotEmpty };
  List<AnswerState> get ungraded =>
      widget.states.where((s) => _answered(s) && (s.written ? !s.graded : !s.autoGraded && s.selfGrade == null)).toList();
  double get pct => widget.states.isEmpty ? 0 : widget.states.fold(0.0, (t, s) => t + (_answered(s) ? s.score : 0)) / widget.states.length;

  @override
  void initState() {
    super.initState();
    for (final s in widget.states) {
      if (s.written && !_answered(s)) s.selfScore = 0; // blank = no marks
      if (!s.written && !s.autoGraded && !_answered(s)) s.selfGrade = false;
    }
  }

  Future<void> _gradeAll() async {
    final todo = ungraded.where((s) => s.written).toList();
    for (final (i, s) in todo.indexed) {
      final r = await busy(context, t('Grading {i} of {n}…', {'i': i + 1, 'n': todo.length}), () => gradeAnswer(s));
      if (r == null) break;
      setState(() => s.aiGrade = r);
    }
  }

  Future<void> _save() async {
    final qs = <Json>[];
    for (final (i, s) in widget.states.indexed) {
      if (_answered(s)) {
        await recordAnswer(s.card,
            conf: widget.flagged.contains(i) ? Conf.unsure : Conf.sure,
            correct: s.correct,
            source: 'exam',
            answer: s.answer,
            score: s.written ? s.score : null,
            scheduler: schedulerForDate(widget.a['date']));
      }
      qs.add({'card_id': s.card['id'], 'section': s.card['section'], 'answer': s.answer, 'score': _answered(s) ? s.score : 0, 'flagged': widget.flagged.contains(i)});
    }
    await Db.put('exam', {
      'assessment_id': widget.a['id'],
      'course_id': widget.a['course_id'],
      'started_at': widget.started,
      'finished_at': nowMs(),
      'minutes': widget.minutes,
      'questions': qs,
      'score_pct': pct,
    });
    setState(() => saved = true);
    Api.sync().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bySection = <String, List<AnswerState>>{};
    for (final s in widget.states) {
      (bySection[s.card['section'] ?? ''] ??= []).add(s);
    }
    final left = ungraded;
    return Scaffold(
      appBar: AppBar(title: Text(t('Results'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(child: Text('${(pct * 100).round()}%', style: Theme.of(context).textTheme.displayMedium)),
        if (left.isNotEmpty && !saved) ...[
          Card(
            color: cs.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('{n} written answers to mark. Grade them with AI, or open each one below and mark it yourself.', {'n': left.length})),
                const SizedBox(height: 8),
                FilledButton.icon(icon: const Icon(Icons.auto_awesome), label: Text(t('Grade with AI')), onPressed: _gradeAll),
              ]),
            ),
          ),
        ],
        if (!saved && left.isEmpty)
          FilledButton(onPressed: _save, child: Text(t('Save results & update my study plan')))
        else if (saved)
          Padding(padding: const EdgeInsets.all(8), child: Text(t('Saved. Your study plan now knows what you missed.'), textAlign: TextAlign.center)),
        const SizedBox(height: 12),
        FutureBuilder<Map<String, String>>(
          future: () async {
            final out = <String, String>{};
            for (final k in bySection.keys.where((k) => k.contains('/'))) {
              final ing = await ingestOf(k.split('/')[0]);
              out[k] = ((ing?['structure'] as List?) ?? []).cast<Map>().where((s) => s['id'] == k.split('/')[1]).firstOrNull?['title'] ?? k;
            }
            return out;
          }(),
          builder: (context, snap) => Column(children: [
            for (final e in bySection.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  autoText('${snap.data?[e.key] ?? t('Other')}: ${(e.value.fold(0.0, (t, s) => t + s.score) / e.value.length * 100).round()}%',
                      style: const TextStyle(fontSize: 13)),
                  LinearProgressIndicator(value: e.value.fold(0.0, (t, s) => t + s.score) / e.value.length, minHeight: 6),
                ]),
              ),
          ]),
        ),
        const Divider(height: 32),
        for (final (i, s) in widget.states.indexed)
          ExpansionTile(
            leading: Icon(!s.graded ? Icons.help : (s.score >= .85 ? Icons.check_circle : (s.score >= .4 ? Icons.adjust : Icons.cancel)),
                color: !s.graded ? Colors.amber : (s.score >= .85 ? Colors.green : (s.score >= .4 ? Colors.amber : cs.error))),
            title: autoText('${i + 1}. ${plain(s.card['question'])}', maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text([if (widget.flagged.contains(i)) t('flagged'), if (s.written && s.graded) '${(s.score * 100).round()}%'].join(' · ')),
            childrenPadding: const EdgeInsets.all(12),
            children: [
              CardView(s, revealed: true, onChanged: saved ? null : () => setState(() {})),
              if (!saved && s.written && !s.graded)
                SegmentedButton<double>(
                  segments: [
                    ButtonSegment(value: 0, label: Text(t('Wrong'))),
                    ButtonSegment(value: .5, label: Text(t('Partly'))),
                    ButtonSegment(value: 1, label: Text(t('Right'))),
                  ],
                  selected: {if (s.selfScore != null) s.selfScore!},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (v) => setState(() => s.selfScore = v.isEmpty ? null : v.first),
                ),
              if (!saved && !s.written && !s.autoGraded)
                SegmentedButton<bool>(
                  segments: [ButtonSegment(value: false, label: Text(t('Wrong'))), ButtonSegment(value: true, label: Text(t('Right')))],
                  selected: {if (s.selfGrade != null) s.selfGrade!},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (v) => setState(() => s.selfGrade = v.isEmpty ? null : v.first),
                ),
            ],
          ),
      ]),
    );
  }
}
