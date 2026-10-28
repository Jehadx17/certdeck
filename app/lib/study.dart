import 'dart:math';

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
  /// The easy version for students (EASY.md): confidence buttons that reveal, plain feedback, a score at the end.
  final bool easy;
  /// A practice test (easy): a score per topic at the end and a round of the missed questions.
  final bool practice;
  /// "Do more" at the end of a easy session.
  final VoidCallback? onMore;
  /// Drill: show only rewritten versions, never the original wording.
  final bool rewriteOnly;
  const StudyScreen(this.queue,
      {super.key, this.source = 'study', this.title = 'Study', this.custom, this.scheduler, this.easy = false, this.practice = false, this.onMore, this.rewriteOnly = false});
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
  final calib = <(Conf, bool)>[]; // confidence and result of each answer, for the calibration line
  final started = DateTime.now();
  late final int planned = widget.custom?.remaining ?? widget.queue.length;
  bool completed = false, studying = false; // studying: a new card shown first, for a student new to the subject
  Map<String, List> versions = {}; // card id -> its rewritten versions ("Rotate card versions" on)
  late bool loading = App.settings['rotate_versions'] == true || widget.rewriteOnly;
  int shownVer = 0;

  @override
  void initState() {
    super.initState();
    if (!loading) return _next();
    Db.query('versions').then((vs) {
      versions = {for (final v in vs) v['card_id'] as String: (v['versions'] as List?) ?? []};
      loading = false;
      if (mounted) _next();
    });
  }

  @override
  void dispose() {
    if (!completed && done > 0) _logSession();
    super.dispose();
  }

  /// One doc per session: planned vs answered, finished or left early (the autopilot's completion signal).
  void _logSession() => Db.put('session', {
        'id': 'sess-${started.millisecondsSinceEpoch}',
        'started_at': started.millisecondsSinceEpoch,
        'ended_at': nowMs(),
        'source': widget.source,
        'planned': planned,
        'done': done,
        'completed': completed,
      }).ignore();

  int get minutes => max(1, (DateTime.now().difference(started).inSeconds / 60).round());

  /// "You said Sure 8 times and were right 6." Only once there are a few Sure answers to talk about.
  String? get calibrationLine {
    final s = sureStats(calib);
    if (s.sure < 3) return null;
    final line = t('You said Sure {n} times and were right {r}.', {'n': s.sure, 'r': s.sureRight});
    return s.sureRight < s.sure ? '$line ${t('When you are Sure and wrong, that is the best moment to learn it.')}' : line;
  }

  void _next() => setState(() {
        card = session.next();
        ans = null;
        if (card != null) {
          final (i, shown) = pickVersion(card!, versions[card!['id']] ?? const [], rewriteOnly: widget.rewriteOnly);
          shownVer = i;
          ans = AnswerState(shown);
        }
        conf = null;
        revealed = false;
        studying = widget.easy && card != null && studyFirst(card!);
        if (studying) {
          conf = Conf.unsure;
          revealed = true;
          ans!.overrideCorrect = true;
          ans!.selfGrade = true;
        }
        if (card == null) {
          completed = true;
          if (done > 0) _logSession();
          Api.sync().ignore();
        }
      });

  bool get graded => ans!.written ? ans!.graded : (ans!.autoGraded || ans!.selfGrade != null);
  bool get misconception => revealed && graded && conf == Conf.sure && ans!.score < .4;

  Future<void> _commit() async {
    final a = ans!;
    if (versions.containsKey(card!['id'])) card!['ver'] = shownVer;
    final updated = await recordAnswer(card!,
        conf: conf!,
        correct: a.correct,
        source: widget.source,
        durationMs: nowMs() - a.startedAt,
        answer: a.answer,
        score: a.written ? a.score : null,
        scheduler: widget.scheduler,
        studyFirst: studying,
        shownVer: versions.containsKey(card!['id']) ? shownVer : null,
        errorType: (a.written && !a.correct) ? (a.aiGrade ?? const {})['error_type']?.toString() : null);
    session.answered(updated, a.score);
    done++;
    if (a.correct) right++;
    if (!studying) calib.add((conf!, a.correct));
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
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
            if (done > 0) Text(t('{m} min', {'m': minutes}), style: const TextStyle(color: Colors.white60)),
            if (calibrationLine != null)
              Padding(padding: const EdgeInsets.fromLTRB(24, 10, 24, 0), child: Text(calibrationLine!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))),
            const SizedBox(height: 20),
            if (done > 0 && widget.onMore != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton.tonal(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onMore!();
                      },
                      child: Text(t('Do more')))),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(t('Back'))),
          ]),
        ),
      );
    }
    final c = card!;
    final owner = App.isOwner;
    return Scaffold(
      appBar: AppBar(
        leading: owner ? IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.maybePop(context)) : null,
        title: owner ? null : Text('${widget.title} · ${t('{n} left', {'n': session.remaining + 1})}', style: const TextStyle(fontSize: 18)),
        bottom: owner
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3, value: planned == 0 ? 0 : (done / planned).clamp(0.0, 1.0)))
            : null,
        actions: [
          if (owner)
            Center(
                child: Text(
                    // The session title (a Drill name) stays, small and muted; the default "Study" is dropped.
                    '${widget.title == 'Study' ? '' : '${widget.title} · '}${t('{n} left', {'n': session.remaining + 1})}',
                    style: const TextStyle(fontSize: 12, color: Colors.white54)))
          else
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
              } else if (v == 'ask') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(c)));
              } else if (v == 'details') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(c['id'])));
              }
            },
            itemBuilder: (_) => [
              if (owner) PopupMenuItem(value: 'ask', child: Text(t('Ask AI'))),
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
              CardView(ans!, key: ObjectKey(ans), revealed: revealed, misconception: misconception, onChanged: () => setState(() {})),
              if (revealed && owner) _afterReveal(c),
              const SizedBox(height: 80),
            ]),
          ),
          _bottom(cs),
        ]),
      ),
    );
  }

  /// Tags and Ask AI, only after the reveal (nothing around the card may hint at the answer before).
  Widget _afterReveal(Json c) {
    final tags = ((c['tags'] as List?) ?? []).cast<String>();
    return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final g in tags) Chip(label: Text(g, style: const TextStyle(fontSize: 12)), visualDensity: VisualDensity.compact),
          TextButton.icon(
              icon: const Icon(Icons.forum_outlined, size: 18),
              label: Text(t('Ask AI')),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(c)))),
        ]));
  }

  Widget _bottom(ColorScheme cs) {
    Widget bar(List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(color: cs.surfaceContainer, border: const Border(top: BorderSide(color: Colors.white10))),
        child: Row(children: [for (final w in children) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: w))]));
    if (!revealed) {
      final ready = ans!.ready;
      if (!App.isOwner) {
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
      ButtonSegment<Conf> seg(Conf c, String label, Color color) => ButtonSegment(value: c, label: Text(label, style: TextStyle(color: ready ? color : null)));
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(ready ? t('How confident are you?') : t('Pick an answer first'), style: const TextStyle(color: Colors.white54, fontSize: 12))),
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<Conf>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  selected: const {},
                  segments: [
                    seg(Conf.guess, t('Guessing'), Colors.orange),
                    seg(Conf.unsure, t('Unsure'), Colors.amber),
                    seg(Conf.sure, t('Sure'), Colors.green),
                  ],
                  onSelectionChanged: ready
                      ? (s) => setState(() {
                            conf = s.first;
                            revealed = true;
                          })
                      : null,
                ))),
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
          title: Text(t('{n} left', {'n': session.remaining + 1})),
          actions: [helpButton(context, studyHelp)],
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                if (studying)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(t('A new one! Read it, then tap Got it. It comes back soon as a question.'), style: const TextStyle(fontSize: 14, color: Colors.white60))),
                CardView(ans!, key: ObjectKey(ans), revealed: revealed, easy: true, misconception: misconception, onChanged: () => setState(() {})),
                const SizedBox(height: 40),
              ]),
            ),
            _easyBottom(cs),
          ]),
        ),
      );

  /// How sure you are doubles as the Check button: one tap rates the confidence and shows the answer.
  void _easyCheck(Conf c) {
    setState(() {
      conf = c;
      revealed = true;
    });
    if (ans!.autoGraded && ans!.correct) HapticFeedback.mediumImpact();
  }

  void _easyVerdict(bool yes) {
    if (yes) HapticFeedback.mediumImpact();
    setState(() => ans!.written ? ans!.selfScore = yes ? 1 : 0 : ans!.selfGrade = yes);
    if (!misconception) _commit(); // sure but wrong: the warning stays on screen until Next
  }

  Widget _easyBottom(ColorScheme cs) {
    Widget bar(Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        decoration: BoxDecoration(color: cs.surfaceContainer, border: const Border(top: BorderSide(color: Colors.white10))),
        child: child);
    final a = ans!;
    if (studying) {
      return bar(FilledButton.icon(style: easyButton(), icon: const Icon(Icons.check_rounded), label: Text(t('Got it')), onPressed: _commit));
    }
    if (!revealed) {
      final empty = (a.type == 'typed' || a.written) && a.typed.trim().isEmpty;
      if (!a.ready || empty) {
        return bar(FilledButton.icon(
            style: easyButton(),
            icon: const Icon(Icons.visibility_rounded),
            label: Text(a.ready ? t('Show me the answer') : t('Pick an answer')),
            onPressed: a.ready ? () => _easyCheck(Conf.guess) : null));
      }
      Widget sure(Conf c, String label, IconData icon, Color color) => Expanded(
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56), padding: const EdgeInsets.symmetric(vertical: 6), backgroundColor: color.withOpacity(.22), foregroundColor: color,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                  onPressed: () => _easyCheck(c),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 22),
                    FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                  ]))));
      return bar(Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t('How sure are you?'), style: const TextStyle(fontSize: 13, color: Colors.white60)),
        const SizedBox(height: 8),
        Row(children: [
          sure(Conf.guess, t('Guessing'), Icons.casino_outlined, Colors.orange),
          sure(Conf.unsure, t('Unsure'), Icons.help_outline, Colors.amber),
          sure(Conf.sure, t('Sure'), Icons.verified_outlined, Colors.green),
        ]),
      ]));
    }
    if (!graded) {
      return bar(Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t('Did you get it?'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: FilledButton.icon(
                  style: easyButton(const Color(0xFF9A6A5E)), icon: const Icon(Icons.replay_rounded), label: Text(t('Not yet')), onPressed: () => _easyVerdict(false))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton.icon(
                  style: easyButton(const Color(0xFF5E8A6A)), icon: const Icon(Icons.thumb_up_alt_rounded), label: Text(t('Yes')), onPressed: () => _easyVerdict(true))),
        ]),
      ]));
    }
    final ok = a.correct;
    return bar(Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(ok ? Icons.celebration_rounded : Icons.replay_rounded, size: 24, color: ok ? Colors.amber : Colors.orangeAccent),
        const SizedBox(width: 10),
        Expanded(
            child: Text(ok ? t('Great job!') : (widget.practice ? t('Not quite. Read the answer, then go on.') : t('Not quite. It will come back in a moment.')),
                style: const TextStyle(fontSize: 15))),
      ]),
      const SizedBox(height: 10),
      FilledButton.icon(style: easyButton(), icon: const Icon(Icons.arrow_forward_rounded), label: Text(t('Next')), onPressed: _commit),
    ]));
  }

  Widget _easyEnd(BuildContext context) {
    final n = sessionTier(right, done);
    final missed = [for (final (c, ok) in results) if (!ok) c];
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.emoji_events_rounded, size: 72, color: Colors.amber),
        const SizedBox(height: 8),
        Text(done == 0 ? t('Nothing to practise right now.') : t('You finished!'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        if (done > 0) ...[
          const SizedBox(height: 12),
          if (App.settings['nerves'] != true) // students who get nervous about tests see no score, only the message
            Text(t('{r} of {n} right', {'r': right, 'n': done}), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          Text(t('{n} cards · {m} min', {'n': done, 'm': minutes}), style: const TextStyle(fontSize: 14, color: Colors.white60), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
              n == 3
                  ? t('Excellent work!')
                  : n == 2
                      ? t('Good work! A little more practice and you have it.')
                      : t('Good try! The ones you missed come back, so you learn them.'),
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center),
          if (calibrationLine != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(calibrationLine!, style: const TextStyle(fontSize: 14, color: Colors.white70), textAlign: TextAlign.center)),
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
                      Expanded(child: autoText(e.key, style: const TextStyle(fontSize: 14), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      Text('${e.value.where((x) => x).length}/${e.value.length}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
              icon: const Icon(Icons.replay_rounded),
              label: Text(t('Practise the ones you missed')),
              onPressed: () => Navigator.pushReplacement(
                  context, MaterialPageRoute(builder: (_) => StudyScreen(missed, easy: true, title: widget.title, scheduler: widget.scheduler)))),
        if (!widget.practice && widget.onMore != null && done > 0)
          FilledButton.icon(
              style: easyButton(),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(t('Do more')),
              onPressed: () {
                Navigator.pop(context);
                widget.onMore!();
              }),
        const SizedBox(height: 12),
        OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), textStyle: const TextStyle(fontSize: 15)),
            onPressed: () => Navigator.pop(context),
            child: Text(t('Done'))),
      ]),
    );
  }
}
