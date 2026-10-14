import 'dart:convert';

import 'package:crypto/crypto.dart';
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

/// The student's app (EASY.md): one big button per exam and nothing a child has to work out. The setup screens
/// (courses, material, scope, settings) sit behind a parent PIN.

const kidButtonHeight = 64.0;

ButtonStyle kidButton([Color? color]) => FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(kidButtonHeight),
    backgroundColor: color,
    textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)));

/// 0..5 stars for a 0..1 share.
int starsFor(double share) => (share.clamp(0, 1) * 5).round();

Widget stars(int n, {double size = 28, int of = 5}) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < of; i++) Icon(i < n ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: Colors.amber),
    ]);

/// A child isn't asked how sure they are: a quick right answer counts as sure, anything else as unsure
/// (so a wrong answer is never a "misconception" for them).
Conf kidConf(bool correct, int durationMs) => correct && durationMs < 15000 ? Conf.sure : Conf.unsure;

/// What a session ends with: 1..3 stars from the share of right answers.
int sessionStars(int right, int done) => done == 0 ? 0 : (right / done >= .8 ? 3 : (right / done >= .5 ? 2 : 1));

/// Larger text everywhere on the child's screens (still follows the phone's own font size).
Widget kidScale(BuildContext context, Widget child) {
  final mq = MediaQuery.of(context);
  return MediaQuery(data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * 1.15)), child: child);
}

class _Exam {
  final Json a;
  final String course;
  final Scope s;
  _Exam(this.a, this.course, this.s);
  int? get days => s.days;
  double get done => s.cards.isEmpty ? 0 : s.cards.where(s.mastered).length / s.cards.length;
}

class KidHome extends StatefulWidget {
  const KidHome({super.key});
  @override
  State<KidHome> createState() => _KidHomeState();
}

class _KidHomeState extends State<KidHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await Db.meta('kid_intro_done') == null && mounted) {
        await Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => const KidIntro()));
        await Db.setMeta('kid_intro_done', '1');
      }
    });
  }

  Future<List<_Exam>> _load() async {
    final out = <_Exam>[];
    for (final a in await upcoming()) {
      final s = await Scope.load(a);
      if (s.cards.isEmpty) continue; // not prepared yet: nothing a child can do with it
      out.add(_Exam(a, (await Db.get(a['course_id']))?['name'] ?? '', s));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => kidScale(
        context,
        Scaffold(
          appBar: AppBar(
            title: Text(t('My study'), style: const TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              helpButton(context, homeHelp),
              TextButton.icon(onPressed: () => openParentArea(context), icon: const Icon(Icons.lock_outline, size: 18), label: Text(t('Parents'))),
            ],
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

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_rounded, size: 96, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t('Nothing to study yet.'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(t('Ask a parent or teacher to add your lessons.'), style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
          ]),
        ),
      );
}

String kidWhen(int? d) => d == null
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
          autoText(e.course, style: TextStyle(fontSize: 18, color: cs.primary)),
          autoText(e.a['title'] ?? '', style: TextStyle(fontSize: big ? 28 : 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(kidWhen(d), style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 12),
          Row(children: [
            stars(starsFor(e.done), size: big ? 32 : 26),
            const SizedBox(width: 8),
            Expanded(child: Text(t('stars fill up as you learn'), style: const TextStyle(fontSize: 14, color: Colors.white60))),
          ]),
          const SizedBox(height: 16),
          if (d == 0)
            FilledButton.icon(
                style: kidButton(Colors.orange),
                icon: const Icon(Icons.wb_sunny_rounded, size: 30),
                label: Text(t('Exam morning warm-up')),
                onPressed: () => kidStudy(context, e.a, kind: 'morning'))
          else if (d == 1)
            FilledButton.icon(
                style: kidButton(Colors.indigo),
                icon: const Icon(Icons.nightlight_round, size: 30),
                label: Text(t('Night before')),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NightBefore(e.a)))),
          if (d != null && d <= 1) const SizedBox(height: 10),
          FilledButton.icon(
              style: kidButton(),
              icon: const Icon(Icons.play_arrow_rounded, size: 36),
              label: Text(t('Study')),
              onPressed: () => kidStudy(context, e.a)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), textStyle: const TextStyle(fontSize: 18)),
              icon: const Icon(Icons.assignment_turned_in_outlined),
              label: Text(t('Try a practice test')),
              onPressed: () => kidPractice(context, e.a)),
        ]),
      ),
    );
  }
}

