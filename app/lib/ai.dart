import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'cards.dart';
import 'db.dart';
import 'logic.dart';
import 'widgets.dart';

/// Calls ai/generate, stores the cards locally and applies the suggested retags.
/// Returns a human summary, or throws ApiError.
Future<(String, List<Json>)> generateCards(Json body) async {
  final res = await Api.ai('ai/generate', body);
  final cards = ((res['cards'] as List?) ?? []).map((c) => Map<String, dynamic>.from(c as Map)).toList();
  await Db.putAll('card', cards, dirty: false); // the server already has them
  final retagged = await applyRetags(res['retag'] as List?);
  final dup = res['skipped_duplicates'] ?? 0;
  String n(int k, String w) => '$k $w${k == 1 ? '' : 's'}';
  return (
    'Added ${n(cards.length, 'card')}${retagged > 0 ? ', tagged ${n(retagged, 'existing card')} for this cert' : ''}${dup > 0 ? ', skipped ${n(dup as int, 'duplicate')}' : ''}',
    cards
  );
}

/// Background generation via the Batch API: 50% cheaper, cards arrive on a later sync (usually minutes).
Future<String> queueCards(Json body) async {
  final res = await Api.ai('ai/generate', {...body, 'background': true});
  await Db.putAll('job', [Map<String, dynamic>.from(res['job'] as Map)], dirty: false);
  return 'Queued ${body['count'] ?? 20} cards in the background (50% cheaper). They arrive within minutes, on the next sync.';
}

bool get backgroundGenerate => App.settings['background_generate'] != false;

class AiScreen extends StatelessWidget {
  const AiScreen({super.key});
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(title: const Text('AI'), bottom: const TabBar(tabs: [Tab(text: 'Generate cards'), Tab(text: 'Weak areas')])),
          body: const Column(children: [
            OnlineBanner(),
            Expanded(child: TabBarView(children: [GenerateTab(), InsightsTab()]))
          ]),
        ),
      );
}

class GenerateTab extends StatefulWidget {
  final String? domain, topic;
  final int count;
  const GenerateTab({super.key, this.domain, this.topic, this.count = 20});
  @override
  State<GenerateTab> createState() => _GenerateTabState();
}

class _GenerateTabState extends State<GenerateTab> with AutomaticKeepAliveClientMixin {
  late String cert = App.cert['id'];
  late String? domain = widget.domain;
  late final topic = TextEditingController(text: widget.topic);
  final text = TextEditingController();
  late final count = TextEditingController(text: '${widget.count}');
  final files = <PlatformFile>[];
  final types = <String>{};
  bool examStyle = false;
  String? result, error;
  List<Json> made = [];

  @override
  bool get wantKeepAlive => true;

  // Follow the active cert when it changes in Settings.
  late String _active = App.cert['id'];
  void _onChange() {
    if (App.cert['id'] != _active && mounted) {
      setState(() {
        _active = cert = App.cert['id'];
        domain = null;
      });
    }
  }

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

