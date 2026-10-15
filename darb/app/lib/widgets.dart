import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';

const typeLabels = {
  'basic': 'Basic',
  'mcq': 'Multiple choice',
  'cloze': 'Cloze',
  'typed': 'Typed answer',
  'code': 'Code / YAML',
  'occlusion': 'Image occlusion',
  'ordering': 'Ordering',
  'short': 'Short answer',
  'problem': 'Problem',
};

void openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// Secondary text that reads in both themes (CertDeck was dark-only and used white54/60/70).
Color muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

void toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg)));

class CodeView extends StatelessWidget {
  final String code;
  final String? language;
  const CodeView(this.code, {super.key, this.language});

  /// The AI sometimes wraps a code field in its own ``` fence: show only the code.
  static String unfence(String code) {
    final m = RegExp(r'^\s*```[\w+-]*\n([\s\S]*?)\n?```\s*$').firstMatch(code);
    return m == null ? code : m[1]!;
  }

  @override
  Widget build(BuildContext context) {
    final lang = allLanguages.containsKey(language) ? language! : 'plaintext';
    return Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: const Color(0xff282c34), borderRadius: BorderRadius.circular(8)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: HighlightView(unfence(code).trimRight(),
            language: lang,
            theme: atomOneDarkTheme,
            padding: const EdgeInsets.all(12),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35)),
      ),
    ));
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

/// `$…$` inline and `$$…$$` display LaTeX. Like pandoc, `$` must hug the formula (`$5 and $10` stays text).
class _MathSyntax extends md.InlineSyntax {
  _MathSyntax() : super(r'\$\$([\s\S]+?)\$\$|\$(?=\S)((?:\\\$|[^$\n])+?)(?<=\S)\$(?!\d)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match m) {
    parser.addNode(md.Element.text(m[1] != null ? 'mathblock' : 'math', (m[1] ?? m[2])!.trim()));
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  final bool display;
  _MathBuilder(this.display);

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final style = parentStyle ?? DefaultTextStyle.of(context).style;
    final math = Math.tex(element.textContent,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: style.copyWith(fontSize: (style.fontSize ?? 16) * (display ? 1.1 : 1)),
        onErrorFallback: (_) => Text(element.textContent, style: style.copyWith(fontFamily: 'monospace')));
    // Formulas are LTR inside Arabic text and scroll sideways rather than overflow a phone screen.
    final child = Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: display ? Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: math) : math));
    return Text.rich(WidgetSpan(alignment: PlaceholderAlignment.middle, child: display ? SizedBox(width: double.infinity, child: Center(child: child)) : child));
  }
}

final _arabic = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]');
final _latin = RegExp(r'[A-Za-z]');
final _notProse = RegExp(r'```[\s\S]*?```|`[^`]*`|\$\$[\s\S]*?\$\$|\$[^$]*\$');

/// Right-to-left when most letters (outside code and math) are Arabic: an Arabic card reads RTL in an English UI.
bool isRtl(String text) {
  final prose = text.replaceAll(_notProse, ' ');
  return _arabic.allMatches(prose).length > _latin.allMatches(prose).length;
}

// Unicode directional isolates: LRI / RLI open a left-to-right / right-to-left run, PDI closes it.
const _lri = '\u2066', _rli = '\u2067', _pdi = '\u2069';
// Code spans, math, fenced blocks, links and URLs are left alone.
final _keep = RegExp(r'```[\s\S]*?```|`[^`]*`|\$\$[\s\S]*?\$\$|\$[^$\n]+\$|\[[^\]]*\]\([^)]*\)|https?://\S+');
// A run of the other script: starts and ends with a letter/digit of that script, may hold spaces and the
// punctuation that belongs inside a phrase ("one copy per class", "Trace the code", "مشتركة بين الكائنات").
// Runs start and end with a letter/digit, so brackets around a term stay outside and pair up in the paragraph.
final _latinRun = RegExp(r"[A-Za-z0-9](?:[A-Za-z0-9 .,:;'’/+=&%_#()*‹›\[\]…-]*[A-Za-z0-9?!])?");
final _arabicRun = RegExp(r'[\u0600-\u06FF](?:[\u0600-\u06FF\u0750-\u077F0-9 ،؛.,:()«»*‹›\[\]…-]*[\u0600-\u06FF])?');