/// One tap: about 10 minutes, the app picks the cards (most marks first when the exam is close).
Future<void> kidStudy(BuildContext context, Json a, {String kind = 'study'}) async {
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
  if (q.isEmpty) return kidMessage(context, Icons.emoji_events_rounded, t('You know all of these for now!'), t('Come back tomorrow, or try a practice test.'));
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => StudyScreen(q,
              kid: true,
              title: a['title'] ?? '',
              source: kind == 'morning' ? 'cram' : 'study',
              custom: custom,
              scheduler: s.scheduler,
              onMore: kind == 'morning' ? null : () => kidStudy(context, a))));
}

/// A practice test with fixed settings: 10 questions from the cards (no AI, works offline), feedback per question,
/// stars per topic at the end.
Future<void> kidPractice(BuildContext context, Json a) async {
  final s = await Scope.load(a);
  final cards = pickPractice(s, await Db.get('profile-${a['course_id']}'), 10)..shuffle();
  if (!context.mounted) return;
  if (cards.isEmpty) return kidMessage(context, Icons.hourglass_empty_rounded, t('Not ready yet.'), t('Ask a parent or teacher to prepare this exam.'));
  await Navigator.push(
      context, MaterialPageRoute(builder: (_) => StudyScreen(cards, kid: true, practice: true, title: t('Practice test'), source: 'exam', scheduler: s.scheduler)));
}

/// The summary in large text, then a short game.
class NightBefore extends StatelessWidget {
  final Json a;
  const NightBefore(this.a, {super.key});

  @override
  Widget build(BuildContext context) => kidScale(
        context,
        Scaffold(
          appBar: AppBar(title: Text(t('Night before'))),
          body: FutureBuilder(
            future: Future.wait([Db.get('sheet-${a['id']}-night'), Db.get('sheet-${a['id']}-summary')]),
            builder: (context, snap) {
              final sheet = snap.data?.firstWhere((s) => s != null, orElse: () => null);
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text(t('Read this once, play a short game, then sleep well. Sleep helps you remember.'), style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 16),
                FilledButton.icon(
                    style: kidButton(),
                    icon: const Icon(Icons.play_arrow_rounded, size: 36),
                    label: Text(t('Play a short game')),
                    onPressed: () => kidStudy(context, a, kind: 'night')),
                const SizedBox(height: 20),
                if (sheet != null) Md(sheet['content'] ?? '', style: const TextStyle(fontSize: 18, height: 1.5)),
              ]);
            },
          ),
        ),
      );
}

Future<void> kidMessage(BuildContext context, IconData icon, String title, String body) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
          icon: Icon(icon, size: 56, color: Colors.amber),
          title: Text(title, textAlign: TextAlign.center),
          content: Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          actions: [FilledButton(style: kidButton(), onPressed: () => Navigator.pop(c), child: Text(t('OK')))],
        ));

// ---------------- help ----------------

List<(IconData, String)> get homeHelp => [
      (Icons.play_arrow_rounded, t('Tap Study. The app picks the questions for you. About 10 minutes.')),
      (Icons.star_rounded, t('Right answers fill your stars.')),
      (Icons.replay_rounded, t('Wrong answers come back later, so you learn them.')),
      (Icons.assignment_turned_in_outlined, t('Try a practice test to see how ready you are.')),
    ];

List<(IconData, String)> get studyHelp => [
      (Icons.touch_app_rounded, t('Choose or write your answer, then tap Check.')),
      (Icons.help_outline_rounded, t('Not sure? Make your best guess. That is how you learn.')),
      (Icons.thumb_up_alt_rounded, t('If the app asks "Did you get it?", compare with the answer and be honest.')),
    ];

Widget helpButton(BuildContext context, List<(IconData, String)> items) => TextButton.icon(
    onPressed: () => showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(t('How it works')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final (icon, text) in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(icon, size: 36, color: Colors.amber),
                      const SizedBox(width: 12),
                      Expanded(child: Text(text, style: const TextStyle(fontSize: 18))),
                    ]),
                  ),
              ]),
              actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('OK')))],
            )),
    icon: const Icon(Icons.help_outline_rounded),
    label: Text(t('Help')));

