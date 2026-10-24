import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'ai.dart';
import 'api.dart';
import 'college_logic.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'widgets.dart';

/// Card text for one-line lists: cloze blanks show their answer, LaTeX becomes readable symbols, Markdown marks go.
String plain(String? s) {
  final text = (s ?? '').replaceAllMapped(RegExp(r'\{\{(.+?)(?:::.+?)?\}\}'), (m) => m[1]!);
  final out = text.replaceAllMapped(RegExp(r'\$\$([\s\S]+?)\$\$|\$([^$]+?)\$'), (m) => texToText(m[1] ?? m[2]!));
  return out.replaceAll(RegExp(r'[*`#>]|(?<!\w)_|_(?!\w)'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

const _tex = {
  'int': '∫', 'sum': 'Σ', 'prod': 'Π', 'sqrt': '√', 'pi': 'π', 'theta': 'θ', 'alpha': 'α', 'beta': 'β', 'gamma': 'γ',
  'delta': 'δ', 'Delta': 'Δ', 'lambda': 'λ', 'mu': 'μ', 'sigma': 'σ', 'omega': 'ω', 'phi': 'φ', 'epsilon': 'ε', 'infty': '∞',
  'cdot': '·', 'times': '×', 'div': '÷', 'pm': '±', 'le': '≤', 'leq': '≤', 'ge': '≥', 'geq': '≥', 'ne': '≠', 'neq': '≠',
  'to': '→', 'rightarrow': '→', 'Rightarrow': '⇒', 'iff': '⇔', 'approx': '≈', 'in': '∈', 'forall': '∀', 'exists': '∃',
  'neg': '¬', 'land': '∧', 'lor': '∨', 'cup': '∪', 'cap': '∩', 'subseteq': '⊆', 'emptyset': '∅', 'partial': '∂',
};
const _sup = {
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹', '+': '⁺', '-': '⁻', '=': '⁼', '(': '⁽',
  ')': '⁾', 'a': 'ᵃ', 'b': 'ᵇ', 'c': 'ᶜ', 'd': 'ᵈ', 'e': 'ᵉ', 'f': 'ᶠ', 'g': 'ᵍ', 'h': 'ʰ', 'i': 'ⁱ', 'j': 'ʲ', 'k': 'ᵏ', 'l': 'ˡ', 'm': 'ᵐ',
  'n': 'ⁿ', 'o': 'ᵒ', 'p': 'ᵖ', 'r': 'ʳ', 's': 'ˢ', 't': 'ᵗ', 'u': 'ᵘ', 'v': 'ᵛ', 'w': 'ʷ', 'x': 'ˣ', 'y': 'ʸ', 'z': 'ᶻ',
};
const _sub = {'0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉', '+': '₊', '-': '₋', 'n': 'ₙ', 'i': 'ᵢ', 'k': 'ₖ'};

/// Superscript/subscript characters when every character has one, else ^(…) / _(…).
String _script(String s, Map<String, String> map, String mark) =>
    s.split('').every(map.containsKey) ? s.split('').map((c) => map[c]).join() : '$mark($s)';

/// A rough plain-text rendering of LaTeX for titles (the card itself renders the real formula).
String texToText(String tex) {
  var t = tex.replaceAll(RegExp(r'\\[,;!: ]'), ' ');
  // Symbols first (before fractions merge \int with the letters after it), keeping \frac and \sqrt for below.
  t = t.replaceAllMapped(RegExp(r'\\([A-Za-z]+)'), (m) => const {'frac', 'dfrac', 'tfrac', 'sqrt'}.contains(m[1])
      ? m[0]!
      : _tex[m[1]] ?? (const {'left', 'right', 'displaystyle', 'mathrm', 'text', 'operatorname', 'quad'}.contains(m[1]) ? '' : m[1]!));
  t = t.replaceAllMapped(RegExp(r'\^\{([^{}]*)\}|\^([A-Za-z0-9])'), (m) => _script(m[1] ?? m[2]!, _sup, '^'));
  t = t.replaceAllMapped(RegExp(r'_\{([^{}]*)\}|_([A-Za-z0-9])'), (m) => _script(m[1] ?? m[2]!, _sub, '_'));
  for (var i = 0; i < 3; i++) {
    t = t.replaceAllMapped(RegExp(r'\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}'), (m) => '${_group(m[1]!)}/${_group(m[2]!)}');
    t = t.replaceAllMapped(RegExp(r'\\sqrt\{([^{}]*)\}'), (m) => '√${_group(m[1]!)}');
  }
  return t.replaceAll(RegExp(r'[{}]'), '');
}

String _group(String s) => RegExp(r'^[^\s+\-*/=]+$').hasMatch(s) ? s : '($s)';

/// Text that takes its direction from its own content (English in an Arabic UI, and the other way round).
Widget autoText(String s, {TextStyle? style, int? maxLines, TextOverflow? overflow}) =>
    Text(s, style: style, maxLines: maxLines, overflow: overflow, textDirection: isRtl(s) ? TextDirection.rtl : TextDirection.ltr);

String dueLabel(Json c) {
  if (isNew(c)) return t('new');
  final days = (dueOf(c) - nowMs()) / dayMs;
  if (days <= 0) return t('due');
  return days < 1 ? t('due in {n}h', {'n': (days * 24).ceil()}) : t('due in {n}d', {'n': days.round()});
}

class CardsScreen extends StatefulWidget {
  final String filter;
  /// Show only this course's cards (college); null = the cert/course picker decides.
  final String? course;
  /// Owner: preselect a cert id ('any' = all cards), a tag chip, or a search text.
  final String? cert, tag;
  final String query;
  const CardsScreen({super.key, this.filter = 'all', this.course, this.cert, this.tag, this.query = ''});
  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  late String filter = widget.filter;
  // 'active' = the active cert; 'any' = everything; a cert code; or 'course:<id>'. Students only have courses.
  late String cert = widget.course != null ? 'course:${widget.course}' : (widget.cert ?? (App.isOwner ? 'active' : 'any'));
  late String q = widget.query;
  late String? tag = widget.tag;
  List<Json> courseList = [];
  late final _qc = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _qc.dispose();
    super.dispose();
  }

  static const filters = {
    'all': 'All',
    'due': 'Due',
    'new': 'New',
    'worked': 'Worked problems',
    'leech': 'Leeches',
    'misconception': 'Misconceptions',
    'suspended': 'Suspended',
  };

  @override
  void initState() {
    super.initState();
    if (!App.isOwner) courses().then((l) => mounted ? setState(() => courseList = l) : null);
  }

  bool _match(Json c, {bool certOnly = false}) {
    if (App.isOwner && c['course'] != null) return false; // owner has no college cards
    if (cert.startsWith('course:')) {
      if (c['course'] != cert.substring(7)) return false;
    } else {
      final certId = cert == 'active' ? App.cert['id'] : cert;
      if (certId != 'any' && !((c['certs'] as Map?) ?? {}).containsKey(certId)) return false;
    }
    if (certOnly) return true;
    final ok = switch (filter) {
      'worked' => c['worked'] == true || c['similar_kp'] != null,
      'due' => !isNew(c) && dueOf(c) <= nowMs() && !isSuspended(c),
      'new' => isNew(c),
      'leech' => c['leech'] == true,
      'misconception' => c['misconception'] == true,
      'suspended' => isSuspended(c),
      _ => true,
    };
    if (!ok) return false;
    if (tag != null && !((c['tags'] as List?) ?? []).contains(tag)) return false;
    if (q.isEmpty) return true;
    final hay = '${c['question']} ${c['answer']} ${(c['tags'] as List?)?.join(' ')} ${(c['options'] as List?)?.join(' ')}'.toLowerCase();
    return hay.contains(q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _qc,
          decoration: InputDecoration(hintText: t('Search cards'), border: InputBorder.none, prefixIcon: const Icon(Icons.search)),
          onChanged: (v) => setState(() => q = v),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(App.isOwner ? Icons.verified_outlined : Icons.filter_list),
            tooltip: t(App.isOwner ? 'Cert' : 'Course'),
            onSelected: (v) => setState(() => cert = v),
            itemBuilder: (_) => [
              if (App.isOwner) CheckedPopupMenuItem(value: 'active', checked: cert == 'active', child: const Text('Active cert')),
              CheckedPopupMenuItem(value: 'any', checked: cert == 'any', child: Text(t('All cards'))),
              if (App.isOwner)
                for (final c in App.certs) CheckedPopupMenuItem(value: c['id'] as String, checked: cert == c['id'], child: Text(c['code'])),
              for (final c in courseList)
                CheckedPopupMenuItem(value: 'course:${c['id']}', checked: cert == 'course:${c['id']}', child: Text(c['name'] ?? '')),
            ],
          ),
        ],
        bottom: App.isOwner ? null : PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              for (final e in filters.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(label: Text(t(e.value)), selected: filter == e.key, onSelected: (_) => setState(() => filter = e.key)),
                ),
            ]),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
          tooltip: t('Add card'),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => CardEditor(course: cert.startsWith('course:') ? cert.substring(7) : (App.isOwner ? null : courseList.firstOrNull?['id'])))),
          child: const Icon(Icons.add)),
      body: Live(
        load: () => Db.query('card', orderBy: 'updated_at DESC'),
        builder: (_, all) {
          final list = all.where(_match).toList();
          final Widget body;
          if (list.isEmpty) {
            body = Center(child: Text(t('No cards here yet.'), textAlign: TextAlign.center));
          } else {
            body = ListView.separated(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: list.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(padding: const EdgeInsets.all(8), child: Text(t('{n} cards', {'n': list.length}), style: const TextStyle(color: Colors.white54)));
                }
                final c = list[i - 1];
                final certJ = App.cert;
                return ListTile(
                  title: autoText(plain(c['question']), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    t(typeLabels[c['type']] ?? c['type']),
                    if (domainOf(c, certJ).isNotEmpty) 'D${domainOf(c, certJ)}',
                    (c['certs'] as Map?)?.keys.join('/') ?? '',
                    isSuspended(c) ? 'suspended' : dueLabel(c),
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (c['misconception'] == true) const Icon(Icons.warning_amber, color: Colors.redAccent, size: 18),
                    if (c['leech'] == true) const Icon(Icons.bug_report_outlined, color: Colors.orange, size: 18),
                  ]),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus(); // else the search keyboard pops back on return
                    Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(c['id'])));
                  },
                );
            },
            );
          }
          return App.isOwner ? Column(children: [_chips(all), Expanded(child: body)]) : body;
        },
      ),
    );
  }

  /// Owner: status filters, then the card set's tags (most used first), as one scrolling row.
  Widget _chips(List<Json> all) {
    final n = <String, int>{};
    for (final c in all.where((c) => _match(c, certOnly: true))) {
      for (final g in ((c['tags'] as List?) ?? []).cast<String>()) {
        n[g] = (n[g] ?? 0) + 1;
      }
    }
    final tags = n.keys.toList()..sort((a, b) => n[b]!.compareTo(n[a]!));
    if (tag != null && !tags.contains(tag)) tags.insert(0, tag!);
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
        for (final e in filters.entries)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: FilterChip(label: Text(t(e.value)), selected: filter == e.key, onSelected: (_) => setState(() => filter = e.key))),
        for (final g in tags)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: FilterChip(label: Text(g), selected: tag == g, onSelected: (v) => setState(() => tag = v ? g : null))),
      ]),
    );
  }
}

