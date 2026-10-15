import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api.dart';
import 'billing.dart';
import 'db.dart';
import 'easy.dart';
import 'guardian.dart';
import 'logic.dart';
import 'notify.dart';
import 'onboarding.dart';
import 'signin.dart';
import 'upload.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Db.open();
  await App.init();
  await Api.load();
  runApp(const Darb());
  // Who am I (guardian state, subscription) first: it decides the first screen even when a sync is refused.
  if (Api.configured) Api.refreshMe().then((_) => Billing.start(Api.me.value!['id'] as String)).catchError((_) {}).whenComplete(() => Api.sync().then((_) => Reminders.reschedule())).ignore();
  Uploads.run().ignore(); // resume unfinished uploads
}

/// Brand colours; every screen reads the theme, never a hard-coded colour, so light and dark both work.
ThemeData darbTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff0f766e), brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamilyFallback: const ['Noto Sans Arabic', 'Roboto'],
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(color: scheme.surfaceContainerLow, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 0),
  );
}

class Darb extends StatelessWidget {
  const Darb({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds on settings changes so a language or theme switch applies at once (Arabic = right-to-left everywhere).
    return ValueListenableBuilder(
      valueListenable: changes,
      builder: (_, __, ___) => MaterialApp(
        title: 'Darb',
        debugShowCheckedModeBanner: false,
        locale: Locale(App.lang),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        themeMode: App.themeMode,
        theme: darbTheme(Brightness.light),
        darkTheme: darbTheme(Brightness.dark),
        // Keyed by language: switching rebuilds every screen (strings and direction).
        home: Shell(key: ValueKey(App.lang)),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
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
    }
    if (state == AppLifecycleState.paused) Reminders.reschedule().ignore(); // after a session, the plan changed
  }

  /// Sign in → (under 18) the guardian's OK → onboarding → home.
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Api.me,
        builder: (_, me, __) {
          if (!Api.configured) return const WelcomeScreen();
          if (me?['guardian'] == 'pending') return const GuardianScreen();
          if (!onboarded) return const OnboardingScreen();
          return const EasyHome();
        },
      );
}
