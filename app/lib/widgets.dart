import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'db.dart';
import 'logic.dart';

const typeLabels = {
  'basic': 'Basic',
  'mcq': 'Multiple choice',
  'cloze': 'Cloze',
  'typed': 'Typed answer',
  'code': 'Code / YAML',
  'occlusion': 'Image occlusion',
  'ordering': 'Ordering',
};

void openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

void toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg)));

class CodeView extends StatelessWidget {
  final String code;
  final String? language;
  const CodeView(this.code, {super.key, this.language});

  @override
  Widget build(BuildContext context) {
    final lang = allLanguages.containsKey(language) ? language! : 'plaintext';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: const Color(0xff282c34), borderRadius: BorderRadius.circular(8)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: HighlightView(code.trimRight(),
            language: lang,
            theme: atomOneDarkTheme,
            padding: const EdgeInsets.all(12),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35)),
      ),
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final cls = element.attributes['class'];
    final text = element.textContent;
    if (cls == null && !text.contains('\n')) return null; // inline code: default style
    return CodeView(text, language: cls?.replaceFirst('language-', ''));
  }
}

class Md extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const Md(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownBody(
      data: text,
      builders: {'code': _CodeBuilder()},
      onTapLink: (_, href, __) => href == null ? null : openUrl(href),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: style ?? theme.textTheme.bodyLarge,
        code: TextStyle(fontFamily: 'monospace', backgroundColor: theme.colorScheme.surfaceContainerHighest, fontSize: 14),
        codeblockDecoration: const BoxDecoration(),
      ),
    );
  }
}

class MediaImage extends StatelessWidget {
  final String name;
  const MediaImage(this.name, {super.key});
  @override
  Widget build(BuildContext context) => Image.file(Db.mediaFile(name),
      errorBuilder: (_, __, ___) =>
          Container(padding: const EdgeInsets.all(16), color: Colors.white10, child: const Text('Image not downloaded yet (sync to fetch it)')));
}

Widget images(List? names) => Column(children: [
      for (final n in (names ?? []).cast<String>())
        Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: MediaImage(n))),
    ]);

/// Occlusion masks over an image. The Stack takes the image's size, so mask fractions map directly.
class OcclusionView extends StatelessWidget {
  final Json card;
  final bool revealed;
  const OcclusionView(this.card, {super.key, this.revealed = false});

  @override
  Widget build(BuildContext context) {
    final masks = ((card['masks'] as List?) ?? []).cast<Map>();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(children: [
        MediaImage(card['image'] ?? ''),
        Positioned.fill(child: CustomPaint(painter: MaskPainter(masks, card['target'] as int?, revealed, Theme.of(context).colorScheme.primary))),
      ]),
    );
  }
}

class MaskPainter extends CustomPainter {
  final List<Map> masks;
  final int? target;
  final bool revealed;
  final Color accent;
  final int? selected;
  MaskPainter(this.masks, this.target, this.revealed, this.accent, {this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < masks.length; i++) {
      final m = masks[i];
      final r =
          Rect.fromLTWH((m['x'] as num) * size.width, (m['y'] as num) * size.height, (m['w'] as num) * size.width, (m['h'] as num) * size.height);
      final tested = target == null || target == i;
      if (revealed && tested) {
        canvas.drawRect(
            r,
            Paint()
              ..color = accent
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
        final label = m['label']?.toString() ?? '';
        if (label.isNotEmpty) {
          final tp = TextPainter(
              text: TextSpan(
                  text: label,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, backgroundColor: Color(0xcc000000))),
              textDirection: TextDirection.ltr,
              maxLines: 2,
              ellipsis: '…')
            ..layout(maxWidth: max(40, r.width));
          tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
        }
      } else {
        canvas.drawRect(r, Paint()..color = tested && target != null ? accent : const Color(0xffb0b0b8));
        if (selected == i)
          canvas.drawRect(
              r,
              Paint()
                ..color = Colors.red
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3);
      }
    }
  }

  @override
  bool shouldRepaint(covariant MaskPainter oldDelegate) => true;
}

final _cloze = RegExp(r'\{\{(.+?)(?:::(.+?))?\}\}');
String clozeFront(String s) => s.replaceAllMapped(_cloze, (m) => '**[${m[2] ?? '…'}]**');
String clozeBack(String s) => s.replaceAllMapped(_cloze, (m) => '**‹${m[1]}›**');

/// What the user has answered for one card, plus grading. Shared by study and exam.
class AnswerState {
  final Json card;
  final List<int> optionOrder; // display order of MCQ options (shuffled on every display)
  final Set<int> selected = {};
  String typed = '';
  List<String> order;
  bool? selfGrade;
  bool? overrideCorrect;
  final int startedAt = nowMs();

