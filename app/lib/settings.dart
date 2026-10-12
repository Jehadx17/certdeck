import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'api.dart';
import 'db.dart';
import 'logic.dart';
import 'widgets.dart';

/// Export file per docs/cards.schema.json, images inlined as base64.
Future<Json> buildExport() async {
  final cards = await Db.query('card');
  final media = <String, String>{};
  for (final c in cards) {
    for (final n in cardMedia(c)) {
      final f = Db.mediaFile(n);
      if (await f.exists()) media[n] = base64Encode(await f.readAsBytes());
    }
  }
  return {
    'format': 'certdeck',
    'version': 1,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'certs': App.certs,
    'cards': cards,
    'media': media,
  };
}

/// Imports cards (and their images) from an export file. Returns the number imported.
Future<int> importLocal(Json data) async {
  if (data['format'] != 'certdeck' || data['cards'] is! List) throw const FormatException('Not a CertDeck export (format/cards missing)');
  final rename = <String, String>{};
  for (final e in ((data['media'] as Map?) ?? {}).entries) {
    final name = e.key as String;
    rename[name] = await Db.saveMedia(base64Decode(e.value as String));
  }
  final cards = <Json>[];
  for (final raw in data['cards'] as List) {
    final c = Map<String, dynamic>.from(raw as Map);
    if (c['type'] is! String || c['question'] is! String || !typeLabels.containsKey(c['type'])) {
      throw FormatException('Invalid card: ${jsonEncode(raw).substring(0, 80)}');
    }
    c['id'] ??= uuid.v4();
    c['created_at'] ??= nowMs();
    c['source'] ??= 'import';
    c['certs'] ??= {};
    if (c['image'] != null) c['image'] = rename[c['image']] ?? c['image'];
    for (final k in ['question_images', 'answer_images']) {
      if (c[k] is List) c[k] = [for (final n in c[k]) rename[n] ?? n];
    }
    cards.add(c);
  }
  await Db.putAll('card', cards);
  return cards.length;
}

Future<void> shareJson(Json data, String name) async {
  final f = File(p.join((await getTemporaryDirectory()).path, name));
  await f.writeAsString(jsonEncode(data));
  await Share.shareXFiles([XFile(f.path, mimeType: 'application/json')], subject: name);
}

