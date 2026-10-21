import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ai.dart';
import 'api.dart';
import 'cards.dart';
import 'college.dart';
import 'db.dart';
import 'exam.dart';
import 'home.dart';
import 'i18n.dart';
import 'easy.dart';
import 'logic.dart';
import 'notify.dart';
import 'settings.dart';
import 'update.dart';
import 'upload.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Db.open();
  await App.init();
  await Api.load();
  runApp(const CertDeck());
  Api.sync().then((_) => Reminders.reschedule()).ignore(); // sync on open, then plan the reminders
  Uploads.run().ignore(); // resume unfinished material uploads
  Updater.check().ignore();
}

class CertDeck extends StatelessWidget {
  const CertDeck({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff2dd4bf), brightness: Brightness.dark, surface: const Color(0xff111316));
    // Rebuilds on settings changes so a language switch applies at once (Arabic = right-to-left everywhere).
    return ValueListenableBuilder(
      valueListenable: changes,
      builder: (_, __, ___) => MaterialApp(
      title: 'CertDeck',
      debugShowCheckedModeBanner: false,
      locale: Locale(App.lang),
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        cardTheme: CardTheme(color: scheme.surfaceContainerLow, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 0),
      ),
      // Keyed by language and role: switching either rebuilds every screen (strings, direction, which tabs).
      home: UpdateGate(key: ValueKey('${App.lang}/${App.role}'), child: const Shell()),
    ));
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Api.sync().ignore();
      Uploads.run().ignore();
      Updater.check().ignore();
    }
    if (state == AppLifecycleState.paused) Reminders.reschedule().ignore(); // after a session, the plan changed
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(valueListenable: changes, builder: (context, _, __) => _body(context)); // sign-in and role changes rebuild the home

  Widget _body(BuildContext context) {
    if (!Api.configured) return const WelcomeScreen(); // a new phone: sign in with a short code
    if (!App.isOwner) return const EasyHome(); // students: the easy app; their setup screens are under "My courses" (EASY.md)
    // The owner keeps the cert tabs.
    final tabs = [
      if (App.isOwner) (const TodayScreen(), Icons.today_outlined, Icons.today, 'Certs'),
      (const CollegeScreen(), Icons.school_outlined, Icons.school, t('College')),
      if (App.isOwner) (const CardsScreen(), Icons.style_outlined, Icons.style, t('Cards')), // students open cards per course
      if (App.isOwner) (const AiScreen(), Icons.auto_awesome_outlined, Icons.auto_awesome, 'AI'),
      if (App.isOwner) (const ExamScreen(), Icons.timer_outlined, Icons.timer, 'Exam'),
      (const SettingsScreen(), Icons.settings_outlined, Icons.settings, t('Settings')),
    ];
    final i = tab.clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(index: i, children: [for (final t in tabs) t.$1]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        onDestinationSelected: (i) {
          FocusManager.instance.primaryFocus?.unfocus(); // a focused field on a hidden tab would keep the keyboard up
          setState(() => tab = i);
        },
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), selectedIcon: Icon(t.$3), label: t.$4)],
      ),
    );
  }
}
