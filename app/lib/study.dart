import 'package:flutter/material.dart';

import 'ai.dart';
import 'api.dart';
import 'cards.dart';
import 'db.dart';
import 'logic.dart';
import 'widgets.dart';

/// Queue with Anki-style relearning: cards due again within 30 min come back this session.
class Session {
  final List<Json> queue;
  final List<Json> pending = [];
  Session(this.queue);

  int get remaining => queue.length + pending.length;

  Json? next() {
    pending.sort((a, b) => dueOf(a).compareTo(dueOf(b)));
    if (pending.isNotEmpty && dueOf(pending.first) <= nowMs()) return pending.removeAt(0);
    if (queue.isNotEmpty) return queue.removeAt(0);
    return pending.isEmpty ? null : pending.removeAt(0);
  }

  void answered(Json card) {
    if (dueOf(card) <= nowMs() + 30 * 60000) pending.add(card);
  }
}

class StudyScreen extends StatefulWidget {
  final List<Json> queue;
  final String source;
  final String title;
  const StudyScreen(this.queue, {super.key, this.source = 'study', this.title = 'Study'});
  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late final session = Session([...widget.queue]);
  Json? card;
  AnswerState? ans;
  Conf? conf;
  bool revealed = false;
  int done = 0, right = 0;

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

  bool get graded => ans!.autoGraded || ans!.selfGrade != null;
  bool get misconception => revealed && graded && conf == Conf.sure && !ans!.correct;

  Future<void> _commit() async {
    final a = ans!;
    final updated = await recordAnswer(card!, conf: conf!, correct: a.correct, source: widget.source, durationMs: nowMs() - a.startedAt, answer: a.answer);
    if (widget.source == 'study') session.answered(updated);
    done++;
    if (a.correct) right++;
    _next();
  }

  void _selfGrade(bool correct) {
    setState(() => ans!.selfGrade = correct);
    if (!misconception) _commit(); // a misconception stays on screen until "Next"
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (card == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.celebration, size: 64),
            const SizedBox(height: 12),
            Text(done == 0 ? 'Nothing to study right now.' : 'Session done: $done cards, ${(100 * right / done).round()}% correct',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
          ]),
        ),
      );
    }
    final c = card!;
    final cert = App.cert;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.title} · ${session.remaining + 1} left', style: const TextStyle(fontSize: 18)),
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
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit card')),
              PopupMenuItem(value: 'details', child: Text('Card details & history')),
              PopupMenuItem(value: 'suspend', child: Text('Suspend card')),
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
                _chip(typeLabels[c['type']] ?? c['type']),
                if (domainOf(c, cert).isNotEmpty) _chip(domainName(cert, domainOf(c, cert))),
                if (isNew(c)) _chip('New', color: cs.primary),
                if (c['misconception'] == true) _chip('Misconception', color: cs.error),
                if (c['leech'] == true) _chip('Leech', color: Colors.orange),
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
            child: Text(ready ? 'How confident are you?' : 'Pick an answer first', style: const TextStyle(color: Colors.white54, fontSize: 12))),
        bar([
          btn(Conf.guess, 'Guessing', Icons.casino_outlined, Colors.orange),
          btn(Conf.unsure, 'Unsure', Icons.help_outline, Colors.amber),
          btn(Conf.sure, 'Sure', Icons.verified_outlined, Colors.green),
        ]),
      ]);
    }
    if (!graded) {
      return bar([
        FilledButton.tonal(onPressed: () => _selfGrade(false), style: FilledButton.styleFrom(foregroundColor: cs.error), child: const Text('I was wrong')),
        FilledButton(onPressed: () => _selfGrade(true), child: const Text('I was right')),
      ]);
    }
    return bar([
      if (ans!.autoGraded)
        TextButton(
            onPressed: () => setState(() => ans!.overrideCorrect = !ans!.correct),
            child: Text(ans!.correct ? 'Actually wrong' : 'Actually right')),
      FilledButton(onPressed: _commit, child: const Text('Next')),
    ]);
  }
}