class CardDetail extends StatefulWidget {
  final String id;
  const CardDetail(this.id, {super.key});
  @override
  State<CardDetail> createState() => _CardDetailState();
}

class _CardDetailState extends State<CardDetail> {
  Future<(Json?, List<Json>, List<Json>, List<Json>)> _load() async {
    final c = await Db.get(widget.id);
    final reviews = await Db.reviewsFor(widget.id);
    final overrides = (await Db.query('override')).where((o) => ((o['card_ids'] as List?) ?? []).contains(widget.id)).toList();
    final variants = (await Db.query('card')).where((v) => v['variant_of'] == widget.id).toList();
    return (c, reviews, overrides, variants);
  }

  Future<void> _variants(Json c, {required bool leech}) async {
    final res = await busy(context, leech ? 'Asking the AI for help with this leech…' : 'Generating variants…',
        () => Api.ai('ai/variants', {'card': c, 'count': 2, 'leech': leech}));
    if (res == null) return;
    final vs = ((res['variants'] as List?) ?? []).cast<Map>().map((v) => Map<String, dynamic>.from(v)).toList();
    await Db.putAll('card', vs, dirty: false); // already stored server-side
    if (leech) {
      c['leech_help'] = {'explanation': res['explanation'], 'learn': res['learn'], 'videos': res['videos'] ?? []};
      await Db.put('card', c);
    }
    if (mounted) toast(context, 'Added ${vs.length} variant card(s)');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Live(
      load: _load,
      builder: (context, data) {
        final (c, reviews, overrides, variants) = data;
        if (c == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(t('Card deleted'))));
        final preview = AnswerState(c)..selected.addAll(((c['correct'] as List?) ?? []).cast<int>());
        preview.order = [...((c['items'] as List?) ?? []).cast<String>()];
        preview.typed = c['answer']?.toString() ?? '';
        final s = schedulerFor(App.cert);
        final help = c['leech_help'];
        return Scaffold(
          appBar: AppBar(title: Text(t(typeLabels[c['type']] ?? 'Card')), actions: [
            IconButton(
                icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardEditor(card: c)))),
            IconButton(
                icon: const Icon(Icons.forum_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(c)))),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'suspend':
                    await Db.put('card', c..['suspended'] = !isSuspended(c));
                  case 'clear':
                    await Db.put(
                        'card',
                        c
                          ..['misconception'] = false
                          ..['leech'] = false);
                  case 'variants':
                    await _variants(c, leech: false);
                  case 'delete':
                    final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(title: Text(t('Delete this card?')), actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Delete'))),
                            ]));
                    if (ok == true) {
                      await Db.put('card', c, deleted: true);
                      if (context.mounted) Navigator.pop(context);
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'suspend', child: Text(isSuspended(c) ? t('Unsuspend') : t('Suspend'))),
                PopupMenuItem(value: 'variants', child: Text(t('AI: make variant questions'))),
                if (c['misconception'] == true || c['leech'] == true)
                  PopupMenuItem(value: 'clear', child: Text(t('Clear leech/misconception flags'))),
                PopupMenuItem(value: 'delete', child: Text(t('Delete'))),
              ],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            CardView(preview, revealed: true),
            const Divider(height: 32),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in ((c['certs'] as Map?) ?? {}).entries) Chip(label: Text('${e.key} · D${e.value}')),
              if (isSuspended(c)) Chip(label: Text(t('Suspended'))),
              if (c['leech'] == true) Chip(label: Text(t('Leech')), avatar: const Icon(Icons.bug_report_outlined, color: Colors.orange)),
              if (c['misconception'] == true) Chip(label: Text(t('Misconception')), avatar: const Icon(Icons.warning_amber, color: Colors.redAccent)),
            ]),
            const SizedBox(height: 8),
            Text(
                [
                  dueLabel(c),
                  if (!isNew(c)) t('recall now {p}%', {'p': (100 * retrievability(s, c)).round()}),
                  if (c['fsrs']?['stability'] != null) t('stability {d} days', {'d': (c['fsrs']['stability'] as num).toStringAsFixed(1)}),
                  t('lapses {n}', {'n': c['lapses'] ?? 0}),
                  if ((c['priority'] ?? 0) != 0) 'priority ${c['priority']}',
                  if (App.isOwner) 'source: ${c['source'] ?? 'manual'}',
                ].join(' · '),
                style: const TextStyle(color: Colors.white60)),
            if (c['leech'] == true) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                  onPressed: () => _variants(c, leech: true),
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(t('AI leech help: new explanation + variants'))),
            ],
            if (help is Map) ...[
              const SizedBox(height: 12),
              if ((help['learn'] ?? '').toString().isNotEmpty)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t('Learn it'), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                          Md(help['learn']),
                        ]))),
              for (final v in ((help['videos'] as List?) ?? []).cast<Map>())
                ListTile(leading: const Icon(Icons.play_circle_outline), title: Text(v['title'] ?? ''), onTap: () => openUrl(v['url'])),
            ],
            if (variants.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(t('Variants'), style: TextStyle(color: cs.primary)),
              for (final v in variants)
                ListTile(
                    dense: true,
                    title: autoText(plain(v['question']), maxLines: 2),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(v['id'])))),
            ],
            const SizedBox(height: 16),
            Text(t('History'), style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
            for (final o in overrides)
              Card(
                color: cs.secondaryContainer.withOpacity(.4),
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text('AI override: ${_describe(o)}'),
                  subtitle: Text('${o['reason']}\n${_when(o['applied_at'])}${o['reverted_at'] != null ? ' · reverted' : ''}'),
                  isThreeLine: true,
                  trailing: o['applied_at'] != null && o['reverted_at'] == null
                      ? TextButton(onPressed: () => revertOverride(o), child: const Text('Revert'))
                      : null,
                ),
              ),
            if (reviews.isEmpty) Text(t('Not reviewed yet'), style: const TextStyle(color: Colors.white54)),
            for (final r in reviews)
              ListTile(
                dense: true,
                leading: Icon(r['correct'] == true ? Icons.check : Icons.close, color: r['correct'] == true ? Colors.green : cs.error),
                title: Text('${_when(r['ts'])} · ${t(const ['', 'Again', 'Hard', 'Good', 'Easy'][r['rating'] as int])}${r['score'] != null && (r['score'] as num) < 1 ? ' · ${((r['score'] as num) * 100).round()}%' : ''}'),
                subtitle: Text('${t(const {'guess': 'Guessing', 'unsure': 'Unsure', 'sure': 'Sure'}[r['confidence']] ?? '${r['confidence']}')}${r['misconception'] == true ? ' · ${t('Misconception')}' : ''} · ${t(const {'study': 'Study', 'exam': 'Practice exam', 'cram': 'Review'}[r['source']] ?? '${r['source']}')}'),
              ),
          ]),
        );
      },
    );
  }
}

