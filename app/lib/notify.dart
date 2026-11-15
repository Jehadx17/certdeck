import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'college_logic.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';

/// On-device study reminders (no push server): one notification per day for the next week with that day's plan
/// ("Quiz 2 in 3 days: 25 min today"), more urgent when you're behind, plus the night-before and exam-morning
/// nudges. Re-planned on every app open and after every session, so they reflect what's actually left.
class Reminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// The hour the student actually studies (from their reviews), used until they pick a time themselves.
  static int? _learnedMinute;

  static TimeOfDay get time {
    final m = (App.settings['reminder_minute'] as int?) ?? _learnedMinute ?? 18 * 60;
    return TimeOfDay(hour: m ~/ 60, minute: m % 60);
  }

  /// The most common hour of day among the last 30 days' reviews (at least 20 of them), as minutes after midnight.
  static Future<int?> _studyHour() async {
    final hours = <int, int>{};
    for (final r in await Db.reviewsSince(nowMs() - 30 * dayMs)) {
      final h = DateTime.fromMillisecondsSinceEpoch(r['ts'] as int).hour;
      hours[h] = (hours[h] ?? 0) + 1;
    }
    if (hours.values.fold(0, (a, b) => a + b) < 20) return null;
    return hours.entries.reduce((a, b) => b.value > a.value ? b : a).key * 60;
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
      items.add(!App.isOwner
          ? (d == 0 ? t('{a} is today. A quick warm-up before you go!', {'a': p.assessment['title']}) : easyLine(p.assessment['title'], d))
          : d == 0
              ? t('{c} {a} today: 10-minute morning check', {'c': p.course, 'a': p.assessment['title']})
              : t('{c} {a} in {d} days: {m} min today', {'c': p.course, 'a': p.assessment['title'], 'd': d, 'm': p.minutes}));
    }
    if (items.isEmpty) return null;
    if (!App.isOwner) return (t('Time to study!'), items.join('\n')); // students (EASY.md): no "behind", no minutes
    return (behind ? t('You\'re behind: catch up today') : t('Today\'s study plan'), items.join('\n'));
  }

  /// "After dinner, at my desk": the student's own words from the setup, added to the reminder.
  static String _withIntention(String body) {
    final i = (App.settings['intention'] as String?)?.trim() ?? '';
    return i.isEmpty ? body : '$body\n$i';
  }

  /// Cert study (no college plan): one line a day with the time the session takes.
  static Future<void> _certReminders() async {
    if (!App.isOwner) return;
    final (queue, st) = await buildQueue(App.cert);
    if (queue.isEmpty && st.due == 0) return;
    final now = DateTime.now();
    final body = _withIntention(t('{n} cards due: about {m} min.', {'n': st.due + st.newAvailable, 'm': App.sessionMinutes}));
    await _askPermission();
    for (var day = 0; day < 7; day++) {
      final at = DateTime(now.year, now.month, now.day + day, time.hour, time.minute);
      if (at.isBefore(now)) continue;
      await _plugin.zonedSchedule(200 + day, t('Time to study'), body, tz.TZDateTime.from(at.toUtc(), tz.UTC), _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
    }
  }

  static Future<void> reschedule() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _init();
      await _plugin.cancelAll();
      if (App.settings['reminders'] == false) return;
      _learnedMinute = await _studyHour();
      final plan = App.isOwner ? <PlanItem>[] : await todayPlan(); // the owner has no college plan
      if (plan.isEmpty) return await _certReminders();
      await _askPermission();
      final now = DateTime.now();
      for (var day = 0; day < 7; day++) {
        final msg = await _message(plan, day);
        if (msg == null) continue;
        var at = DateTime(now.year, now.month, now.day + day, time.hour, time.minute);
        if (at.isBefore(now)) continue;
        await _plugin.zonedSchedule(day, msg.$1, _withIntention(msg.$2), tz.TZDateTime.from(at.toUtc(), tz.UTC), _details,
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
          (0, eve, t('{a} tomorrow', {'a': p.assessment['title']}),
              App.isOwner ? t('Read your night-before sheet, then sleep. Sleep is when it sticks.') : t('Do the night-before review, then get some sleep.')),
          (1, morning, t('{a} today', {'a': p.assessment['title']}),
              App.isOwner ? t('10-minute morning check: your weakest points, nothing new.') : t('A quick warm-up before you go. You can do it!')),
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

/// A student's daily reminder line (EASY.md wording): "Science quiz in 3 days. 10 minutes of practice today!"
String easyLine(String? title, int days) => days == 1
    ? t('{a} is tomorrow. Do the night-before review tonight.', {'a': title ?? ''})
    : t('{a} in {d} days. {m} minutes of practice today!', {'a': title ?? '', 'd': days, 'm': App.sessionMinutes});
