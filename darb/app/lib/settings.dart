import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'billing.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'notify.dart';
import 'onboarding.dart';
import 'signin.dart';
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
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const OnboardingScreen()));
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
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(t('Sign out')),
            onTap: () async {
              final err = await Api.sync(); // push this phone's progress first
              if (!context.mounted) return;
              if (err != null && !await _confirm(context, t('Sign out without saving?'),
                  t('Some progress on this phone hasn\'t reached the server yet (no connection). Signing out now loses it.'))) {
                return;
              }
              await Auth.signOut();
              await Billing.stop();
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: cs.error),
            title: Text(t('Delete my account'), style: TextStyle(color: cs.error)),
            onTap: () => _delete(context),
          ),
          header(t('Subscription')),
          ValueListenableBuilder(
            valueListenable: Api.me,
            builder: (_, me, __) => Column(children: [
              ListTile(
                leading: const Icon(Icons.workspace_premium_outlined),
                title: Text(Billing.premium ? t('Darb Plus') : t('Free')),
                subtitle: Billing.premium && me?['premium_until'] != null
                    ? Text(t('Renews or ends on {date}', {'date': '${me!['premium_until']}'.substring(0, 10)}))
                    : null,
                trailing: Billing.premium ? null : FilledButton(onPressed: () => openPaywall(context), child: Text(t('Upgrade'))),
              ),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: Text(t('Manage or cancel')),
                onTap: () => launchUrl(Billing.manageUrl, mode: LaunchMode.externalApplication),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(t('Restore purchases')),
                onTap: () async {
                  final err = await busy(context, t('Talking to the store…'), Billing.restore);
                  if (context.mounted) toast(context, err ?? t('Welcome to Darb Plus!'));
                },
              ),
            ]),
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

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(title: Text(title), content: Text(body), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Continue'))),
      ]),
    ) ==
    true;

/// Deletes the account on the server and everything on this phone (App Store 5.1.1(v): in the app, no email detour).
Future<void> _delete(BuildContext context) async {
  final ok = await _confirm(
      context,
      t('Delete your account?'),
      [
        t('Your progress, uploads and settings are deleted from Darb\'s servers and this phone. This can\'t be undone.'),
        if (Billing.premium)
          t('Your subscription is billed by {store}: cancel it there too, or it keeps renewing.', {'store': Platform.isIOS ? 'App Store' : 'Google Play'}),
      ].join('\n\n'));
  if (!ok || !context.mounted) return;
  final done = await busy(context, t('Deleting…'), () => Api.call('DELETE', 'account'));
  if (done == null) return;
  await Billing.stop();
  await Api.forget();
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
