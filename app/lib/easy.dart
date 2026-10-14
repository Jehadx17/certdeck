import 'package:flutter/material.dart';

import 'api.dart';
import 'cards.dart';
import 'college.dart';
import 'college_exam.dart';
import 'college_logic.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'settings.dart';
import 'study.dart';
import 'widgets.dart';

/// The student's app (EASY.md): one big button per exam, simple enough for a child (the students are college students).
/// The setup screens (courses, material, scope, settings) are one tap away under "My courses".

const easyButtonHeight = 50.0;

ButtonStyle easyButton([Color? color]) => FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(easyButtonHeight),
    backgroundColor: color,
    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)));



/// How a session went, for the closing sentence: 3 = most right, 2 = half or more, 1 = fewer.
int sessionTier(int right, int done) => done == 0 ? 0 : (right / done >= .8 ? 3 : (right / done >= .5 ? 2 : 1));

/// The student's screens use the phone's own text size (kept as a hook for a later size setting).
Widget easyScale(BuildContext context, Widget child) => child;

class _Exam {
  final Json a;
  final String course;
  final Scope s;
  _Exam(this.a, this.course, this.s);
  int? get days => s.days;
  int get learned => s.cards.where(s.mastered).length;
  double get done => s.cards.isEmpty ? 0 : learned / s.cards.length;
}

class EasyHome extends StatefulWidget {
  const EasyHome({super.key});
  @override
  State<EasyHome> createState() => _KidHomeState();
}

class _KidHomeState extends State<EasyHome> {
  bool _introChecked = false;

  /// The first-run intro, once this screen is on top (right after signing in, the sign-in screen is still closing).
  void _intro() {
    if (_introChecked || ModalRoute.of(context)?.isCurrent != true) return;
    _introChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (await Db.meta('easy_intro_done') != null) return;
      final seen = await nav.push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const EasyIntro()));
      if (seen == true) await Db.setMeta('easy_intro_done', '1');
      if (seen != true) _introChecked = false; // closed by something else: show it next time
    });
  }

  Future<List<_Exam>> _load() async {
    final out = <_Exam>[];
    for (final a in await upcoming()) {
      final s = await Scope.load(a);
      if (s.cards.isEmpty) continue; // not prepared yet: nothing to study
      out.add(_Exam(a, (await Db.get(a['course_id']))?['name'] ?? '', s));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    _intro();
    return easyScale(
        context,
        Scaffold(
          appBar: AppBar(title: Text(t('My study'), style: const TextStyle(fontWeight: FontWeight.bold))),
          // Help and the setup screens at the bottom: in reach of a thumb, and the title keeps its room.
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(children: [
                Expanded(child: helpButton(context, homeHelp)),
                Expanded(
                    child: TextButton.icon(
                        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ManageScreen())),
                        icon: const Icon(Icons.folder_open_rounded),
                        label: Text(t('My courses')))),
              ]),
            ),
          ),
          body: Live(
            load: _load,
            builder: (context, exams) => exams.isEmpty
                ? _empty(context)
                : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                    _ExamCard(exams.first, big: true),
                    for (final e in exams.skip(1)) _ExamCard(e),
                  ]),
          ),
        ),
      );
  }

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_rounded, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t('Nothing to study yet.'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(t('Tap "My courses" to add your material and exams.'), style: const TextStyle(fontSize: 15), textAlign: TextAlign.center),
          ]),
        ),
      );
}

String easyWhen(int? d) => d == null
    ? ''
    : d == 0
        ? t('The exam is today!')
        : d == 1
            ? t('The exam is tomorrow!')
            : App.lang == 'ar'
                ? 'الاختبار ${countdown(d)}' // Arabic dual/plural forms
                : t('The exam is in {n} days', {'n': d});