/// Three screens on the first open, skippable.
class KidIntro extends StatefulWidget {
  const KidIntro({super.key});
  @override
  State<KidIntro> createState() => _KidIntroState();
}

class _KidIntroState extends State<KidIntro> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      (Icons.school_rounded, t('Hello!'), t('This app helps you get ready for your exams.')),
      (Icons.play_circle_fill_rounded, t('Tap Study'), t('The app picks the questions. About 10 minutes is enough.')),
      (Icons.star_rounded, t('Collect stars'), t('Right answers fill your stars. Wrong ones come back later, so you learn them.')),
    ];
    final (icon, title, body) = pages[page];
    final last = page == pages.length - 1;
    return kidScale(
      context,
      Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Skip'), style: const TextStyle(fontSize: 18)))),
              const Spacer(),
              Icon(icon, size: 140, color: Colors.amber),
              const SizedBox(height: 24),
              Text(title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(body, style: const TextStyle(fontSize: 20), textAlign: TextAlign.center),
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
                  style: kidButton(),
                  onPressed: () => last ? Navigator.pop(context) : setState(() => page++),
                  child: Text(last ? t('Let\'s go!') : t('Next'))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------- parents ----------------

String _pinHash(String pin) => sha256.convert(utf8.encode('certdeck-parent-pin:$pin')).toString();

/// The setup screens (courses, material, exams, settings) behind a 4-digit PIN chosen on first use.
Future<void> openParentArea(BuildContext context) async {
  final saved = await Db.meta('parent_pin');
  if (!context.mounted) return;
  final r = await showDialog<Object>(context: context, builder: (_) => _PinDialog(saved));
  if (!context.mounted) return;
  // A new sign-in code resets the PIN (signing in wipes and restores this phone's copy).
  final page = r == true ? const ParentArea() : (r == 'forgot' ? const WelcomeScreen() : null);
  if (page != null) await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

class _PinDialog extends StatefulWidget {
  final String? saved;
  const _PinDialog(this.saved);
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final pin = TextEditingController();
  String? first, error;

  Future<void> _submit() async {
    final p = pin.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(p)) return setState(() => error = t('4 digits, please'));
    if (widget.saved != null) {
      if (_pinHash(p) == widget.saved) return Navigator.pop(context, true);
      return setState(() {
        error = t('Wrong PIN');
        pin.clear();
      });
    }
    if (first == null) {
      return setState(() {
        first = p;
        error = null;
        pin.clear();
      });
    }
    if (p != first) {
      return setState(() {
        first = null;
        error = t('The two PINs were different. Start again.');
        pin.clear();
      });
    }
    await Db.setMeta('parent_pin', _pinHash(p));
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.saved != null
            ? t('Parent PIN')
            : first == null
                ? t('Choose a 4-digit parent PIN')
                : t('Type the PIN again')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.saved == null && first == null)
            Text(t('Only for parents and teachers: it keeps the setup screens away from the child.'), style: const TextStyle(fontSize: 14)),
          TextField(
            controller: pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 12),
            onSubmitted: (_) => _submit(),
          ),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (widget.saved != null)
            TextButton(
                onPressed: () => Navigator.pop(context, 'forgot'),
                child: Text(t('Forgot it? Sign in again with a new code: nothing is lost.'), style: const TextStyle(fontSize: 12))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
          FilledButton(onPressed: _submit, child: Text(t('OK'))),
        ],
      );
}

/// The student setup as it was: College (courses, material, exams) and Settings.
class ParentArea extends StatefulWidget {
  const ParentArea({super.key});
  @override
  State<ParentArea> createState() => _ParentAreaState();
}

class _ParentAreaState extends State<ParentArea> {
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
            NavigationDestination(icon: const Icon(Icons.school_outlined), selectedIcon: const Icon(Icons.school), label: t('Setup')),
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
  Widget build(BuildContext context) => kidScale(
        context,
        Scaffold(
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
              const SizedBox(height: 40),
              Icon(Icons.school_rounded, size: 110, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(t('Welcome!'), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(t('Type the code your parent or teacher gave you.'), style: const TextStyle(fontSize: 20), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              TextField(
                controller: code,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 30, letterSpacing: 6, fontWeight: FontWeight.bold),
                decoration: InputDecoration(hintText: 'ABCD 2345', border: const OutlineInputBorder(), errorText: error, errorMaxLines: 3),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                  style: kidButton(),
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