  AnswerState(this.card)
      : optionOrder = List.generate(((card['options'] as List?) ?? []).length, (i) => i)..shuffle(),
        order = [...((card['items'] as List?) ?? []).cast<String>()]..shuffle() {
    while (order.length > 1 && listEquals(order, (card['items'] as List).cast<String>())) {
      order.shuffle();
    }
  }

  String get type => card['type'] as String;
  bool get autoGraded => const {'mcq', 'typed', 'ordering'}.contains(type);
  Set<int> get correctSet => ((card['correct'] as List?) ?? []).cast<int>().toSet();
  bool get ready => type != 'mcq' || selected.isNotEmpty;

  bool get correct {
    if (overrideCorrect != null) return overrideCorrect!;
    return switch (type) {
      'mcq' => setEquals(selected, correctSet),
      'typed' => lenientMatch(typed, [card['answer']?.toString() ?? '', ...((card['accepted'] as List?) ?? []).cast<String>()]),
      'ordering' => listEquals(order, (card['items'] as List).cast<String>()),
      _ => selfGrade == true,
    };
  }

  Object? get answer => switch (type) {
        'mcq' => selected.toList()..sort(),
        'typed' => typed,
        'ordering' => order,
        _ => selfGrade,
      };
}

/// Renders a card's question, its answer input, and (when revealed) the answer + explanation.
class CardView extends StatefulWidget {
  final AnswerState state;
  final bool revealed;
  final bool showExplanation;
  final VoidCallback? onChanged;
  final bool misconception;
  const CardView(this.state, {super.key, this.revealed = false, this.showExplanation = true, this.onChanged, this.misconception = false});

  @override
  State<CardView> createState() => _CardViewState();
}

class _CardViewState extends State<CardView> {
  late final _typed = TextEditingController(text: widget.state.typed);

  AnswerState get s => widget.state;
  Json get c => s.card;

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  void didUpdateWidget(CardView old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _typed.text = widget.state.typed;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final revealed = widget.revealed;
    final question = c['question']?.toString() ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (s.type == 'cloze') Md(revealed ? clozeBack(question) : clozeFront(question)) else Md(question),
      if (s.type == 'mcq' && s.correctSet.length > 1)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Choose ${s.correctSet.length}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold))),
      if (s.type == 'code' && (c['code'] ?? '').toString().isNotEmpty) CodeView(c['code'], language: c['language']),
      images(c['question_images']),
      if (s.type == 'occlusion') OcclusionView(c, revealed: revealed),
      const SizedBox(height: 12),
      if (s.type == 'mcq') ..._mcq(cs),
      if (s.type == 'typed') ..._typedInput(cs),
      if (s.type == 'ordering') _ordering(cs),
      if (revealed) ..._answer(cs),
    ]);
  }

  List<Widget> _mcq(ColorScheme cs) {
    final options = (c['options'] as List).cast<String>();
    final expl = ((c['option_explanations'] as List?) ?? []).cast<String>();
    final multi = s.correctSet.length > 1;
    return [
      for (final i in s.optionOrder)
        Builder(builder: (_) {
          final chosen = s.selected.contains(i);
          final right = s.correctSet.contains(i);
          Color? border;
          if (widget.revealed && right) border = Colors.green;
          if (widget.revealed && chosen && !right) border = cs.error;
          if (!widget.revealed && chosen) border = cs.primary;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10), side: BorderSide(color: border ?? Colors.white12, width: border == null ? 1 : 2)),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: widget.revealed
                  ? null
                  : () {
                      if (multi) {
                        chosen ? s.selected.remove(i) : s.selected.add(i);
                      } else {
                        s.selected
                          ..clear()
                          ..add(i);
                      }
                      _changed();
                    },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                        widget.revealed
                            ? (right ? Icons.check_circle : (chosen ? Icons.cancel : Icons.circle_outlined))
                            : (multi
                                ? (chosen ? Icons.check_box : Icons.check_box_outline_blank)
                                : (chosen ? Icons.radio_button_checked : Icons.radio_button_off)),
                        color: border ?? Colors.white54,
                        size: 22),
                    const SizedBox(width: 10),
                    Expanded(child: Md(options[i])),
                  ]),
                  if (widget.revealed && widget.showExplanation && i < expl.length && expl[i].isNotEmpty && (chosen || right))
                    Padding(
                      padding: const EdgeInsets.only(left: 32, top: 6),
                      child: Md(expl[i], style: TextStyle(color: chosen && !right ? cs.error : Colors.white70, fontSize: 14)),
                    ),
                ]),
              ),
            ),
          );
        }),
      if (widget.revealed && widget.showExplanation)
        for (final i in s.optionOrder)
          if (!s.selected.contains(i) && !s.correctSet.contains(i) && i < expl.length && expl[i].isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Md('• *${options[i]}*: ${expl[i]}', style: const TextStyle(color: Colors.white54, fontSize: 13))),
    ];
  }

  List<Widget> _typedInput(ColorScheme cs) => [
        TextField(
          controller: _typed,
          enabled: !widget.revealed,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(labelText: 'Your answer', border: OutlineInputBorder()),
          onChanged: (v) {
            s.typed = v;
            widget.onChanged?.call();
          },
        ),
      ];

  Widget _ordering(ColorScheme cs) {
    final correctOrder = (c['items'] as List).cast<String>();
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: !widget.revealed,
      onReorder: (a, b) {
        if (b > a) b--;
        s.order.insert(b, s.order.removeAt(a));
        _changed();
      },
      children: [
        for (var i = 0; i < s.order.length; i++)
          ListTile(
            key: ValueKey(s.order[i]),
            leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
            title: Md(s.order[i]),
            trailing: widget.revealed
                ? Icon(s.order[i] == correctOrder[i] ? Icons.check : Icons.close, color: s.order[i] == correctOrder[i] ? Colors.green : cs.error)
                : const Icon(Icons.drag_handle),
          ),
      ],
    );
  }

  List<Widget> _answer(ColorScheme cs) {
    final c = this.c;
    final out = <Widget>[const Divider(height: 28)];
    if (widget.misconception) {
      out.add(Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(Icons.warning_amber, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
              child: Text('Misconception: you were sure, but wrong. Read this carefully; the card will come back soon.',
                  style: TextStyle(color: cs.onErrorContainer))),
        ]),
      ));
    }
    if (s.autoGraded) {
      out.add(Row(children: [
        Icon(s.correct ? Icons.check_circle : Icons.cancel, color: s.correct ? Colors.green : cs.error),
        const SizedBox(width: 8),
        Text(s.correct ? 'Correct' : 'Incorrect', style: TextStyle(fontSize: 18, color: s.correct ? Colors.green : cs.error)),
      ]));
    }
    if (s.type == 'typed') out.add(Md('**Answer:** `${c['answer']}`'));
    if (s.type == 'ordering') {
      out.add(Md('**Correct order:**\n\n${[for (final (i, it) in (c['items'] as List).indexed) '${i + 1}. $it'].join('\n')}'));
    }
    if (s.type != 'typed' && s.type != 'cloze' && (c['answer'] ?? '').toString().isNotEmpty) out.add(Md(c['answer']));
    if ((c['answer_code'] ?? '').toString().isNotEmpty) out.add(CodeView(c['answer_code'], language: c['language']));
    out.add(images(c['answer_images']));
    if (widget.showExplanation && (c['explanation'] ?? '').toString().isNotEmpty) {
      out.add(Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: widget.misconception ? cs.errorContainer.withOpacity(.35) : cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Explanation', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Md(c['explanation']),
        ]),
      ));
    }
    final help = c['leech_help'];
    if (widget.showExplanation && help is Map && (help['explanation'] ?? '').toString().isNotEmpty) {
      out.add(Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: cs.tertiaryContainer.withOpacity(.4), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Another way to see it', style: TextStyle(color: cs.tertiary, fontWeight: FontWeight.bold)),
          Md(help['explanation']),
        ]),
      ));
    }
    return out;
  }
}

