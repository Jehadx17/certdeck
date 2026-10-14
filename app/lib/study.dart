import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai.dart';
import 'api.dart';
import 'cards.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

import 'db.dart';
import 'i18n.dart';
import 'easy.dart';
import 'logic.dart';
import 'widgets.dart';

/// Queue with Anki-style relearning: cards due again within 30 min come back this session.
class Session implements StudyQueue {
  final List<Json> queue;
  final List<Json> pending = [];
  final bool relearn;
  Session(this.queue, {this.relearn = true});

  @override
  int get remaining => queue.length + pending.length;

  @override
  Json? next() {
    pending.sort((a, b) => dueOf(a).compareTo(dueOf(b)));
    if (pending.isNotEmpty && dueOf(pending.first) <= nowMs()) return pending.removeAt(0);
    if (queue.isNotEmpty) return queue.removeAt(0);
    return pending.isEmpty ? null : pending.removeAt(0);
  }

  @override
  void answered(Json card, double score) {
    if (relearn && dueOf(card) <= nowMs() + 30 * 60000) pending.add(card);
  }
}

class StudyScreen extends StatefulWidget {
  final List<Json> queue;
  final String source;
  final String title;
  /// Pulls cards from this instead of [queue] (the college sprint loop).
  final StudyQueue? custom;
  /// Schedules every answer with this (a college assessment's date); null = per card.
  final fsrs.Scheduler? scheduler;
  /// The easy version for students (EASY.md): no confidence step, one Check button, stars at the end.
  final bool easy;
  /// A practice test (easy): stars per topic at the end and a round of the missed questions.
  final bool practice;
  /// "Do more" at the end of a easy session.
  final VoidCallback? onMore;
  const StudyScreen(this.queue,
      {super.key, this.source = 'study', this.title = 'Study', this.custom, this.scheduler, this.easy = false, this.practice = false, this.onMore});
  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late final StudyQueue session = widget.custom ?? Session([...widget.queue], relearn: widget.source == 'study');
  Json? card;
  AnswerState? ans;
  Conf? conf;
  bool revealed = false;
  int done = 0, right = 0;
  final results = <(Json, bool)>[]; // each answer this session, for the practice test's topics

  @override
  void initState() {
    super.initState();
    _next();
  }

  void _next() => setState(() {
        card = session.next();
        ans = card == null ? null : AnswerState(card!);
        conf = null;
        revealed = false;
        if (card == null) Api.sync().ignore();
      });

  bool get graded => ans!.written ? ans!.graded : (ans!.autoGraded || ans!.selfGrade != null);
  bool get misconception => !widget.easy && revealed && graded && conf == Conf.sure && ans!.score < .4;

  Future<void> _commit() async {
    final a = ans!;
    if (widget.easy) conf = easyConf(a.correct, nowMs() - a.startedAt);
    final updated = await recordAnswer(card!,
        conf: conf!,
        correct: a.correct,
        source: widget.source,
        durationMs: nowMs() - a.startedAt,
        answer: a.answer,
        score: a.written ? a.score : null,
        scheduler: widget.scheduler);
    session.answered(updated, a.score);
    done++;
    if (a.correct) right++;
    results.add((card!, a.correct));
    _next();
  }

  void _selfScore(double v) {
    setState(() => ans!.selfScore = v);
    if (!misconception) _commit();
  }