Future<Json?> pickJson() async {
  final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
  final bytes = r?.files.firstOrNull?.bytes;
  return bytes == null ? null : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)));
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final url = TextEditingController(text: Api.url);
  late final token = TextEditingController(text: Api.token);
  bool showToken = false;
  Future<dynamic>? usage = Api.configured ? Api.call('GET', 'usage') : null;

  String get stamp => DateTime.now().toIso8601String().substring(0, 10);

  Future<void> _setCert(Json cert, {String? examDate, bool clearDate = false, bool? active}) async {
    if (active == true) {
      for (final c in App.certs.where((c) => c['active'] == true && c['id'] != cert['id'])) {
        await Db.put('cert', c..['active'] = false);
      }
      cert['active'] = true;
      App.settings['active_cert'] = cert['id'];
      await App.saveSettings();
    }
    if (examDate != null || clearDate) cert['exam_date'] = examDate;
    await Db.put('cert', cert);
    await App.reload();
    setState(() {});
  }

  Widget _num(String key, String label) => ListTile(
        title: Text(label),
        trailing: SizedBox(
          width: 80,
          child: TextFormField(
            initialValue: '${App.setting(key)}',
            textAlign: TextAlign.end,
            keyboardType: TextInputType.number,
            onChanged: (v) async {
              final n = int.tryParse(v);
              if (n == null || n < 0) return;
              App.settings[key] = n;
              await App.saveSettings();
            },
          ),
        ),
      );

  Future<void> _connect() async {
    await Api.configure(url.text, token.text);
    if (!mounted) return;
    final err = await busy(context, 'Connecting & restoring…', () => Api.sync());
    if (mounted) toast(context, err ?? 'Connected. Everything is synced.');
    setState(() {});
  }

  Future<void> _run(String label, Future<String> Function() f) async {
    try {
      final msg = await busy(context, label, f);
      if (msg != null && mounted) toast(context, msg);
    } on FormatException catch (e) {
      if (mounted) toast(context, 'Import failed: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget header(String t) =>
        Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)));
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // Rebuild after syncs (a restore can change certs, exam dates and limits).
      body: ValueListenableBuilder(
        valueListenable: changes,
        builder: (context, _, __) => ListView(children: [
          header('Certifications'),
          for (final c in App.certs)
            ListTile(
              leading: Radio<String>(value: c['id'], groupValue: App.settings['active_cert'], onChanged: (_) => _setCert(c, active: true)),
              title: Text(c['code']),
              subtitle: Text(c['exam_date'] == null ? 'No exam date' : 'Exam: ${c['exam_date']}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (c['exam_date'] != null) IconButton(icon: const Icon(Icons.clear), onPressed: () => _setCert(c, clearDate: true)),
                IconButton(
                  icon: const Icon(Icons.event),
                  onPressed: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                        context: context,
                        firstDate: now.subtract(const Duration(days: 1)),
                        lastDate: now.add(const Duration(days: 730)),
                        initialDate: DateTime.tryParse(c['exam_date'] ?? '') ?? now.add(const Duration(days: 60)));
                    if (d != null) _setCert(c, examDate: d.toIso8601String().substring(0, 10));
                  },
                ),
              ]),
              onTap: () => _setCert(c, active: true),
            ),
          header('Study'),
          _num('new_per_day', 'New cards per day'),
          _num('max_reviews_per_day', 'Max reviews per day'),
          _num('leech_threshold', 'Leech after N lapses'),
          header('Backend & sync'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server URL')),
              TextField(
                controller: token,
                obscureText: !showToken,
                decoration: InputDecoration(
                    labelText: 'API token',
                    suffixIcon: IconButton(
                        icon: Icon(showToken ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => showToken = !showToken))),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: FilledButton(onPressed: _connect, child: const Text('Save & sync'))),
              ]),
            ]),
          ),
          ValueListenableBuilder(
            valueListenable: Api.lastSync,
            builder: (_, v, __) => ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Sync now'),
              subtitle: Text('Last sync: $v'),
              onTap: () async {
                final err = await Api.sync();
                if (context.mounted) toast(context, err ?? 'Synced');
              },
            ),
          ),
          FutureBuilder(
            future: usage,
            builder: (_, snap) {
              final u = snap.data;
              return ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('AI spend this month'),
                subtitle: Text(usage == null
                    ? 'Connect the backend to see it'
                    : snap.hasError
                        ? 'Needs connection (tap to retry)'
                        : u == null
                            ? 'Loading…'
                            : '\$${(u['usd'] as num).toStringAsFixed(2)} · ${u['calls']} calls (${u['batch_calls']} in background) · all time \$${(u['all_time_usd'] as num).toStringAsFixed(2)}'),
                onTap: () => setState(() => usage = Api.call('GET', 'usage')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Re-optimize FSRS parameters'),
            subtitle: Text(App.params == null
                ? 'Using FSRS defaults (optimizes weekly on the server once you have enough reviews)'
                : 'Using parameters optimized from your reviews'),
            onTap: () => _run('Optimizing on the server…', () async {
              await Api.sync();
              final r = await Api.call('POST', 'fsrs/optimize', body: {}, timeout: const Duration(minutes: 5));
              await Api.sync();
              return r?['optimized_at'] == null
                  ? 'Not enough history yet (${r?['review_count']} reviews, needs 512); keeping FSRS defaults'
                  : 'Optimized from ${r?['review_count']} reviews';
            }),
          ),
          header('Import / export'),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Export cards to a file'),
            subtitle: const Text('JSON with images inlined (share or save)'),
            onTap: () => _run('Exporting…', () async {
              await shareJson(await buildExport(), 'certdeck-$stamp.json');
              return 'Exported';
            }),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Import cards from a file'),
            onTap: () async {
              final data = await pickJson();
              if (data != null && mounted) _run('Importing…', () async => 'Imported ${await importLocal(data)} cards');
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('Export from server'),
            subtitle: const Text('Downloads the backend\'s full card export'),
            onTap: () => _run('Downloading export…', () async {
              final data = await Api.call('GET', 'export', timeout: const Duration(minutes: 3));
              await shareJson(Map<String, dynamic>.from(data), 'certdeck-server-$stamp.json');
              return 'Exported';
            }),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Import a file through the server'),
            subtitle: const Text('Server validates it against the schema, then it syncs down'),
            onTap: () async {
              final data = await pickJson();
              if (data == null || !mounted) return;
              _run('Uploading…', () async {
                final r = await Api.call('POST', 'import', body: data, timeout: const Duration(minutes: 3));
                await Api.sync();
                return 'Server imported ${r['imported']} cards';
              });
            },
          ),
          const SizedBox(height: 40),
        ]),
      ),
    );
  }
}
