import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api.dart';
import 'db.dart';
import 'home.dart';
import 'library.dart';
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

final _scheme = ColorScheme.fromSeed(seedColor: const Color(0xff2dd4bf), brightness: Brightness.dark, surface: const Color(0xff111316));

ThemeData studentTheme() => ThemeData(
      colorScheme: _scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: _scheme.surface,
      cardTheme: CardTheme(color: _scheme.surfaceContainerLow, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      appBarTheme: AppBarTheme(backgroundColor: _scheme.surface, scrolledUnderElevation: 0),
    );

// Owner-only refinement: rounder, tone-separated surfaces.
ThemeData ownerTheme() {
  final s = _scheme;
  final btn = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const pad = EdgeInsets.symmetric(vertical: 14, horizontal: 20);
  return ThemeData(
    colorScheme: s,
    useMaterial3: true,
    scaffoldBackgroundColor: s.surface,
    cardTheme: CardTheme(color: s.surfaceContainerLow, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: btn, padding: pad)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: btn, padding: pad)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: s.surface,
      indicatorColor: s.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    chipTheme: const ChipThemeData(shape: StadiumBorder(), side: BorderSide.none),
    appBarTheme: AppBarTheme(backgroundColor: s.surface, scrolledUnderElevation: 0, centerTitle: false),
  );
}

class CertDeck extends StatelessWidget {
  const CertDeck({super.key});

  @override
  Widget build(BuildContext context) {
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
      darkTheme: App.isOwner ? ownerTheme() : studentTheme(),
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
  int get tab => ownerTab.value;
  set tab(int v) => ownerTab.value = v;

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
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([changes, ownerTab]), builder: (context, _) => _body(context)); // sign-in and role changes rebuild the home

  Widget _body(BuildContext context) {
    if (!Api.configured) return const WelcomeScreen(); // a new phone: sign in with a short code
    if (!App.isOwner) return const EasyHome(); // students: the easy app; their setup screens are under "My courses" (EASY.md)
    final tabs = [
      (const TodayScreen(), Icons.home_outlined, Icons.home, t('Today')),
      (const LibraryScreen(), Icons.style_outlined, Icons.style, t('Library')),
      (const SettingsScreen(), Icons.person_outline, Icons.person, t('Me')),
    ];
    final i = tab.clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(index: i, children: [for (final t in tabs) t.$1]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) {
          FocusManager.instance.primaryFocus?.unfocus(); // a focused field on a hidden tab would keep the keyboard up
          setState(() => tab = i);
        },
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), selectedIcon: Icon(t.$3), label: t.$4)],
      ),
    );
  }
}
