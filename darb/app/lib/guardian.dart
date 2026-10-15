import 'package:flutter/material.dart';

import 'api.dart';
import 'db.dart';
import 'i18n.dart';
import 'widgets.dart';

/// Under 18: a guardian confirms by email before anything is synced or sent to AI (docs/DARB-PDPL.md).
class GuardianScreen extends StatefulWidget {
  const GuardianScreen({super.key});
  @override
  State<GuardianScreen> createState() => _GuardianScreenState();
}

class _GuardianScreenState extends State<GuardianScreen> {
  late final email = TextEditingController(text: '${Api.me.value?['guardian_email'] ?? ''}');
  bool sent = '${Api.me.value?['guardian_email'] ?? ''}'.isNotEmpty;

  Future<void> _send() async {
    // busy() shows the server's message (a wrong address, the student's own email) as a toast.
    final me = await busy(context, t('Sending…'), () => Api.call('POST', 'account/guardian', body: {'email': email.text.trim()}));
    if (me == null) return;
    Api.me.value = {...?Api.me.value, ...Map<String, dynamic>.from(me as Map)};
    setState(() => sent = true);
  }

  Future<void> _check() async {
    await busy(context, t('Checking…'), () => Api.refreshMe().catchError((_) {}));
    if (Api.me.value?['guardian'] != 'pending') {
      Api.sync().ignore();
      changes.value++;
    } else if (mounted) {
      toast(context, t('Not confirmed yet.'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Your guardian\'s OK'))),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Icon(Icons.family_restroom, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t('Students under 18 need a parent or guardian to agree before Darb saves your progress. We email them a link.')),
            const SizedBox(height: 20),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(labelText: t('Guardian\'s email'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _send, child: Text(sent ? t('Send again') : t('Send the link'))),
            if (sent) ...[
              const SizedBox(height: 24),
              Text(t('Waiting for {email} to open the link.', {'email': email.text.trim()})),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _check, child: Text(t('They confirmed: check again'))),
            ],
          ]),
        ),
      );
}
