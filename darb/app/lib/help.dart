import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'i18n.dart';
import 'widgets.dart';

/// In-app help: short answers to what students ask, then the support email and the legal pages.
const faq = [
  ('How do I study?', 'Tap Study now once a day. A session takes about 10 minutes and Darb picks the questions: new ones, and the ones you are about to forget.'),
  ('Does it work without internet?', 'Yes. Downloaded packs and your progress stay on the phone. Darb saves your progress to your account when you are back online.'),
  ('What does "How sure are you?" do?', 'It helps Darb plan: questions you guessed come back sooner than ones you were sure about. Being sure and wrong is the best moment to learn.'),
  ('A question is wrong. What do I do?', 'Tap the flag at the top of the question. We check every report and tell you when it is fixed.'),
  ('Why does AI help stop sometimes?', 'Each account has a monthly amount of AI help. It comes back at the start of next month. Studying always works.'),
  ('How do I cancel my subscription?', 'In Settings → Subscription → Manage or cancel. It opens the App Store or Google Play page, where cancelling takes effect at the end of the paid period.'),
  ('Can I get a refund?', 'Payments go through the App Store or Google Play, so refunds follow their rules. Request one from them; we are happy to help by email.'),
  ('How do I delete my account?', 'Settings → Account → Delete my account. Everything is deleted from our servers and this phone.'),
  ('Are these the real exam questions?', 'No. Darb\'s questions are original practice questions in the official format and topics, checked carefully. Darb is not affiliated with Qiyas (ETEC) or the Ministry of Education.'),
];

const supportEmail = 'support@${Api.domain}';

void openHelp(BuildContext context) => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen()));

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Help'))),
        body: ListView(padding: const EdgeInsets.all(8), children: [
          for (final (q, a) in faq)
            ExpansionTile(title: Text(t(q)), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12), children: [
              Align(alignment: AlignmentDirectional.centerStart, child: Text(t(a), style: TextStyle(color: muted(context)))),
            ]),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: Text(t('Write to us')),
            subtitle: const Text(supportEmail),
            onTap: () => launchUrl(Uri(scheme: 'mailto', path: supportEmail, query: 'subject=Darb')),
          ),
          for (final (label, path) in [('Privacy policy', 'privacy'), ('Terms of use', 'terms'), ('AI and students under 18', 'ai-and-minors')])
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(t(label)),
              onTap: () => launchUrl(Uri.parse('https://${Api.domain}/$path'), mode: LaunchMode.externalApplication),
            ),
        ]),
      );
}