  Json get certJ => App.certs.firstWhere((c) => c['id'] == cert);

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
        allowMultiple: true, withData: true, type: FileType.custom, allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'gif', 'txt', 'md']);
    if (r != null) setState(() => files.addAll(r.files.where((f) => f.bytes != null)));
  }

  String _mime(String name) => switch (name.split('.').last.toLowerCase()) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'text/plain',
      };

  Future<void> _go() async {
    setState(() {
      result = null;
      error = null;
    });
    final body = {
      'cert': cert,
      if (domain != null) 'domain': domain,
      if (topic.text.trim().isNotEmpty) 'topic': topic.text.trim(),
      if (text.text.trim().isNotEmpty) 'text': text.text.trim(),
      'files': [
        for (final f in files) {'name': f.name, 'media_type': _mime(f.name), 'data': base64Encode(f.bytes!)}
      ],
      'count': int.tryParse(count.text) ?? 20,
      if (types.isNotEmpty) 'types': types.toList(),
      'exam_style': examStyle,
    };
    await Api.sync(); // so dedupe sees every existing card
    if (!mounted) return;
    if (backgroundGenerate) {
      final msg = await busy(context, 'Queuing…', () => queueCards(body));
      if (msg != null) {
        setState(() {
          result = msg;
          made = [];
        });
        files.clear();
        text.clear();
      } else if (Api.online.value == false) {
        setState(() => error = 'Needs connection');
      }
      return;
    }
    final r = await busy(context, 'Generating ${body['count']} cards… this can take a couple of minutes.', () => generateCards(body));
    if (r != null) {
      setState(() {
        result = r.$1;
        made = r.$2;
      });
      files.clear();
      text.clear();
    } else if (Api.online.value == false) {
      setState(() => error = 'Needs connection');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: cert,
            decoration: const InputDecoration(labelText: 'Certification', border: OutlineInputBorder()),
            items: [for (final c in App.certs) DropdownMenuItem(value: c['id'] as String, child: Text(c['code']))],
            onChanged: (v) => setState(() {
              cert = v!;
              domain = null;
            }),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
            width: 90,
            child: TextField(
                controller: count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Count', border: OutlineInputBorder()))),
      ]),
      const SizedBox(height: 10),
      DropdownButtonFormField<String?>(
        value: domain,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Domain', border: OutlineInputBorder()),
        items: [
          const DropdownMenuItem(value: null, child: Text('Any / let the AI decide')),
          for (final d in certJ['domains'] as List)
            DropdownMenuItem(value: d['id'] as String, child: Text('${d['id']}. ${d['name']}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => setState(() => domain = v),
      ),
      const SizedBox(height: 10),
      TextField(
          controller: topic, decoration: const InputDecoration(labelText: 'Topic (optional), e.g. DynamoDB GSIs', border: OutlineInputBorder())),
      const SizedBox(height: 10),
      TextField(
          controller: text,
          minLines: 3,
          maxLines: 10,
          decoration: const InputDecoration(labelText: 'Paste notes (optional)', border: OutlineInputBorder(), alignLabelWithHint: true)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final f in files) InputChip(label: Text(f.name), onDeleted: () => setState(() => files.remove(f))),
        ActionChip(avatar: const Icon(Icons.attach_file, size: 18), label: const Text('PDF / screenshot'), onPressed: _pick),
      ]),
      const SizedBox(height: 8),
      Text('Card types (none selected = AI picks the best mix)', style: TextStyle(color: cs.primary, fontSize: 13)),
      Wrap(spacing: 6, children: [
        for (final e in typeLabels.entries)
          if (e.key != 'occlusion')
            FilterChip(
                label: Text(e.value), selected: types.contains(e.key), onSelected: (v) => setState(() => v ? types.add(e.key) : types.remove(e.key))),
      ]),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Exam-style questions'),
          subtitle: const Text('Scenario MCQs (or hands-on tasks for CKAD)'),
          value: examStyle,
          onChanged: (v) => setState(() => examStyle = v)),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('In the background (50% cheaper)'),
          subtitle: const Text('Cards arrive within minutes, on the next sync. Off = wait for them now.'),
          value: backgroundGenerate,
          onChanged: (v) async {
            App.settings['background_generate'] = v;
            await App.saveSettings();
            setState(() {});
          }),
      FilledButton.icon(onPressed: _go, icon: const Icon(Icons.auto_awesome), label: const Text('Generate')),
      if (error != null) NeedsConnection(error!, onRetry: _go),
      if (result != null) ...[
        const SizedBox(height: 12),
        Text(result!, style: TextStyle(color: cs.primary)),
        for (final c in made)
          ListTile(
              dense: true,
              title: autoText(plain(c['question']), maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(typeLabels[c['type']] ?? ''),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardDetail(c['id'])))),
      ],
      const JobsList(),
    ]);
  }
}