String _when(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms).toString().substring(0, 16) : 'pending';

String _describe(Json o) => [
      if (o['due_now'] == true) 'review now',
      if (o['due_shift_days'] != null) '${(o['due_shift_days'] as int) > 0 ? 'postpone' : 'bring forward'} ${(o['due_shift_days'] as int).abs()}d',
      if (o['priority'] != null) 'priority ${o['priority']}',
    ].join(', ');

// ---------------- editor ----------------

Future<String?> pickImage(BuildContext context) async {
  final src = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.photo), title: const Text('Gallery'), onTap: () => Navigator.pop(context, 'gallery')),
            ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Camera'), onTap: () => Navigator.pop(context, 'camera')),
            ListTile(leading: const Icon(Icons.link), title: const Text('From URL'), onTap: () => Navigator.pop(context, 'url')),
          ])));
  if (src == null || !context.mounted) return null;
  if (src == 'url') {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Image URL'),
              content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.url),
              actions: [FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: const Text('Add'))],
            ));
    if (url == null || url.isEmpty) return null;
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      final type = r.headers['content-type'] ?? '';
      if (r.statusCode != 200 || !type.startsWith('image/')) throw Exception('not an image (${r.statusCode} $type)');
      return await Db.saveMedia(r.bodyBytes);
    } catch (e) {
      if (context.mounted) toast(context, 'Could not download image: $e');
      return null;
    }
  }
  final x = await ImagePicker().pickImage(source: src == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
  if (x == null) return null;
  try {
    return await Db.saveMedia(await x.readAsBytes());
  } on FormatException catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  }
}