/// Wraps every run of the other script in a directional isolate, so English inside an Arabic sentence (and the
/// other way round) renders as one unit with its own spaces and punctuation instead of being reordered piecemeal.
String isolateRuns(String text, {required bool rtl}) {
  final run = rtl ? _latinRun : _arabicRun;
  final open = rtl ? _lri : _rli;
  final out = StringBuffer();
  var last = 0;
  void prose(String s) => out.write(_isolate(s, run, open));
  for (final m in _keep.allMatches(text)) {
    prose(text.substring(last, m.start));
    out.write(rtl ? '$_lri${m[0]}$_pdi' : m[0]);
    last = m.end;
  }
  prose(text.substring(last));
  return out.toString();
}

/// Isolates each run; a run that opens a marker (bold `**`, cloze ‹ › [ ], brackets) without closing it takes the
/// closing marker that follows it (and the other way round), so "one copy per ‹**class**›" stays one unit.
String _isolate(String s, RegExp run, String open) {
  int count(String t, String c) => c.allMatches(t).length;
  bool unbalanced(String t) =>
      count(t, '‹') != count(t, '›') || count(t, '[') != count(t, ']') || count(t, '(') != count(t, ')') || count(t, '*').isOdd;
  final out = StringBuffer();
  var i = 0;
  for (final m in run.allMatches(s)) {
    if (m.start < i) continue;
    var a = m.start, b = m.end;
    while (unbalanced(s.substring(a, b))) {
      if (b < s.length && '*_›])'.contains(s[b])) {
        b++;
      } else if (a > i && '*_‹[('.contains(s[a - 1])) {
        a--;
      } else {
        break;
      }
    }
    out
      ..write(s.substring(i, a))
      ..write('$open${s.substring(a, b)}$_pdi');
    i = b;
  }
  out.write(s.substring(i));
  return out.toString();
}

/// A name or title inside a UI sentence keeps its own direction (first-strong isolate).
String iso(Object? s) => '\u2068$s$_pdi';

class Md extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const Md(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Numbers and symbols alone ("24", "3 × 4") follow the screen's direction instead of falling back to left-to-right.
    final rtl = _arabic.hasMatch(text) || _latin.hasMatch(text) ? isRtl(text) : Directionality.of(context) == TextDirection.rtl;
    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: MarkdownBody(
        data: isolateRuns(text, rtl: rtl),
        inlineSyntaxes: [_MathSyntax()],
        builders: {'code': _CodeBuilder(), 'math': _MathBuilder(false), 'mathblock': _MathBuilder(true)},
        onTapLink: (_, href, __) => href == null ? null : openUrl(href),
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: style ?? theme.textTheme.bodyLarge,
          code: TextStyle(fontFamily: 'monospace', backgroundColor: theme.colorScheme.surfaceContainerHighest, fontSize: 14),
          codeblockDecoration: const BoxDecoration(),
        ),
      ),
    );
  }
}

/// Fills the available width (aspect ratio kept) so occlusion masks, which are fractions of the
/// drawn size, line up with the image. [fill] false = natural size (for FittedBox thumbnails).
class MediaImage extends StatelessWidget {
  final String name;
  final bool fill;
  const MediaImage(this.name, {super.key, this.fill = true});
  @override
  Widget build(BuildContext context) => Image.file(Db.mediaFile(name),
      width: fill ? double.infinity : null,
      fit: fill ? BoxFit.fitWidth : null,
      errorBuilder: (_, __, ___) =>
          Container(padding: const EdgeInsets.all(16), color: Theme.of(context).colorScheme.outlineVariant, child: Text(t('Image not downloaded yet (sync to fetch it)'))));
}

/// Card images; tap one to view it full screen with pinch-zoom (diagrams have small labels on a phone).
Widget images(List? names) => Column(children: [
      for (final n in (names ?? []).cast<String>())
        Builder(
          builder: (context) => GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                    appBar: AppBar(),
                    body: InteractiveViewer(maxScale: 6, child: Center(child: MediaImage(n)))))),
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: MediaImage(n))),
          ),
        ),
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
        if (selected == i) {
          canvas.drawRect(
              r,
              Paint()
                ..color = Colors.red
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant MaskPainter oldDelegate) => true;
}