class _ExamCard extends StatelessWidget {
  final _Exam e;
  final bool big;
  const _ExamCard(this.e, {this.big = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = e.days;
    return Card(
      margin: const EdgeInsets.only(top: 14),
      color: big ? cs.primaryContainer.withOpacity(.35) : null,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          autoText(e.course, style: TextStyle(fontSize: 14, color: cs.primary)),
          autoText(e.a['title'] ?? '', style: TextStyle(fontSize: big ? 22 : 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(easyWhen(d), style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 12),
          Text(t('{p}% learned · {n} of {m} cards', {'p': (e.done * 100).round(), 'n': e.learned, 'm': e.s.cards.length}),
              style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: e.done, minHeight: 8)),
          const SizedBox(height: 16),
          if (d == 0)
            FilledButton.icon(
                style: easyButton(Colors.orange),
                icon: const Icon(Icons.wb_sunny_rounded),
                label: Text(t('Exam morning warm-up')),
                onPressed: () => easyStudy(context, e.a, kind: 'morning'))
          else if (d == 1)
            FilledButton.icon(
                style: easyButton(Colors.indigo),
                icon: const Icon(Icons.nightlight_round),
                label: Text(t('Night before')),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NightBefore(e.a)))),
          if (d != null && d <= 1) const SizedBox(height: 10),
          FilledButton.icon(
              style: easyButton(),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(t('Study now')),
              onPressed: () => easyStudy(context, e.a)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), textStyle: const TextStyle(fontSize: 15)),
              icon: const Icon(Icons.assignment_turned_in_outlined),
              label: Text(t('Try a practice test')),
              onPressed: () => easyPractice(context, e.a)),
        ]),
      ),
    );
  }
}

/// One tap: about 10 minutes, the app picks the cards (most marks first when the exam is close).
Future<void> easyStudy(BuildContext context, Json a, {String kind = 'study'}) async {
  final s = await Scope.load(a);
  var q = <Json>[];
  StudyQueue? custom;
  if (kind == 'morning') {
    q = morningCheck(s);
  } else {
    if (s.mode != Mode.sprint) q = pacedQueue(s, 10);
    if (q.isEmpty) {
      // close to the exam, or nothing due: the most valuable cards not known yet, each until right twice
      q = plan(s, 10).master;
      custom = SprintSession(q, s);
    }
  }
  if (!context.mounted) return;
  if (q.isEmpty) return easyMessage(context, Icons.emoji_events_rounded, t('You know all of these for now!'), t('Come back tomorrow, or try a practice test.'));
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => StudyScreen(q,
              easy: true,
              title: a['title'] ?? '',
              source: kind == 'morning' ? 'cram' : 'study',
              custom: custom,
              scheduler: s.scheduler,
              onMore: kind == 'morning' ? null : () => easyStudy(context, a))));
}

/// A practice test with fixed settings: 10 questions from the cards (no AI, works offline), feedback per question,
/// a score per topic at the end.
Future<void> easyPractice(BuildContext context, Json a) async {
  final s = await Scope.load(a);
  final cards = pickPractice(s, await Db.get('profile-${a['course_id']}'), 10)..shuffle();
  if (!context.mounted) return;
  if (cards.isEmpty) return easyMessage(context, Icons.hourglass_empty_rounded, t('Not ready yet.'), t('Prepare this exam first in "My courses".'));
  await Navigator.push(
      context, MaterialPageRoute(builder: (_) => StudyScreen(cards, easy: true, practice: true, title: t('Practice test'), source: 'exam', scheduler: s.scheduler)));
}

/// The summary in large text, then a quick review.
class NightBefore extends StatelessWidget {
  final Json a;
  const NightBefore(this.a, {super.key});

  @override
  Widget build(BuildContext context) => easyScale(
        context,
        Scaffold(
          appBar: AppBar(title: Text(t('Night before'))),
          body: FutureBuilder(
            future: Future.wait([Db.get('sheet-${a['id']}-night'), Db.get('sheet-${a['id']}-summary')]),
            builder: (context, snap) {
              final sheet = snap.data?.firstWhere((s) => s != null, orElse: () => null);
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text(t('Read this once, do a quick review, then get some sleep. Sleep helps you remember.'), style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 16),
                FilledButton.icon(
                    style: easyButton(),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(t('Quick review')),
                    onPressed: () => easyStudy(context, a, kind: 'night')),
                const SizedBox(height: 20),
                if (sheet != null) Md(sheet['content'] ?? ''),
              ]);
            },
          ),
        ),
      );
}

Future<void> easyMessage(BuildContext context, IconData icon, String title, String body) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
          icon: Icon(icon, size: 40, color: Colors.amber),
          title: Text(title, textAlign: TextAlign.center),
          content: Text(body, textAlign: TextAlign.center),
          actions: [FilledButton(style: easyButton(), onPressed: () => Navigator.pop(c), child: Text(t('OK')))],
        ));

// ---------------- help ----------------

List<(IconData, String)> get homeHelp => [
      (Icons.play_arrow_rounded, t('Tap "Study now". The app picks the questions for you. About 10 minutes.')),
      (Icons.trending_up_rounded, t('Each exam shows how much you have learned, in cards and percent.')),
      (Icons.replay_rounded, t('Wrong answers come back later, so you learn them.')),
      (Icons.assignment_turned_in_outlined, t('Try a practice test to see how ready you are.')),
    ];

