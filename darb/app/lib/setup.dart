import 'package:flutter/material.dart';

import 'api.dart';
import 'db.dart';
import 'easy.dart';
import 'i18n.dart';
import 'logic.dart';
import 'notify.dart';

/// Six short questions after sign-up (and under Settings → Study setup). Only things that change how the app
/// studies with you: time, reminder hour, how new the subject is, the goal, test nerves, language.
/// Not asked: "learning style" (visual/auditory/kinesthetic): matching teaching to it has no evidence behind it.
/// Everything else (pace, load, retention) the app tunes itself from the answers' results.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late int minutes = (App.settings['session_minutes'] as num?)?.toInt() ?? 10;
  int? reminder = (App.settings['reminder_minute'] as num?)?.toInt();
  late String expertise = (App.settings['expertise'] as String?) ?? 'some';
  late String goal = (App.settings['goal'] as String?) ?? 'good';
  late String nerves = App.settings['nerves'] == true ? 'yes' : 'no';
  late String lang = App.lang;
  late final intention = TextEditingController(text: (App.settings['intention'] as String?) ?? '');

  Future<void> _save() async {
    if ((App.settings['session_minutes'] as num?)?.toInt() != minutes) App.settings['session_minutes_set_at'] = nowMs();
    App.settings
      ..['session_minutes'] = minutes
      ..['expertise'] = expertise
      ..['goal'] = goal
      ..['nerves'] = nerves == 'yes'
      ..['lang'] = lang
      ..['intention'] = intention.text.trim();
    if (reminder != null) App.settings['reminder_minute'] = reminder;
    await App.saveSettings();
    await Db.setMeta('setup_done', '1');
    Reminders.reschedule().ignore();
    Api.sync().ignore();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _skip() async {
    await Db.setMeta('setup_done', '1');
    if (mounted) Navigator.pop(context, false);
  }

  Widget _q(String title, List<(Object, String)> options, Object? selected, void Function(Object) onPick) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 8, children: [
            for (final (v, label) in options)
              ChoiceChip(
                  label: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: Text(label, style: const TextStyle(fontSize: 15))),
                  selected: selected == v,
                  onSelected: (_) => setState(() => onPick(v))),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) => easyScale(
        context,
        Scaffold(
          appBar: AppBar(
            title: Text(t('Set up your study')),
            actions: [TextButton(onPressed: _skip, child: Text(t('Skip')))],
          ),
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text(t('A few quick questions so the app fits you. You can change them later in Settings.'), style: const TextStyle(fontSize: 14, color: Colors.white60)),
              const SizedBox(height: 20),
              _q(t('How long can you study each day?'), [for (final m in const [5, 10, 15, 20]) (m, t('{m} min', {'m': m}))], minutes, (v) => minutes = v as int),
              _q(t('When do you usually study?'), [(8 * 60, t('Morning')), (14 * 60, t('Afternoon')), (18 * 60, t('Evening')), (21 * 60, t('Night'))], reminder,
                  (v) => reminder = v as int),
              Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: TextField(
                      controller: intention,
                      maxLength: 80,
                      decoration: InputDecoration(
                          labelText: t('Where and when will you study? (optional)'), hintText: t('After dinner, at my desk'), border: const OutlineInputBorder()))),
              _q(t('How well do you know your subjects?'), [('new', t('New to them')), ('some', t('Some background')), ('know', t('I know them well'))], expertise, (v) => expertise = v as String),
              _q(t('What are you aiming for?'), [('pass', t('Pass')), ('good', t('A good grade')), ('top', t('The top grade'))], goal, (v) => goal = v as String),
              _q(t('Do tests make you nervous?'), [('no', t('Not really')), ('yes', t('A bit or a lot'))], nerves, (v) => nerves = v as String),
              _q(t('Language'), [('en', 'English'), ('ar', 'العربية')], lang, (v) => lang = v as String),
              const SizedBox(height: 4),
              FilledButton(style: easyButton(), onPressed: _save, child: Text(t('Save'))),
            ]),
          ),
        ),
      );
}