final _cloze = RegExp(r'\{\{(.+?)(?:::(.+?))?\}\}');
// `{{x}}` → {{`x`}} so the blank's bold markers aren't trapped inside an inline code span.
String _unwrapCode(String s) => s.replaceAllMapped(RegExp(r'`\{\{(.+?)(?:::(.+?))?\}\}`'), (m) => '{{`${m[1]}`${m[2] == null ? '' : '::${m[2]}'}}}');
// Brackets go outside the bold markers: `**[` right after a letter (Arabic "بـ**[…]**") isn't bold in Markdown.
String clozeFront(String s) => _unwrapCode(s).replaceAllMapped(_cloze, (m) => '[**${m[2] ?? '…'}**]');
String clozeBack(String s) => _unwrapCode(s).replaceAllMapped(_cloze, (m) => '‹**${m[1]}**›');

/// What the user has answered for one card, plus grading. Shared by study and exam.
class AnswerState {
  final Json card;
  final List<int> optionOrder; // display order of MCQ options (shuffled on every display)
  final Set<int> selected = {};
  String typed = '';
  List<String> order;
  bool? selfGrade;
  double? selfScore; // written answers: Wrong 0 / Partly .5 / Right 1
  bool? overrideCorrect;
  final Set<int> rubricMet = {}; // written answers: rubric points the student ticked
  bool rubricTouched = false;
  Json? aiGrade; // {score, verdict, points, feedback} from college/grade
  final int startedAt = nowMs();

  AnswerState(this.card)
      : optionOrder = List.generate(((card['options'] as List?) ?? []).length, (i) => i)..shuffle(),
        order = [...((card['items'] as List?) ?? []).cast<String>()]..shuffle() {
    while (order.length > 1 && listEquals(order, (card['items'] as List).cast<String>())) {
      order.shuffle();
    }
  }

  String get type => card['type'] as String;
  bool get written => type == 'short' || type == 'problem';
  bool get autoGraded => const {'mcq', 'typed', 'ordering'}.contains(type) || numericMatch == true;
  Set<int> get correctSet => ((card['correct'] as List?) ?? []).cast<int>().toSet();
  bool get ready => type != 'mcq' || selected.isNotEmpty;
  List<Map> get rubric => ((card['rubric'] as List?) ?? []).cast<Map>();

  /// A problem's typed final answer matches its verified numeric answer (null = can't tell locally).
  bool? get numericMatch {
    final check = card['check'];
    if (type != 'problem' || check is! Map || check['kind'] != 'numeric') return null;
    final want = double.tryParse('${check['value']}'.trim());
    final got = double.tryParse(typed.trim().replaceAll(',', '.').replaceAll(RegExp(r'[^0-9eE+\-.]'), ''));
    if (want == null || got == null) return null;
    final tol = max(((check['tolerance'] as num?) ?? 1e-3).toDouble(), 1e-3 * want.abs());
    return (got - want).abs() <= tol;
  }

  /// Written answers are graded (AI, rubric ticks or the student's own verdict) before moving on.
  bool get graded => !written || aiGrade != null || rubricTouched || selfScore != null || overrideCorrect != null || numericMatch == true;

  /// 0..1: partial credit for written answers, otherwise 1 or 0.
  double get score {
    if (overrideCorrect != null) return overrideCorrect! ? 1 : 0;
    if (!written) return correct ? 1 : 0;
    if (aiGrade != null) return (aiGrade!['score'] as num).toDouble();
    if (numericMatch == true) return 1;
    if (rubricTouched) return rubricMet.fold(0.0, (t, i) => t + ((rubric.elementAtOrNull(i)?['weight'] as num?) ?? 0).toDouble());
    return selfScore ?? 0;
  }

  bool get correct {
    if (overrideCorrect != null) return overrideCorrect!;
    if (written) return score >= .85;
    return switch (type) {
      'mcq' => setEquals(selected, correctSet),
      'typed' => lenientMatch(typed, [card['answer']?.toString() ?? '', ...((card['accepted'] as List?) ?? []).cast<String>()]),
      'ordering' => listEquals(order, (card['items'] as List).cast<String>()),
      _ => selfGrade == true,
    };
  }