class CardEditor extends StatefulWidget {
  final Json? card;
  /// New college card for this course (no cert tags).
  final String? course;
  const CardEditor({super.key, this.card, this.course});
  @override
  State<CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<CardEditor> {
  late final Json d = widget.card == null
      ? {
          'type': 'basic',
          if (widget.course == null) 'certs': {App.cert['id']: ''},
          if (widget.course != null) 'course': widget.course,
          'source': 'manual',
          'created_at': nowMs()
        }
      : Map<String, dynamic>.from(widget.card!);
  bool get courseCard => d['course'] != null;
  final _ctl = <String, TextEditingController>{};
  late List<TextEditingController> options = [
    for (final o in ((d['options'] as List?) ?? ['', '', '', ''])) TextEditingController(text: o.toString())
  ];
  late List<TextEditingController> optionExpl = [
    for (var i = 0; i < options.length; i++)
      TextEditingController(text: (((d['option_explanations'] as List?) ?? []).elementAtOrNull(i) ?? '').toString())
  ];
  late Set<int> correct = ((d['correct'] as List?) ?? []).cast<int>().toSet();
  late List<TextEditingController> items = [
    for (final o in ((d['items'] as List?) ?? ['', '', ''])) TextEditingController(text: o.toString())
  ];
  late Map<String, String> certs = {for (final e in ((d['certs'] as Map?) ?? {}).entries) e.key.toString(): e.value.toString()};
  late List<Map> masks = [for (final m in ((d['masks'] as List?) ?? [])) Map.from(m)];
  bool perRegion = true;

  TextEditingController ctl(String key, {String? initial}) =>
      _ctl[key] ??= TextEditingController(text: initial ?? (d[key] is List ? (d[key] as List).join(', ') : d[key]?.toString() ?? ''));

  String get type => d['type'];
  bool get isNewCard => widget.card == null;

  Widget field(String key, String label, {int lines = 1, bool mono = false, String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: ctl(key),
          minLines: lines,
          maxLines: lines == 1 ? 1 : 20,
          style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), alignLabelWithHint: true),
        ),
      );

  void _collect() {
    for (final e in _ctl.entries) {
      d[e.key] = e.value.text.trim();
    }
    List<String> csv(String k) => (d[k] as String? ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    d['tags'] = csv('tags');
    if (type == 'typed') d['accepted'] = csv('accepted');
    if (type == 'mcq') {
      final keep = [
        for (var i = 0; i < options.length; i++)
          if (options[i].text.trim().isNotEmpty) i
      ];
      d['options'] = [for (final i in keep) options[i].text.trim()];
      d['option_explanations'] = [for (final i in keep) optionExpl[i].text.trim()];
      d['correct'] = [
        for (var j = 0; j < keep.length; j++)
          if (correct.contains(keep[j])) j
      ];
    }
    if (type == 'ordering') {
      d['items'] = [
        for (final c in items)
          if (c.text.trim().isNotEmpty) c.text.trim()
      ];
    }
    if (type == 'occlusion') d['masks'] = masks;
    List<String> lines(String k) => (d.remove(k) as String? ?? '').split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (type == 'problem') d['steps'] = lines('steps_text');
    if (type == 'short' || type == 'problem') {
      final points = lines('rubric_text');
      d['rubric'] = [for (final p in points) {'point': p, 'weight': 1 / points.length}];
    }
    if (!courseCard) {
      d['certs'] = {
        for (final e in certs.entries)
          if (e.value.isNotEmpty) e.key: e.value
      };
    }
  }

  String? _validate() {
    final question = (d['question'] ?? '').toString();
    if (question.isEmpty && type != 'occlusion') return t('Question is required');
    if (!courseCard && (d['certs'] as Map).isEmpty) return 'Tag at least one certification domain';
    return switch (type) {
      'short' || 'problem' when (d['answer'] ?? '').toString().isEmpty => t('Answer is required'),
      'problem' when (d['steps'] as List).isEmpty => t('Add the solution steps'),
      'mcq' when (d['options'] as List).length < 2 => 'Add at least 2 options',
      'mcq' when (d['correct'] as List).isEmpty => 'Mark the correct option(s)',
      'typed' when (d['answer'] ?? '').toString().isEmpty => 'Answer is required',
      'cloze' when !question.contains('{{') => 'Wrap at least one answer in {{double braces}}',
      'ordering' when (d['items'] as List).length < 2 => 'Add at least 2 steps',
      'code' when '${d['code']}${d['answer_code']}'.isEmpty => 'Add a code snippet',
      'occlusion' when d['image'] == null || masks.isEmpty => 'Pick an image and draw at least one region',
      'basic' when (d['answer'] ?? '').toString().isEmpty => 'Answer is required',
      _ => null,
    };
  }

  Future<void> _save() async {
    _collect();
    final err = _validate();
    if (err != null) return toast(context, err);
    if (type == 'occlusion' && (d['question'] ?? '').toString().isEmpty) d['question'] = 'What is hidden?';
    if (type == 'occlusion' && isNewCard && perRegion && masks.length > 1) {
      await Db.putAll('card', [
        for (var i = 0; i < masks.length; i++) {...d, 'id': uuid.v4(), 'target': i, 'answer': masks[i]['label'] ?? ''}
      ]);
    } else {
      if (type == 'occlusion') d['target'] ??= masks.length == 1 ? 0 : null;
      await Db.put('card', d);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _aiFill() async {
    _collect();
    final res = await busy(context, 'Writing the explanation…', () => Api.ai('ai/explain', {'card': d, 'messages': [], 'mode': 'fill'}));
    if (res == null) return;
    setState(() {
      ctl('explanation').text = res['explanation'] ?? '';
      final ex = ((res['option_explanations'] as List?) ?? []).cast<String>();
      for (var i = 0; i < optionExpl.length && i < ex.length; i++) {
        optionExpl[i].text = ex[i];
      }
    });
  }

  void _wrapCloze() {
    final c = ctl('question');
    final sel = c.selection;
    if (!sel.isValid || sel.isCollapsed) return toast(context, 'Select the text to hide first');
    final t = c.text;
    c.text = '${t.substring(0, sel.start)}{{${t.substring(sel.start, sel.end)}}}${t.substring(sel.end)}';
  }

  Widget _imageList(String key, String label) {
    final list = ((d[key] as List?) ?? []).cast<String>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final n in list)
          Stack(children: [
            SizedBox(
                width: 80,
                height: 80,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: MediaImage(n, fill: false)))),
            Positioned(
                right: -8,
                top: -8,
                child: IconButton(icon: const Icon(Icons.cancel, size: 20), onPressed: () => setState(() => d[key] = [...list]..remove(n)))),
          ]),
        OutlinedButton.icon(
            onPressed: () async {
              final n = await pickImage(context);
              if (n != null) setState(() => d[key] = [...list, n]);
            },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(label)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(isNewCard ? 'New card' : 'Edit card'), actions: [
        TextButton(onPressed: _save, child: const Text('Save')),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (isNewCard)
          DropdownButtonFormField<String>(
            value: type,
            decoration: const InputDecoration(labelText: 'Card type', border: OutlineInputBorder()),
            items: [for (final e in typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => d['type'] = v),
          ),
        if (type == 'occlusion') ..._occlusion(cs),
        field(
            'question',
            switch (type) {
              'cloze' => 'Text with {{blanks}} (use {{answer::hint}} for a hint)',
              'mcq' => 'Question / scenario',
              'occlusion' => 'Caption (optional)',
              'ordering' => 'What to order',
              _ => 'Question',
            },
            lines: 3),
        if (type == 'cloze')
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _wrapCloze, icon: const Icon(Icons.data_array), label: const Text('Make selection a blank'))),
        _imageList('question_images', 'Question image'),
        if (type == 'code') ...[
          DropdownButtonFormField<String>(
            value: (d['language'] ?? 'yaml') as String,
            decoration: const InputDecoration(labelText: 'Language', border: OutlineInputBorder()),
            items: [
              for (final l in ['yaml', 'json', 'bash', 'python', 'javascript', 'typescript', 'java', 'go', 'dockerfile', 'sql', 'plaintext'])
                DropdownMenuItem(value: l, child: Text(l))
            ],
            onChanged: (v) => d['language'] = v,
          ),
          field('code', 'Code shown with the question (optional)', lines: 5, mono: true),
          field('answer_code', 'Code shown with the answer (optional)', lines: 5, mono: true),
        ],
        if (type == 'mcq') ..._mcq(cs),
        if (type == 'ordering') ..._ordering(),
        if (const {'basic', 'code', 'typed'}.contains(type))
          field('answer', type == 'typed' ? t('Exact answer') : t('Answer'), lines: type == 'typed' ? 1 : 3, mono: type == 'typed'),
        if (type == 'problem') ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TextField(
              controller: ctl('steps_text', initial: ((d['steps'] as List?) ?? []).join('\n')),
              minLines: 3,
              maxLines: 20,
              decoration: InputDecoration(labelText: t('Solution steps (one per line)'), border: const OutlineInputBorder(), alignLabelWithHint: true),
            ),
          ),
          field('answer', t('Final answer'), lines: 1),
        ],
        if (type == 'short') field('answer', t('Model answer'), lines: 3),
        if (type == 'short' || type == 'problem')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TextField(
              controller: ctl('rubric_text', initial: [for (final r in ((d['rubric'] as List?) ?? []).cast<Map>()) r['point']].join('\n')),
              minLines: 2,
              maxLines: 10,
              decoration: InputDecoration(labelText: t('Marking points (one per line)'), border: const OutlineInputBorder(), alignLabelWithHint: true),
            ),
          ),
        if (type == 'typed') field('accepted', 'Other accepted answers (comma separated)'),
        _imageList('answer_images', 'Answer image'),
        Row(children: [
          Expanded(child: Text('Explanation', style: TextStyle(color: cs.primary))),
          TextButton.icon(onPressed: _aiFill, icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('AI fill')),
        ]),
        field('explanation', 'Why the right answer is right, and why the others are wrong', lines: 4),
        field('tags', 'Tags (comma separated)'),
        const SizedBox(height: 8),
        if (!courseCard) Text('Certifications & domains', style: TextStyle(color: cs.primary)),
        if (!courseCard)
          for (final cert in App.certs)
          Row(children: [
            Checkbox(
                value: certs.containsKey(cert['id']),
                onChanged: (v) => setState(() => v == true ? certs[cert['id']] = '' : certs.remove(cert['id']))),
            SizedBox(width: 72, child: Text(cert['code'])),
            if (certs.containsKey(cert['id']))
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: certs[cert['id']]!.isEmpty ? null : certs[cert['id']],
                  hint: const Text('Pick domain'),
                  items: [
                    for (final dm in (cert['domains'] as List))
                      DropdownMenuItem(value: dm['id'] as String, child: Text('${dm['id']}. ${dm['name']}', overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (v) => setState(() => certs[cert['id']] = v!),
                ),
              ),
          ]),
        const SizedBox(height: 40),
      ]),
    );
  }

  List<Widget> _mcq(ColorScheme cs) => [
        const SizedBox(height: 8),
        Text('Options: tick every correct one (more than one = "choose N")', style: TextStyle(color: cs.primary)),
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Checkbox(value: correct.contains(i), onChanged: (v) => setState(() => v == true ? correct.add(i) : correct.remove(i))),
              Expanded(
                child: Column(children: [
                  TextField(controller: options[i], decoration: InputDecoration(labelText: 'Option ${String.fromCharCode(65 + i)}', isDense: true)),
                  TextField(
                      controller: optionExpl[i],
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(hintText: 'Why right / wrong (optional)', isDense: true)),
                ]),
              ),
              IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: options.length <= 2
                      ? null
                      : () => setState(() {
                            options.removeAt(i);
                            optionExpl.removeAt(i);
                            correct = {
                              for (final c in correct)
                                if (c != i) c > i ? c - 1 : c
                            };
                          })),
            ]),
          ),
        TextButton.icon(
            onPressed: () => setState(() {
                  options.add(TextEditingController());
                  optionExpl.add(TextEditingController());
                }),
            icon: const Icon(Icons.add),
            label: const Text('Add option')),
      ];

  List<Widget> _ordering() => [
        const Text('Steps in the correct order (shown shuffled when studying)'),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            items.insert(b, items.removeAt(a));
          }),
          children: [
            for (var i = 0; i < items.length; i++)
              ListTile(
                key: ObjectKey(items[i]),
                leading: Text('${i + 1}.'),
                title: TextField(controller: items[i], decoration: const InputDecoration(isDense: true)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => items.removeAt(i))),
                  const Icon(Icons.drag_handle),
                ]),
              ),
          ],
        ),
        TextButton.icon(
            onPressed: () => setState(() => items.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Add step')),
      ];

  List<Widget> _occlusion(ColorScheme cs) => [
        const SizedBox(height: 12),
        if (d['image'] == null)
          OutlinedButton.icon(
              onPressed: () async {
                final n = await pickImage(context);
                if (n != null) setState(() => d['image'] = n);
              },
              icon: const Icon(Icons.image_outlined),
              label: const Text('Pick image (gallery, camera, URL)'))
        else ...[
          const Text('Drag to cover a region. Tap a region to label or delete it.', style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 6),
          MaskEditor(image: d['image'], masks: masks, onChanged: () => setState(() {})),
          if (isNewCard)
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('One card per region'),
                subtitle: const Text('Off = a single card that hides all regions'),
                value: perRegion,
                onChanged: (v) => setState(() => perRegion = v)),
        ],
      ];
}