/// Recent background generations and their status.
class JobsList extends StatelessWidget {
  const JobsList({super.key});
  @override
  Widget build(BuildContext context) => Live(
        load: () async => (await Db.query('job'))..sort((a, b) => ((b['created_at'] as int?) ?? 0).compareTo((a['created_at'] as int?) ?? 0)),
        builder: (context, jobs) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (jobs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Background generations', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
          for (final j in jobs.take(5))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (j['status']) { 'done' => Icons.check_circle_outline, 'failed' => Icons.error_outline, _ => Icons.hourglass_top }),
              title: Text(j['task'] == 'diagrams'
                  ? 'Diagrams · ${j['count']} cards'
                  : '${j['count']} cards · ${(j['label'] ?? '').toString().isEmpty ? j['cert'] ?? '' : j['label']}'),
              subtitle: Text(switch (j['status']) {
                'done' when j['task'] == 'diagrams' => 'Drew ${j['added']} (the rest read fine as text)',
                'done' => 'Added ${j['added']}${(j['skipped_duplicates'] ?? 0) > 0 ? ' · ${j['skipped_duplicates']} duplicates skipped' : ''}',
                'failed' => 'Failed: ${j['error']}',
                _ => 'Queued ${DateTime.fromMillisecondsSinceEpoch(j['created_at'] as int).toString().substring(11, 16)} · arrives on a later sync',
              }),
            ),
        ]),
      );
}

/// Sync, then analyze the review history and store the result. Returns an error to show, or null.
Future<String?> runAnalysis(BuildContext context) async {
  final err = await Api.sync();
  if (err != null) return Api.online.value == false ? 'Needs connection' : err;
  if (!context.mounted) return null;
  final res = await busy(context, 'Analyzing your review history…', () => Api.ai('ai/analyze', {'cert': App.cert['id']}));
  if (res == null) return Api.online.value == false ? 'Needs connection' : null;
  final overrides = ((res.remove('overrides') as List?) ?? []).map((o) => Map<String, dynamic>.from(o as Map)).toList();
  await Db.putAll('override', overrides, dirty: false);
  await Db.putAll('analysis', [res], dirty: false);
  await applyPendingOverrides();
  await Api.sync();
  return null;
}

/// Generate cards for an analysis action or weak area ({cert?, domain, topic, count?}).
Future<void> generateFor(BuildContext context, Map a) async {
  final body = {'cert': a['cert'] ?? App.cert['id'], 'domain': a['domain'], 'topic': a['topic'], 'count': a['count'] ?? 15};
  String? msg;
  if (backgroundGenerate) {
    msg = await busy(context, 'Queuing ${a['count'] ?? 15} cards on ${a['topic']}…', () => queueCards(body));
  } else {
    msg = (await busy(context, 'Generating ${a['count'] ?? 15} cards on ${a['topic']}…', () => generateCards(body)))?.$1;
  }
  if (msg != null && context.mounted) toast(context, msg);
}

class InsightsTab extends StatefulWidget {
  const InsightsTab({super.key});
  @override
  State<InsightsTab> createState() => _InsightsTabState();
}

class _InsightsTabState extends State<InsightsTab> {
  String? error;

  Future<(Json?, List<Json>)> _load() async {
    final list = (await Db.query('analysis')).where((a) => a['cert'] == App.cert['id']).toList()
      ..sort((a, b) => ((b['created_at'] as int?) ?? 0).compareTo((a['created_at'] as int?) ?? 0));
    if (list.isEmpty) return (null, <Json>[]);
    final ids = ((list.first['override_ids'] as List?) ?? []).cast<String>();
    final overrides = (await Db.query('override')).where((o) => ids.contains(o['id'])).toList()
      ..sort((a, b) => ids.indexOf(a['id']).compareTo(ids.indexOf(b['id']))); // stable, as the analysis listed them
    return (list.first, overrides);
  }

  Future<void> _run() async {
    setState(() => error = null);
    final err = await runAnalysis(context);
    if (mounted) setState(() => error = err);
  }