  Object? get answer => switch (type) {
        'mcq' => selected.toList()..sort(),
        'typed' || 'short' || 'problem' => typed,
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
  /// The easy version (EASY.md): no percentages or AI grading, a problem's steps one at a time.
  final bool easy;
  const CardView(this.state,
      {super.key, this.revealed = false, this.showExplanation = true, this.onChanged, this.misconception = false, this.easy = false});

  @override
  State<CardView> createState() => _CardViewState();
}

class _CardViewState extends State<CardView> {
  late final _typed = TextEditingController(text: widget.state.typed);
  int _steps = 1; // easy: problem steps shown so far
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
      s.type == 'cloze' ? Md(revealed ? clozeBack(question) : clozeFront(question)) : Md(question),
      if (s.type == 'mcq' && s.correctSet.length > 1)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t('Choose {n}', {'n': s.correctSet.length}), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold))),
      if (s.type == 'code' && (c['code'] ?? '').toString().isNotEmpty) CodeView(c['code'], language: c['language']),
      images(c['question_images']),
      if (s.type == 'occlusion') OcclusionView(c, revealed: revealed),
      const SizedBox(height: 12),
      if (s.type == 'mcq') ..._mcq(cs),
      if (s.type == 'typed') ..._typedInput(cs),
      if (s.written) ..._writtenInput(cs),
      if (s.type == 'ordering') _ordering(cs),
      if (revealed) ..._answer(cs),
    ]);
  }

  List<Widget> _writtenInput(ColorScheme cs) => [
        TextField(
          controller: _typed,
          enabled: !widget.revealed,
          minLines: s.type == 'short' ? 3 : 1,
          maxLines: 12,
          decoration: InputDecoration(
              labelText: s.type == 'problem' ? t('Your final answer (work it out on paper)') : t('Your answer'), border: const OutlineInputBorder()),
          onChanged: (v) {
            s.typed = v;
            widget.onChanged?.call();
          },
        ),
      ];

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
                borderRadius: BorderRadius.circular(10), side: BorderSide(color: border ?? Theme.of(context).colorScheme.outlineVariant, width: border == null ? 1 : 2)),
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
                        color: border ?? muted(context),
                        size: 22),
                    const SizedBox(width: 10),
                    Expanded(child: Md(options[i])),
                  ]),
                  if (widget.revealed && widget.showExplanation && i < expl.length && expl[i].isNotEmpty && (chosen || right))
                    Padding(
                      padding: const EdgeInsets.only(left: 32, top: 6),
                      child: Md(expl[i], style: TextStyle(color: chosen && !right ? cs.error : muted(context), fontSize: 14)),
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
                child: Md('• *${options[i]}*: ${expl[i]}', style: TextStyle(color: muted(context), fontSize: 13))),
    ];
  }

  List<Widget> _typedInput(ColorScheme cs) => [
        TextField(
          controller: _typed,
          enabled: !widget.revealed,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(labelText: t('Your answer'), border: const OutlineInputBorder()),
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

  /// Rubric self-check, quick verdicts and AI grading for short answers and problems.
  Widget _grading(ColorScheme cs) {
    final g = s.aiGrade;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(t('Marking'), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold))),
          if (s.graded && s.numericMatch != true && !widget.easy) Text(t('Score {p}%', {'p': (s.score * 100).round()}), style: const TextStyle(fontWeight: FontWeight.bold)),
          if (s.numericMatch == true) Text(t('Final answer matches'), style: const TextStyle(color: Colors.green)),
        ]),
        for (final (i, r) in s.rubric.indexed)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: g != null ? ((g['points'] as List?)?.elementAtOrNull(i)?['met'] == true) : s.rubricMet.contains(i),
            onChanged: g != null || widget.onChanged == null
                ? null
                : (v) {
                    s.rubricTouched = true;
                    v == true ? s.rubricMet.add(i) : s.rubricMet.remove(i);
                    _changed();
                  },
            title: Md('${r['point']}', style: const TextStyle(fontSize: 14)),
            subtitle: g != null && ((g['points'] as List?)?.elementAtOrNull(i)?['note'] ?? '').toString().isNotEmpty
                ? Text('${(g['points'] as List)[i]['note']}',
                    style: const TextStyle(fontSize: 12), textDirection: isRtl('${(g['points'] as List)[i]['note']}') ? TextDirection.rtl : TextDirection.ltr)
                : null,
            secondary: widget.easy ? null : Text('${(((r['weight'] as num?) ?? 0) * 100).round()}%', style: TextStyle(fontSize: 12, color: muted(context))),
          ),
        if (g != null) Padding(padding: const EdgeInsets.only(top: 4), child: Md('${g['feedback']}', style: const TextStyle(fontSize: 14))),
        if (g == null && widget.onChanged != null && !widget.easy && s.typed.trim().isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(t('Grade my answer with AI')),
              onPressed: () async {
                final res = await busy(context, t('Grading…'), () => gradeAnswer(s));
                if (res == null) return;
                s.aiGrade = res;
                _changed();
              },
            ),
          ),
      ]),
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
              child: Text(t('Misconception: you were sure, but wrong. Read this carefully; the card will come back soon.'),
                  style: TextStyle(color: cs.onErrorContainer))),
        ]),
      ));
    }
    if (s.autoGraded) {
      out.add(Row(children: [
        Icon(s.correct ? Icons.check_circle : Icons.cancel, color: s.correct ? Colors.green : cs.error),
        const SizedBox(width: 8),
        Text(s.correct ? t('Correct') : t('Incorrect'), style: TextStyle(fontSize: 18, color: s.correct ? Colors.green : cs.error)),
      ]));
    }
    if (s.type == 'typed') out.add(Md('**${t('Answer')}:** `${c['answer']}`'));
    if (s.type == 'problem') {
      out.add(Text(t('Solution'), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)));
      final steps = ((c['steps'] as List?) ?? []).cast<String>();
      final shown = widget.easy ? _steps.clamp(0, steps.length) : steps.length;
      for (final (i, step) in steps.take(shown).indexed) {
        out.add(Padding(padding: const EdgeInsets.only(top: 4), child: Md('${i + 1}. $step')));
      }
      if (shown < steps.length) {
        out.add(Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                icon: const Icon(Icons.arrow_downward_rounded),
                label: Text(t('Next step')),
                onPressed: () => setState(() => _steps++))));
        return out; // the answer comes after the last step
      }
      out.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Expanded(child: Md('**${t('Answer')}:** ${c['answer']}')),
            if (c['verified'] == true)
              Tooltip(message: t('Checked by computer algebra'), child: Icon(Icons.verified, size: 18, color: Colors.green.shade400)),
          ])));
    }
    if (s.type == 'short') out.add(Md('**${t('Model answer')}:**\n\n${c['answer']}'));
    if (s.written) out.add(_grading(cs));
    if (s.type == 'ordering') {
      out.add(Md('**${t('Correct order:')}**\n\n${[for (final (i, it) in (c['items'] as List).indexed) '${i + 1}. $it'].join('\n')}'));
    }
    if (!const {'typed', 'cloze', 'short', 'problem'}.contains(s.type) && (c['answer'] ?? '').toString().isNotEmpty) out.add(Md(c['answer']));
    if ((c['answer_code'] ?? '').toString().isNotEmpty) out.add(CodeView(c['answer_code'], language: c['language']));
    out.add(images(c['answer_images']));
    if (widget.showExplanation && (c['explanation'] ?? '').toString().isNotEmpty) {
      out.add(Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: widget.misconception ? cs.errorContainer.withOpacity(.35) : cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Explanation'), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Md(c['explanation']),
        ]),
      ));
    }
    if (c['ref'] is Map && c['ref']['material_id'] != null) out.add(SourceChip(c['ref'] as Map));
    final help = c['leech_help'];
    if (widget.showExplanation && help is Map && (help['explanation'] ?? '').toString().isNotEmpty) {
      out.add(Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: cs.tertiaryContainer.withOpacity(.4), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Another way to see it'), style: TextStyle(color: cs.tertiary, fontWeight: FontWeight.bold)),
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
          title: Text(t(message)),
          trailing: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      );
}