  void _selfGrade(bool correct) {
    setState(() => ans!.selfGrade = correct);
    if (!misconception) _commit(); // a misconception stays on screen until "Next"
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (widget.easy) return easyScale(context, card == null ? _easyEnd(context) : _easyCard(cs));
    if (card == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.celebration, size: 64),
            const SizedBox(height: 12),
            Text(done == 0 ? t('Nothing to study right now.') : t('Session done: {n} answers, {p}% correct', {'n': done, 'p': (100 * right / done).round()}),
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(t('Back'))),
          ]),
        ),
      );
    }
    final c = card!;
    final cert = App.cert;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.title} · ${t('{n} left', {'n': session.remaining + 1})}', style: const TextStyle(fontSize: 18)),
        actions: [
          IconButton(
              tooltip: 'Ask AI',
              icon: const Icon(Icons.forum_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(c)))),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => CardEditor(card: c)));
                final fresh = await Db.get(c['id']);
                if (fresh != null) setState(() => ans = AnswerState(card = fresh));
              } else if (v == 'suspend') {
                await Db.put('card', c..['suspended'] = true);
                if (context.mounted) toast(context, 'Card suspended');
                _next();
              } else if (v == 'details') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(c['id'])));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(t('Edit card'))),
              PopupMenuItem(value: 'details', child: Text(t('Card details & history'))),
              PopupMenuItem(value: 'suspend', child: Text(t('Suspend card'))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const OnlineBanner(),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Wrap(spacing: 6, children: [
                _chip(t(typeLabels[c['type']] ?? c['type'])),
                if (domainOf(c, cert).isNotEmpty) _chip(domainName(cert, domainOf(c, cert))),
                if (isNew(c)) _chip(t('New'), color: cs.primary),
                if (c['worked'] == true) _chip(t('Worked example'), color: Colors.lightBlueAccent),
                if (c['misconception'] == true) _chip(t('Misconception'), color: cs.error),
                if (c['leech'] == true) _chip(t('Leech'), color: Colors.orange),
              ]),
              const SizedBox(height: 12),
              CardView(ans!, key: ObjectKey(ans), revealed: revealed, misconception: misconception, onChanged: () => setState(() {})),
              const SizedBox(height: 80),
            ]),
          ),
          _bottom(cs),
        ]),
      ),
    );
  }

  Widget _chip(String text, {Color? color}) => Chip(
      label: Text(text, style: TextStyle(fontSize: 12, color: color)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      side: BorderSide(color: color ?? Colors.white24));

  Widget _bottom(ColorScheme cs) {
    Widget bar(List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(color: cs.surfaceContainer, border: const Border(top: BorderSide(color: Colors.white10))),
        child: Row(children: [for (final w in children) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: w))]));
    if (!revealed) {
      final ready = ans!.ready;
      Widget btn(Conf c, String label, IconData icon, Color color) => FilledButton.tonal(
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), foregroundColor: color),
          onPressed: ready
              ? () => setState(() {
                    conf = c;
                    revealed = true;
                  })
              : null,
          child: Column(children: [Icon(icon), Text(label)]));
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(ready ? t('How confident are you?') : t('Pick an answer first'), style: const TextStyle(color: Colors.white54, fontSize: 12))),
        bar([
          btn(Conf.guess, t('Guessing'), Icons.casino_outlined, Colors.orange),
          btn(Conf.unsure, t('Unsure'), Icons.help_outline, Colors.amber),
          btn(Conf.sure, t('Sure'), Icons.verified_outlined, Colors.green),
        ]),
      ]);
    }
    if (!graded && ans!.written) {
      // Written answers: tick the rubric or grade with AI above, or give a quick verdict here.
      return bar([
        FilledButton.tonal(onPressed: () => _selfScore(0), style: FilledButton.styleFrom(foregroundColor: cs.error), child: Text(t('Wrong'))),
        FilledButton.tonal(onPressed: () => _selfScore(.5), style: FilledButton.styleFrom(foregroundColor: Colors.amber), child: Text(t('Partly'))),
        FilledButton(onPressed: () => _selfScore(1), child: Text(t('Right'))),
      ]);
    }
    if (!graded) {
      return bar([
        FilledButton.tonal(
            onPressed: () => _selfGrade(false), style: FilledButton.styleFrom(foregroundColor: cs.error), child: Text(t('I was wrong'))),
        FilledButton(onPressed: () => _selfGrade(true), child: Text(t('I was right'))),
      ]);
    }
    return bar([
      if (ans!.autoGraded && !ans!.written)
        TextButton(
            onPressed: () => setState(() => ans!.overrideCorrect = !ans!.correct), child: Text(ans!.correct ? t('Actually wrong') : t('Actually right'))),
      FilledButton(onPressed: _commit, child: Text(t('Next'))),
    ]);
  }

  // ---------------- the easy version (EASY.md) ----------------

  Widget _easyCard(ColorScheme cs) => Scaffold(
        appBar: AppBar(
          title: Text(t('{n} left', {'n': session.remaining + 1}), style: const TextStyle(fontSize: 20)),
          actions: [helpButton(context, studyHelp)],
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                CardView(ans!, key: ObjectKey(ans), revealed: revealed, easy: true, onChanged: () => setState(() {})),
                const SizedBox(height: 40),
              ]),
            ),
            _easyBottom(cs),
          ]),
        ),
      );

  void _easyCheck() {
    setState(() {
      conf = Conf.unsure;
      revealed = true;
    });
    if (ans!.autoGraded && ans!.correct) HapticFeedback.mediumImpact();
  }

  void _easyVerdict(bool yes) {
    if (yes) HapticFeedback.mediumImpact();
    ans!.written ? ans!.selfScore = yes ? 1 : 0 : ans!.selfGrade = yes;
    _commit();
  }

  Widget _easyBottom(ColorScheme cs) {
    Widget bar(Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        decoration: BoxDecoration(color: cs.surfaceContainer, border: const Border(top: BorderSide(color: Colors.white10))),
        child: child);
    final a = ans!;
    if (!revealed) {
      final empty = (a.type == 'typed' || a.written) && a.typed.trim().isEmpty;
      return bar(FilledButton.icon(
          style: easyButton(),
          icon: Icon(empty ? Icons.visibility_rounded : Icons.check_rounded, size: 30),
          label: Text(a.ready ? (empty ? t('Show me the answer') : t('Check')) : t('Pick an answer')),
          onPressed: a.ready ? _easyCheck : null));
    }
    if (!graded) {
      return bar(Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t('Did you get it?'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: FilledButton.icon(
                  style: easyButton(Colors.deepOrange), icon: const Icon(Icons.replay_rounded), label: Text(t('Not yet')), onPressed: () => _easyVerdict(false))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton.icon(
                  style: easyButton(Colors.green), icon: const Icon(Icons.thumb_up_alt_rounded), label: Text(t('Yes')), onPressed: () => _easyVerdict(true))),
        ]),
      ]));
    }
    final ok = a.correct;
    return bar(Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(ok ? Icons.celebration_rounded : Icons.replay_rounded, size: 36, color: ok ? Colors.amber : Colors.orangeAccent),
        const SizedBox(width: 10),
        Expanded(
            child: Text(ok ? t('Great job!') : (widget.practice ? t('Not quite. Read the answer, then go on.') : t('Not quite. It will come back in a moment.')),
                style: const TextStyle(fontSize: 20))),
      ]),
      const SizedBox(height: 10),
      FilledButton.icon(style: easyButton(), icon: const Icon(Icons.arrow_forward_rounded, size: 30), label: Text(t('Next')), onPressed: _commit),
    ]));
  }

  Widget _easyEnd(BuildContext context) {
    final n = sessionStars(right, done);
    final missed = [for (final (c, ok) in results) if (!ok) c];
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.emoji_events_rounded, size: 110, color: Colors.amber),
        const SizedBox(height: 8),
        Text(done == 0 ? t('Nothing to practise right now.') : t('You finished!'),
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        if (done > 0) ...[
          const SizedBox(height: 12),
          Center(child: stars(n, size: 52, of: 3)),
          const SizedBox(height: 12),
          Text(
              n == 3
                  ? t('Excellent work!')
                  : n == 2
                      ? t('Good work! A little more practice and you have it.')
                      : t('Good try! The ones you missed come back, so you learn them.'),
              style: const TextStyle(fontSize: 20),
              textAlign: TextAlign.center),
        ],
        if (widget.practice && results.isNotEmpty) ...[
          const SizedBox(height: 24),
          FutureBuilder(
            future: sectionTitles(),
            builder: (context, snap) {
              final by = <String, List<bool>>{};
              for (final (c, ok) in results) {
                by.putIfAbsent(snap.data?[c['section']] ?? t('Other questions'), () => []).add(ok);
              }
              return Column(children: [
                for (final e in by.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(child: autoText(e.key, style: const TextStyle(fontSize: 18), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      stars(sessionStars(e.value.where((x) => x).length, e.value.length), size: 26, of: 3),
                    ]),
                  ),
              ]);
            },
          ),
        ],
        const SizedBox(height: 28),
        if (widget.practice && missed.isNotEmpty)
          FilledButton.icon(
              style: easyButton(),
              icon: const Icon(Icons.replay_rounded, size: 30),
              label: Text(t('Practise the ones you missed')),
              onPressed: () => Navigator.pushReplacement(
                  context, MaterialPageRoute(builder: (_) => StudyScreen(missed, easy: true, title: widget.title, scheduler: widget.scheduler)))),
        if (!widget.practice && widget.onMore != null && done > 0)
          FilledButton.icon(
              style: easyButton(),
              icon: const Icon(Icons.play_arrow_rounded, size: 34),
              label: Text(t('Do more')),
              onPressed: () {
                Navigator.pop(context);
                widget.onMore!();
              }),
        const SizedBox(height: 12),
        OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), textStyle: const TextStyle(fontSize: 20)),
            onPressed: () => Navigator.pop(context),
            child: Text(t('Done'))),
      ]),
    );
  }
}