class MaskEditor extends StatefulWidget {
  final String image;
  final List<Map> masks;
  final VoidCallback onChanged;
  const MaskEditor({super.key, required this.image, required this.masks, required this.onChanged});
  @override
  State<MaskEditor> createState() => _MaskEditorState();
}

class _MaskEditorState extends State<MaskEditor> {
  Offset? start, cur;

  Map? _draft(Size size) {
    if (start == null || cur == null) return null;
    final a = Offset((start!.dx / size.width).clamp(0, 1), (start!.dy / size.height).clamp(0, 1));
    final b = Offset((cur!.dx / size.width).clamp(0, 1), (cur!.dy / size.height).clamp(0, 1));
    return {'x': a.dx < b.dx ? a.dx : b.dx, 'y': a.dy < b.dy ? a.dy : b.dy, 'w': (a.dx - b.dx).abs(), 'h': (a.dy - b.dy).abs()};
  }

  Future<void> _edit(int i) async {
    final ctl = TextEditingController(text: widget.masks[i]['label']?.toString() ?? '');
    final res = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('Region ${i + 1}'),
              content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Label (the hidden answer)')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, '\u0000delete'), child: const Text('Delete')),
                FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: const Text('OK')),
              ],
            ));
    if (res == null) return;
    if (res == '\u0000delete') {
      widget.masks.removeAt(i);
    } else {
      widget.masks[i]['label'] = res;
    }
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(children: [
          MediaImage(widget.image),
          Positioned.fill(
            child: LayoutBuilder(builder: (context, b) {
              final size = Size(b.maxWidth, b.maxHeight);
              final draft = _draft(size);
              return GestureDetector(
                onPanStart: (e) => setState(() => start = cur = e.localPosition),
                onPanUpdate: (e) => setState(() => cur = e.localPosition),
                onPanEnd: (_) {
                  final m = _draft(size);
                  setState(() => start = cur = null);
                  if (m != null && (m['w'] as double) > .02 && (m['h'] as double) > .02) {
                    widget.masks.add(m);
                    widget.onChanged();
                    _edit(widget.masks.length - 1);
                  }
                },
                onTapUp: (e) {
                  final p = Offset(e.localPosition.dx / size.width, e.localPosition.dy / size.height);
                  for (var i = widget.masks.length - 1; i >= 0; i--) {
                    final m = widget.masks[i];
                    if (Rect.fromLTWH((m['x'] as num).toDouble(), (m['y'] as num).toDouble(), (m['w'] as num).toDouble(), (m['h'] as num).toDouble())
                        .contains(p)) {
                      _edit(i);
                      return;
                    }
                  }
                },
                child:
                    CustomPaint(painter: MaskPainter([...widget.masks, if (draft != null) draft], null, true, Theme.of(context).colorScheme.primary)),
              );
            }),
          ),
        ]),
      );
    });
  }
}