/// Runs [f] with a modal spinner; returns its result or null after showing the error.
Future<T?> busy<T>(BuildContext context, String label, Future<T> Function() f) async {
  FocusManager.instance.primaryFocus?.unfocus(); // else the keyboard returns over the result when the dialog closes
  BuildContext? dialog;
  showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        dialog = c;
        return PopScope(
            canPop: false,
            child: AlertDialog(content: Row(children: [const CircularProgressIndicator(), const SizedBox(width: 16), Expanded(child: Text(label))])));
      });
  try {
    return await f();
  } on ApiError catch (e) {
    if (context.mounted) toast(context, t(e.message));
    return null;
  } catch (e) {
    if (context.mounted) toast(context, 'Failed: $e');
    return null;
  } finally {
    // Closed through its own context: the screen that opened it may be gone by now (an account switch or a
    // language change rebuilds every screen).
    if (dialog?.mounted == true) Navigator.of(dialog!).pop();
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
                  Text(t('Offline: studying works, AI features need a connection'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)))
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


/// Sends a written answer to college/grade (text only: photos of handwritten work were removed, too costly for
/// what they added).
Future<Json> gradeAnswer(AnswerState s) {
  final card = Map<String, dynamic>.from(s.card)..remove('fsrs');
  return Api.ai('college/grade', {'card': card, 'answer': s.typed});
}

