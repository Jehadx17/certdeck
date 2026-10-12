import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'ai.dart';
import 'api.dart';
import 'db.dart';
import 'logic.dart';
import 'widgets.dart';

String plain(String? s) => (s ?? '').replaceAll(RegExp(r'[*_`#>\[\]]|\{\{|\}\}'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

String dueLabel(Json c) {
  if (isNew(c)) return 'new';
  final days = (dueOf(c) - nowMs()) / dayMs;
  if (days <= 0) return 'due';
  return days < 1 ? 'due in ${(days * 24).ceil()}h' : 'due in ${days.round()}d';
}

class CardsScreen extends StatefulWidget {
  final String filter;
  const CardsScreen({super.key, this.filter = 'all'});
  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  late String filter = widget.filter;
  String cert = 'active';
  String q = '';

  static const filters = {
    'all': 'All',
    'due': 'Due',
    'new': 'New',
    'leech': 'Leeches',
    'misconception': 'Misconceptions',
    'suspended': 'Suspended',
  };

  bool _match(Json c) {
    final certId = cert == 'active' ? App.cert['id'] : cert;
    if (certId != 'any' && !((c['certs'] as Map?) ?? {}).containsKey(certId)) return false;
    final ok = switch (filter) {
      'due' => !isNew(c) && dueOf(c) <= nowMs() && !isSuspended(c),
      'new' => isNew(c),
      'leech' => c['leech'] == true,
      'misconception' => c['misconception'] == true,
      'suspended' => isSuspended(c),
      _ => true,
    };
    if (!ok) return false;
    if (q.isEmpty) return true;
    final hay = '${c['question']} ${c['answer']} ${(c['tags'] as List?)?.join(' ')} ${(c['options'] as List?)?.join(' ')}'.toLowerCase();
    return hay.contains(q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(hintText: 'Search cards', border: InputBorder.none, prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => q = v),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.school_outlined),
            tooltip: 'Certification',
            onSelected: (v) => setState(() => cert = v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'active', checked: cert == 'active', child: const Text('Active cert')),
              CheckedPopupMenuItem(value: 'any', checked: cert == 'any', child: const Text('All certs')),
              for (final c in App.certs) CheckedPopupMenuItem(value: c['id'] as String, checked: cert == c['id'], child: Text(c['code'])),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              for (final e in filters.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(label: Text(e.value), selected: filter == e.key, onSelected: (_) => setState(() => filter = e.key)),
                ),
            ]),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CardEditor())), child: const Icon(Icons.add)),
      body: Live(
        load: () => Db.query('card', orderBy: 'updated_at DESC'),
        builder: (_, all) {
          final list = all.where(_match).toList();
          if (list.isEmpty)
            return const Center(child: Text('No cards here yet.\nTap + to add one, or generate some in the AI tab.', textAlign: TextAlign.center));
          return ListView.separated(
            itemCount: list.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              if (i == 0)
                return Padding(padding: const EdgeInsets.all(8), child: Text('${list.length} cards', style: const TextStyle(color: Colors.white54)));
              final c = list[i - 1];
              final certJ = App.cert;
              return ListTile(
                title: Text(plain(c['question']), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  typeLabels[c['type']] ?? c['type'],
                  if (domainOf(c, certJ).isNotEmpty) 'D${domainOf(c, certJ)}',
                  (c['certs'] as Map?)?.keys.join('/') ?? '',
                  isSuspended(c) ? 'suspended' : dueLabel(c),
                ].join(' · ')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (c['misconception'] == true) const Icon(Icons.warning_amber, color: Colors.redAccent, size: 18),
                  if (c['leech'] == true) const Icon(Icons.bug_report_outlined, color: Colors.orange, size: 18),
                ]),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(c['id']))),
              );
            },
          );
        },
      ),
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
        if (c == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Card deleted')));
        final preview = AnswerState(c)..selected.addAll(((c['correct'] as List?) ?? []).cast<int>());
        preview.order = [...((c['items'] as List?) ?? []).cast<String>()];
        preview.typed = c['answer']?.toString() ?? '';
        final s = schedulerFor(App.cert);
        final help = c['leech_help'];
        return Scaffold(
          appBar: AppBar(title: Text(typeLabels[c['type']] ?? 'Card'), actions: [
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
                        builder: (_) => AlertDialog(title: const Text('Delete this card?'), actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                            ]));
                    if (ok == true) {
                      await Db.put('card', c, deleted: true);
                      if (context.mounted) Navigator.pop(context);
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'suspend', child: Text(isSuspended(c) ? 'Unsuspend' : 'Suspend')),
                const PopupMenuItem(value: 'variants', child: Text('AI: make variant questions')),
                if (c['misconception'] == true || c['leech'] == true)
                  const PopupMenuItem(value: 'clear', child: Text('Clear leech/misconception flags')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            CardView(preview, revealed: true),
            const Divider(height: 32),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in ((c['certs'] as Map?) ?? {}).entries) Chip(label: Text('${e.key} · D${e.value}')),
              for (final t in ((c['tags'] as List?) ?? [])) Chip(label: Text('#$t')),
              if (isSuspended(c)) const Chip(label: Text('Suspended')),
              if (c['leech'] == true) const Chip(label: Text('Leech'), avatar: Icon(Icons.bug_report_outlined, color: Colors.orange)),
              if (c['misconception'] == true) const Chip(label: Text('Misconception'), avatar: Icon(Icons.warning_amber, color: Colors.redAccent)),
            ]),
            const SizedBox(height: 8),
            Text(
                [
                  dueLabel(c),
                  if (!isNew(c)) 'recall now ${(100 * retrievability(s, c)).round()}%',
                  if (c['fsrs']?['stability'] != null) 'stability ${(c['fsrs']['stability'] as num).toStringAsFixed(1)}d',
                  'lapses ${c['lapses'] ?? 0}',
                  if ((c['priority'] ?? 0) != 0) 'priority ${c['priority']}',
                  'source: ${c['source'] ?? 'manual'}',
                ].join(' · '),
                style: const TextStyle(color: Colors.white60)),
            if (c['leech'] == true) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                  onPressed: () => _variants(c, leech: true),
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('AI leech help: new explanation + variants')),
            ],
            if (help is Map) ...[
              const SizedBox(height: 12),
              if ((help['learn'] ?? '').toString().isNotEmpty)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Learn it', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                          Md(help['learn']),
                        ]))),
              for (final v in ((help['videos'] as List?) ?? []).cast<Map>())
                ListTile(leading: const Icon(Icons.play_circle_outline), title: Text(v['title'] ?? ''), onTap: () => openUrl(v['url'])),
            ],
            if (variants.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Variants', style: TextStyle(color: cs.primary)),
              for (final v in variants)
                ListTile(
                    dense: true,
                    title: Text(plain(v['question']), maxLines: 2),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(v['id'])))),
            ],
            const SizedBox(height: 16),
            Text('History', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
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
            if (reviews.isEmpty) const Text('Not reviewed yet', style: TextStyle(color: Colors.white54)),
            for (final r in reviews)
              ListTile(
                dense: true,
                leading: Icon(r['correct'] == true ? Icons.check : Icons.close, color: r['correct'] == true ? Colors.green : cs.error),
                title: Text('${_when(r['ts'])} · ${const ['', 'Again', 'Hard', 'Good', 'Easy'][r['rating'] as int]}'),
                subtitle: Text('${r['confidence']}${r['misconception'] == true ? ' · misconception' : ''} · ${r['source']}'),
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
      return Db.saveMedia(r.bodyBytes, type.split('/').last.split(';').first.replaceAll('svg+xml', 'svg'));
    } catch (e) {
      if (context.mounted) toast(context, 'Could not download image: $e');
      return null;
    }
  }
  final x = await ImagePicker().pickImage(source: src == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
  if (x == null) return null;
  return Db.saveMedia(await x.readAsBytes(), x.path.split('.').last);
}