List<(IconData, String)> get studyHelp => [
      (Icons.touch_app_rounded, t('Choose or write your answer, then tap how sure you are: that also shows the answer.')),
      (Icons.help_outline_rounded, t('Not sure? Make your best guess and tap Guessing. That is how you learn.')),
      (Icons.thumb_up_alt_rounded, t('If the app asks "Did you get it?", compare with the answer and be honest.')),
    ];

Widget helpButton(BuildContext context, List<(IconData, String)> items) => TextButton.icon(
    style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
    onPressed: () => showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(t('How it works')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final (icon, text) in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(icon, size: 26, color: Colors.amber),
                      const SizedBox(width: 12),
                      Expanded(child: Text(text)),
                    ]),
                  ),
              ]),
              actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('OK')))],
            )),
    icon: const Icon(Icons.help_outline_rounded),
    label: Text(t('Help')));

/// Three screens on the first open, skippable.
class EasyIntro extends StatefulWidget {
  const EasyIntro({super.key});
  @override
  State<EasyIntro> createState() => _KidIntroState();
}

class _KidIntroState extends State<EasyIntro> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      (Icons.school_rounded, t('Welcome!'), t('This app helps you get ready for your exams.')),
      (Icons.play_circle_fill_rounded, t('Tap "Study now"'), t('The app picks the questions. About 10 minutes is enough.')),
      (Icons.trending_up_rounded, t('Watch your progress'), t('Each exam shows how much you have learned. Wrong answers come back later, so you learn them.')),
    ];
    final (icon, title, body) = pages[page];
    final last = page == pages.length - 1;
    return easyScale(
      context,
      Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Skip')))),
              const Spacer(),
              Icon(icon, size: 88, color: Colors.amber),
              const SizedBox(height: 24),
              Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(body, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
              const Spacer(),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < pages.length; i++)
                  Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.all(6),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: i == page ? Colors.amber : Colors.white24)),
              ]),
              const SizedBox(height: 16),
              FilledButton(
                  style: easyButton(),
                  onPressed: () => last ? Navigator.pop(context, true) : setState(() => page++),
                  child: Text(last ? t('Let\'s go!') : t('Next'))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------- the student's own setup ----------------

/// The setup screens as they were: College (courses, material, exams, preparing) and Settings.
class ManageScreen extends StatefulWidget {
  const ManageScreen({super.key});
  @override
  State<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends State<ManageScreen> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: tab, children: const [CollegeScreen(), SettingsScreen()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => tab = i);
          },
          destinations: [
            NavigationDestination(icon: const Icon(Icons.school_outlined), selectedIcon: const Icon(Icons.school), label: t('My courses')),
            NavigationDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: t('Settings')),
          ],
        ),
      );
}

// ---------------- sign in ----------------

/// The first screen on a new phone: a short code instead of a server token.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final code = TextEditingController();
  String? error;
  bool working = false;

  Future<void> _go() async {
    setState(() {
      working = true;
      error = null;
    });
    final err = await Api.redeem(code.text);
    if (!mounted) return;
    if (err == null) return Navigator.of(context).popUntil((r) => r.isFirst); // opened from Settings or the PIN: back to the new home
    setState(() {
      working = false;
      error = t(err);
    });
  }

  @override
  Widget build(BuildContext context) => easyScale(
        context,
        Scaffold(
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
              const SizedBox(height: 40),
              Icon(Icons.school_rounded, size: 72, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(t('Welcome!'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(t('Type the sign-in code you were given.'), style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              TextField(
                controller: code,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 22, letterSpacing: 4, fontWeight: FontWeight.bold),
                decoration: InputDecoration(hintText: 'ABCD 2345', border: const OutlineInputBorder(), errorText: error, errorMaxLines: 3),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                  style: easyButton(),
                  onPressed: working ? null : _go,
                  child: working ? const CircularProgressIndicator() : Text(t('Start'))),
              const SizedBox(height: 40),
              TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                  child: Text(t('I have a server token'), style: const TextStyle(color: Colors.white54))),
            ]),
          ),
        ),
      );
}

/// "material/section" -> section title, for naming a practice test's topics.
Future<Map<String, String>> sectionTitles() async => {
      for (final i in await Db.query('ingest'))
        for (final s in ((i['structure'] as List?) ?? []).cast<Map>()) '${i['material_id']}/${s['id']}': '${s['title']}',
    };
