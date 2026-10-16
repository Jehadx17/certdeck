import 'dart:io';

import 'package:darb/api.dart';
import 'package:darb/billing.dart';
import 'package:darb/db.dart';
import 'package:darb/help.dart';
import 'package:darb/logic.dart';
import 'package:darb/main.dart';
import 'package:darb/settings.dart';
import 'package:darb/weighted.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Every main screen in Arabic and English, light and dark, on the device it runs on (CI: the oldest iOS simulator
/// runtime at iPhone SE size and a large iPhone; the Android 7.0 emulator). Fails on any layout overflow or exception;
/// screenshots go to build/walkthrough/. No server: run with --dart-define=DARB_API=http://127.0.0.1:9 (offline).
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const device = String.fromEnvironment('DEVICE', defaultValue: 'device');

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    await binding.takeScreenshot('$device-${App.lang}-${App.settings['theme']}-$name');
  }

  Future<void> start(WidgetTester tester, String lang, String theme, {bool signedIn = true, String? segment}) async {
    await App.init();
    App.settings
      ..['lang'] = lang
      ..['theme'] = theme;
    if (segment != null) {
      App.settings
        ..['segment'] = segment
        ..['grade'] = {'middle': 'm3', 'high': 'general', 'university': 'y1', 'cert': 'step'}[segment]
        ..['exam'] = {'middle': 'school', 'high': 'qudurat', 'university': 'course', 'cert': 'cert'}[segment];
    }
    Api.token = signedIn ? 'walkthrough' : null;
    Api.me.value = signedIn ? {'id': 'walkthrough', 'email': 'student@example.com', 'guardian': 'not_needed', 'premium': false} : null;
    await tester.pumpWidget(Darb(key: UniqueKey()));
  }

  Future<void> open(WidgetTester tester, Widget screen, String name) async {
    final nav = Navigator.of(tester.element(find.byType(Shell))); // before the push: Shell is offstage after it
    nav.push(MaterialPageRoute(builder: (_) => screen));
    await shot(tester, name);
    nav.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('walkthrough', (tester) async {
    await Db.open();
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage(); // Android needs this once for screenshots
    for (final lang in ['ar', 'en']) {
      for (final theme in ['light', 'dark']) {
        await start(tester, lang, theme, signedIn: false);
        await shot(tester, '1-signin');
        await start(tester, lang, theme);
        await shot(tester, '2-onboarding');
        for (final seg in ['middle', 'high', 'university', 'cert']) {
          await start(tester, lang, theme, segment: seg);
          await shot(tester, '3-home-$seg');
        }
        await open(tester, const SettingsScreen(), '4-settings');
        await open(tester, const PaywallScreen(), '5-paywall');
        await open(tester, const WeightedScreen(), '6-weighted');
        await open(tester, const HelpScreen(), '7-help');
      }
    }
  });
}