class CardEditor extends StatefulWidget {
  final Json? card;
  const CardEditor({super.key, this.card});
  @override
  State<CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<CardEditor> {
  late final Json d = widget.card == null
      ? {
          'type': 'basic',
          'certs': {App.cert['id']: ''},
          'source': 'manual',
          'created_at': nowMs()
        }
      : Map<String, dynamic>.from(widget.card!);
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
    if (type == 'ordering')
      d['items'] = [
        for (final c in items)
          if (c.text.trim().isNotEmpty) c.text.trim()
      ];
    if (type == 'occlusion') d['masks'] = masks;
    d['certs'] = {
      for (final e in certs.entries)
        if (e.value.isNotEmpty) e.key: e.value
    };
  }

  String? _validate() {
    final question = (d['question'] ?? '').toString();
    if (question.isEmpty && type != 'occlusion') return 'Question is required';
    if ((d['certs'] as Map).isEmpty) return 'Tag at least one certification domain';
    return switch (type) {
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
                    borderRadius: BorderRadius.circular(6), child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: MediaImage(n)))),
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
          field('answer', type == 'typed' ? 'Exact answer (e.g. aws sts assume-role)' : 'Answer',
              lines: type == 'typed' ? 1 : 3, mono: type == 'typed'),
        if (type == 'typed') field('accepted', 'Other accepted answers (comma separated)'),
        _imageList('answer_images', 'Answer image'),
        Row(children: [
          Expanded(child: Text('Explanation', style: TextStyle(color: cs.primary))),
          TextButton.icon(onPressed: _aiFill, icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('AI fill')),
        ]),
        field('explanation', 'Why the right answer is right, and why the others are wrong', lines: 4),
        field('tags', 'Tags (comma separated)'),
        const SizedBox(height: 8),
        Text('Certifications & domains', style: TextStyle(color: cs.primary)),
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
