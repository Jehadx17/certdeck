import 'package:flutter/material.dart';

import 'i18n.dart';
import 'logic.dart';

/// The one short onboarding (docs/GOAL-DARB.md): segment, then grade or track, then the exam and its date.
/// Saved in the synced `settings` doc; the autopilot tunes everything else.
const segments = [
  ('middle', 'Middle school', Icons.backpack_outlined),
  ('high', 'High school', Icons.school_outlined),
  ('university', 'University', Icons.account_balance_outlined),
  ('cert', 'Certification', Icons.workspace_premium_outlined),
];

/// Grades or tracks per segment (Saudi MOE: three middle-school grades; high school = a common first year, then a track).
const grades = {
  'middle': [('m1', 'Grade 7 (1st intermediate)'), ('m2', 'Grade 8 (2nd intermediate)'), ('m3', 'Grade 9 (3rd intermediate)')],
  'high': [
    ('h1', 'Grade 10 (common first year)'),
    ('general', 'General track'),
    ('cs_eng', 'Computer science and engineering track'),
    ('health', 'Health and life track'),
    ('business', 'Business administration track'),
    ('sharia', 'Sharia track'),
  ],
  'university': [('prep', 'Preparatory year'), ('y1', 'Years 1-2'), ('y3', 'Years 3 and up')],
  'cert': [('step', 'STEP (English)'), ('prof', 'Professional certification'), ('other', 'Other')],
};

/// What a student in each segment is preparing for.
const exams = {
  'middle': [('school', 'School exams'), ('nafs', 'Nafs national test')],
  'high': [('qudurat', 'Qudurat (GAT)'), ('tahsili', 'Tahsili (SAAT)'), ('school', 'School exams')],
  'university': [('course', 'Course exams'), ('qudurat', 'Qudurat (GAT)')],
  'cert': [('cert', 'The certification exam')],
};

bool get onboarded => App.settings['segment'] is String && App.settings['exam'] is String;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int step = 0;
  String? segment = App.settings['segment'] as String?, grade = App.settings['grade'] as String?;
  String? exam = App.settings['exam'] as String?;
  DateTime? date = DateTime.tryParse('${App.settings['exam_date']}');

  Future<void> _finish() async {
    App.settings
      ..['segment'] = segment
      ..['grade'] = grade
      ..['exam'] = exam
      ..['exam_date'] = date?.toIso8601String().substring(0, 10);
    await App.saveSettings();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Widget _choices(List<(String, String)> items, String? selected, void Function(String) pick) => Column(children: [
        for (final (id, label) in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              tileColor: Theme.of(context).colorScheme.surfaceContainerLow,
              selected: selected == id,
              title: Text(t(label)),
              trailing: selected == id ? const Icon(Icons.check_circle) : null,
              onTap: () => setState(() => pick(id)),
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pages = [
      (
        t('What are you studying for?'),
        Column(children: [
          for (final (id, label, icon) in segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: cs.surfaceContainerLow,
                minVerticalPadding: 18,
                leading: Icon(icon, color: cs.primary),
                title: Text(t(label), style: const TextStyle(fontSize: 18)),
                selected: segment == id,
                onTap: () => setState(() {
                  if (segment != id) grade = exam = null;
                  segment = id;
                  step = 1;
                }),
              ),
            ),
        ]),
        segment != null,
      ),
      (
        segment == 'high' ? t('Which grade or track?') : t('Which grade?'),
        _choices(grades[segment] ?? const [], grade, (g) => grade = g),
        grade != null,
      ),
      (
        t('Your next exam'),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _choices(exams[segment] ?? const [], exam, (e) => exam = e),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text(date == null ? t('Exam date (optional)') : '${t('Exam date')}: ${date!.toIso8601String().substring(0, 10)}'),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                  context: context, firstDate: now, lastDate: now.add(const Duration(days: 730)), initialDate: date ?? now.add(const Duration(days: 60)));
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 8),
          Text(t('No date? We plan steady progress and you can add it later.'), style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
        exam != null,
      ),
    ];
    final (title, body, ready) = pages[step];
    return Scaffold(
      appBar: AppBar(
        leading: step > 0 ? BackButton(onPressed: () => setState(() => step--)) : null,
        title: Text(t('Step {n} of {m}', {'n': step + 1, 'm': pages.length})),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          body,
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: !ready ? null : () => step == pages.length - 1 ? _finish() : setState(() => step++),
            child: Text(step == pages.length - 1 ? t('Start studying') : t('Next')),
          ),
        ),
      ),
    );
  }
}