/// "Lecture 2, p. 14": where a card comes from; tap to see that page of the student's material.
class SourceChip extends StatelessWidget {
  final Map ref;
  const SourceChip(this.ref, {super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<Json?>(
        future: Db.get(ref['material_id']),
        builder: (context, snap) {
          final title = snap.data?['title'] ?? t('Your material');
          final loc = ref['loc'];
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: ActionChip(
              avatar: const Icon(Icons.description_outlined, size: 18),
              label: Text(loc == null ? iso(title) : '${iso(title)}، ${t('p.')} $loc'.replaceAll('،', App.lang == 'ar' ? '،' : ','),
                  overflow: TextOverflow.ellipsis),
              onPressed: loc is! int ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => SourcePage(ref['material_id'], loc, title))),
            ),
          );
        },
      );
}

/// One page of the student's uploaded material, rendered by the server (cached on the phone after the first view).
class SourcePage extends StatelessWidget {
  final String materialId, title;
  final int page;
  const SourcePage(this.materialId, this.page, this.title, {super.key});

  Future<File> _load() async {
    final f = File('${Db.mediaDir}/page-$materialId-$page.png');
    if (!await f.exists()) await f.writeAsBytes(await Api.call('GET', 'college/page/$materialId/$page') as List<int>, flush: true);
    return f;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('$title · ${t('p.')} $page')),
        body: FutureBuilder<File>(
          future: _load(),
          builder: (context, snap) => snap.hasData
              ? InteractiveViewer(maxScale: 5, child: Center(child: Image.file(snap.data!)))
              : Center(child: snap.hasError ? NeedsConnection('${snap.error}') : const CircularProgressIndicator()),
        ),
      );
}


/// "Report a mistake" on any question, or on an AI answer ([ai] = its text): the note goes to the admin's list; the
/// student gets a notice once it's fixed.
Future<void> reportMistake(BuildContext context, Json card, {String? ai}) async {
  final note = TextEditingController();
  final send = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(ai == null ? t('Report a mistake') : t('Report this answer')),
      content: TextField(controller: note, maxLines: 3, decoration: InputDecoration(hintText: t('What is wrong? (optional)'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Send'))),
      ],
    ),
  );
  if (send != true || !context.mounted) return;
  final ok = await busy(context, t('Sending…'), () => Api.call('POST', 'report', body: {
        'card_id': card['id'],
        'kind': ai == null ? 'question' : 'ai',
        'note': [note.text.trim(), if (ai != null) 'AI: ${ai.length > 500 ? ai.substring(0, 500) : ai}'].where((x) => x.isNotEmpty).join('\n'),
      }));
  if (ok != null && context.mounted) toast(context, t('Thanks! We will check it.'));
}
