import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'college_logic.dart';
import 'i18n.dart';
import 'logic.dart';

/// On-device study reminders (no push server): one notification per day for the next week with that day's plan
/// ("Quiz 2 in 3 days: 25 min today"), more urgent when you're behind, plus the night-before and exam-morning
/// nudges. Re-planned on every app open and after every session, so they reflect what's actually left.
class Reminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static TimeOfDay get time {
    final m = (App.settings['reminder_minute'] as int?) ?? 18 * 60;
    return TimeOfDay(hour: m ~/ 60, minute: m % 60);
  }

  static String get timeLabel => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
    ));
    _ready = true;
  }

  static Future<void> _askPermission() async {
    if (Platform.isAndroid) {
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);
    }
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails('study', 'Study plan', channelDescription: 'Daily study reminders for your quizzes and exams'),
    iOS: DarwinNotificationDetails(),
  );

  /// What the reminder says [daysAhead] days from now, assuming nothing gets studied before then.
  static Future<(String, String)?> _message(List<PlanItem> plan, int daysAhead) async {
    final items = <String>[];
    var behind = false;
    for (final p in plan) {
      final d = (daysUntil(p.assessment['date']) ?? 99) - daysAhead;
      if (d < 0) continue;
      behind |= p.behind && daysAhead == 0;
      items.add(d == 0
          ? t('{c} {a} today: 10-minute morning check', {'c': p.course, 'a': p.assessment['title']})
          : t('{c} {a} in {d} days: {m} min today', {'c': p.course, 'a': p.assessment['title'], 'd': d, 'm': p.minutes}));
    }
    if (items.isEmpty) return null;
    return (behind ? t('You\'re behind: catch up today') : t('Today\'s study plan'), items.join('\n'));
  }

  static Future<void> reschedule() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _init();
      await _plugin.cancelAll();
      if (App.settings['reminders'] == false) return;
      final plan = await todayPlan();
      if (plan.isEmpty) return;
      await _askPermission();
      final now = DateTime.now();
      for (var day = 0; day < 7; day++) {
        final msg = await _message(plan, day);
        if (msg == null) continue;
        var at = DateTime(now.year, now.month, now.day + day, time.hour, time.minute);
        if (at.isBefore(now)) continue;
        await _plugin.zonedSchedule(day, msg.$1, msg.$2, tz.TZDateTime.from(at.toUtc(), tz.UTC), _details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
      }
      // The evening before an exam and the morning of it.
      for (final (i, p) in plan.indexed) {
        final d = daysUntil(p.assessment['date']);
        if (d == null) continue;
        final date = DateTime(now.year, now.month, now.day + d);
        final eve = date.subtract(const Duration(hours: 3)); // 21:00 the day before
        final morning = date.add(const Duration(hours: 7, minutes: 30));
        for (final (j, at, title, body) in [
          (0, eve, t('{a} tomorrow', {'a': p.assessment['title']}), t('Read your night-before sheet, then sleep. Sleep is when it sticks.')),
          (1, morning, t('{a} today', {'a': p.assessment['title']}), t('10-minute morning check: your weakest points, nothing new.')),
        ]) {
          if (at.isAfter(now)) {
            await _plugin.zonedSchedule(100 + i * 2 + j, title, body, tz.TZDateTime.from(at.toUtc(), tz.UTC), _details,
                androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
                uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
          }
        }
      }
    } catch (_) {
      // Reminders are a nudge; never let them break studying.
    }
  }
}