  Future<void> _action(Map a) => generateFor(context, a);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cert = App.cert;
    return Live(
      load: _load,
      builder: (context, data) {
        final (a, overrides) = data;
        return ListView(padding: const EdgeInsets.all(16), children: [
          FilledButton.icon(onPressed: _run, icon: const Icon(Icons.insights), label: Text('Analyze weak areas (${cert['code']})')),
          if (error != null) NeedsConnection(error!, onRetry: _run),
          if (a == null)
            const Padding(padding: EdgeInsets.all(24), child: Text('No analysis yet. Study a bit, then run one.', textAlign: TextAlign.center))
          else ...[
            const SizedBox(height: 8),
            Text('From ${DateTime.fromMillisecondsSinceEpoch(a['created_at'] as int).toString().substring(0, 16)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            Md(a['summary'] ?? ''),
            const SizedBox(height: 12),
            Text('Weak areas', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
            for (final w in ((a['weak_areas'] as List?) ?? []).cast<Map>())
              Card(
                  child: ListTile(
                leading: CircleAvatar(child: Text('${w['rank']}')),
                title: Text('${w['topic']}'),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(domainName(cert, '${w['domain']}'), style: TextStyle(color: cs.primary, fontSize: 12)),
                  Md('${w['diagnosis']}', style: const TextStyle(fontSize: 14)),
                ]),
              )),
            const SizedBox(height: 8),
            Text('Do this', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
            for (final act in ((a['actions'] as List?) ?? []).cast<Map>())
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text('${act['label']}'),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => _action(act),
              ),
            Text('Watch', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
            for (final v in ((a['videos'] as List?) ?? []).cast<Map>())
              ListTile(
                  leading: const Icon(Icons.smart_display_outlined, color: Colors.redAccent),
                  title: Text('${v['title']}'),
                  onTap: () => openUrl(v['url'])),
            if (overrides.isNotEmpty) ...[
              Text('Scheduling overrides', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
              for (final o in overrides)
                ListTile(
                  leading: const Icon(Icons.event_repeat),
                  title: Text('${(o['card_ids'] as List).length} cards: ${[
                    if (o['due_now'] == true) 'review now',
                    if (o['due_shift_days'] != null) 'shift ${o['due_shift_days']}d',
                    if (o['priority'] != null) 'priority ${o['priority']}',
                  ].join(', ')}'),
                  subtitle: Text('${o['reason']}${o['reverted_at'] != null ? '\n(reverted)' : ''}'),
                  trailing: o['applied_at'] != null && o['reverted_at'] == null
                      ? TextButton(onPressed: () => revertOverride(o), child: const Text('Revert'))
                      : null,
                ),
            ],
          ],
        ]);
      },
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Json card;
  const ChatScreen(this.card, {super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final input = TextEditingController();
  List<Map> messages = [];
  bool sending = false;
  String? error;

  @override
  void initState() {
    super.initState();
    Db.get(widget.card['id']).then((_) async {
      final chat = await Db.query('chat', where: 'id = ?', args: [widget.card['id']]);
      if (chat.isNotEmpty && mounted) setState(() => messages = ((chat.first['messages'] as List?) ?? []).cast<Map>());
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? input.text).trim();
    if (text.isEmpty || sending) return;
    final next = [
      ...messages,
      {'role': 'user', 'text': text, 'ts': nowMs()}
    ];
    setState(() {
      messages = next;
      sending = true;
      error = null;
    });
    input.clear();
    try {
      final card = Map<String, dynamic>.from(widget.card)..remove('fsrs');
      final res = await Api.ai('ai/explain', {
        'card': card,
        'messages': [
          for (final m in next) {'role': m['role'], 'text': m['text']}
        ]
      });
      messages = [
        ...next,
        {'role': 'assistant', 'text': res['reply'], 'ts': nowMs()}
      ];
      await Db.put('chat', {'id': widget.card['id'], 'card_id': widget.card['id'], 'messages': messages});
    } on ApiError catch (e) {
      messages = messages.sublist(0, messages.length - 1);
      input.text = text;
      error = e.message;
    }
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Explain this card')),
      body: SafeArea(
        child: Column(children: [
          const OnlineBanner(),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Card(child: Padding(padding: const EdgeInsets.all(12), child: Md(clozeBack(widget.card['question'] ?? '')))),
              if (messages.isEmpty)
                Wrap(spacing: 6, children: [
                  for (final q in [
                    'Explain this to me in depth',
                    'Give me an analogy',
                    'What are the common traps here?',
                    'How would the exam test this?'
                  ])
                    ActionChip(label: Text(q), onPressed: () => _send(q)),
                ]),
              for (final m in messages)
                Align(
                  alignment: m['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .88),
                    decoration: BoxDecoration(
                        color: m['role'] == 'user' ? cs.primaryContainer : cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
                    child: Md('${m['text']}'),
                  ),
                ),
              if (sending) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
              if (error != null) NeedsConnection(error!, onRetry: _send),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: 'Ask a follow-up…', border: OutlineInputBorder()))),
              IconButton(onPressed: _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }
}
