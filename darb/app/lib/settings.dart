import 'package:flutter/material.dart';

import 'api.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'notify.dart';
import 'setup.dart';
import 'widgets.dart';

/// Settings hold only what the spec lists: theme, language, account, subscription, notifications, study goal / exam
/// date, delete account, and one collapsed Advanced section. Everything else is automatic.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _set(String key, Object value) async {
    App.settings[key] = value;
    await App.saveSettings();
    if (key == 'lang') Reminders.reschedule().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget header(String s) =>
        Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(s, style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)));
    Widget choice(String key, String current, List<(String, String)> options) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: [for (final (v, label) in options) ButtonSegment(value: v, label: Text(label))],
            selected: {current},
            onSelectionChanged: (v) => _set(key, v.first),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t('Settings'))),
      body: ValueListenableBuilder(
        valueListenable: changes,
        builder: (context, _, __) => ListView(children: [
          header(t('Theme')),
          choice('theme', '${App.settings['theme'] ?? 'system'}', [('system', t('Automatic')), ('light', t('Light')), ('dark', t('Dark'))]),
          header(t('Language')),
          choice('lang', App.lang, [('ar', 'العربية'), ('en', 'English')]),
          header(t('Study')),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text(t('Study goal and exam date')),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen()));
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(t('Daily study reminder')),
            subtitle: Text(t('Your plan for the day, at {time}', {'time': Reminders.timeLabel})),
            value: App.settings['reminders'] != false,
            onChanged: (v) async {
              await _set('reminders', v);
              await Reminders.reschedule();
            },
          ),
          header(t('Account')),
          ValueListenableBuilder(
            valueListenable: Api.me,
            builder: (_, me, __) => ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text('${me?['name'] ?? ''}'.isEmpty ? t('Signed in') : '${me!['name']}'),
              subtitle: Text('${me?['email'] ?? ''}'),
            ),
          ),
          ExpansionTile(
            leading: const Icon(Icons.more_horiz),
            title: Text(t('Advanced')),
            children: [
              ValueListenableBuilder(
                valueListenable: Api.lastSync,
                builder: (_, last, __) => ListTile(
                  title: Text(t('Sync now')),
                  subtitle: Text(t('Last sync: {when}', {'when': last})),
                  trailing: const SyncButton(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }
}

/// Pushes and pulls now; shows a spinner while a sync runs.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Api.syncing,
        builder: (_, busy, __) => busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                icon: const Icon(Icons.sync),
                onPressed: () async {
                  final err = await Api.sync();
                  if (context.mounted) toast(context, err ?? t('Synced'));
                },
              ),
      );
}