/// Shown on AI screens when a call fails offline.
class NeedsConnection extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const NeedsConnection(this.message, {super.key, this.onRetry});
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: ListTile(
          leading: Icon(message.startsWith('Needs connection') ? Icons.cloud_off : Icons.error_outline),
          title: Text(message),
          trailing: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      );
}

/// Runs [f] with a modal spinner; returns its result or null after showing the error.
Future<T?> busy<T>(BuildContext context, String label, Future<T> Function() f) async {
  showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(content: Row(children: [const CircularProgressIndicator(), const SizedBox(width: 16), Expanded(child: Text(label))]))));
  try {
    return await f();
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

class OnlineBanner extends StatelessWidget {
  const OnlineBanner({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
      valueListenable: Api.online,
      builder: (_, v, __) => v == false
          ? Container(
              width: double.infinity,
              color: Colors.orange.withOpacity(.2),
              padding: const EdgeInsets.all(6),
              child:
                  const Text('Offline: studying works, AI features need a connection', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)))
          : const SizedBox.shrink());
}

/// Re-runs [load] when local data changes, but only while this route is on top, so screens
/// underneath a study session don't re-query on every answer. Keeps showing the last result while reloading.
class Live<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  const Live({super.key, required this.load, required this.builder});
  @override
  State<Live<T>> createState() => _LiveState<T>();
}

class _LiveState<T> extends State<Live<T>> {
  Future<T>? future;
  int seen = -1;

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    return ValueListenableBuilder<int>(
      valueListenable: changes,
      builder: (context, v, _) {
        if ((current || future == null) && v != seen) {
          seen = v;
          future = widget.load();
        }
        return FutureBuilder<T>(
          future: future,
          builder: (context, snap) => snap.hasData
              ? widget.builder(context, snap.data as T)
              : Center(child: snap.hasError ? Text('${snap.error}') : const CircularProgressIndicator()),
        );
      },
    );
  }
}
