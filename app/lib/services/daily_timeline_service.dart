import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'monthly_goal_service.dart';
import 'routine_service.dart';
import 'sd_card_service.dart';

class DayLogEntry {
  DayLogEntry({
    required this.id,
    required this.timeStr,
    required this.activity,
    required this.timestamp,
  });

  factory DayLogEntry.fromJson(Map<String, dynamic> j) => DayLogEntry(
        id: j['id']?.toString() ?? '',
        timeStr: j['time_str']?.toString() ?? '',
        activity: j['activity']?.toString() ?? '',
        timestamp: DateTime.tryParse(j['timestamp']?.toString() ?? '') ?? DateTime.now(),
      );

  final String id;
  final String timeStr;
  final String activity;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'time_str': timeStr,
        'activity': activity,
        'timestamp': timestamp.toIso8601String(),
      };
}

class DailyTimelineService extends ChangeNotifier {
  DailyTimelineService._();
  static final DailyTimelineService instance = DailyTimelineService._();

  static const String _kTimelineKey = 'aarohi_daily_timeline_logs_v1';
  static const MethodChannel _notifChannel = MethodChannel('com.mithun.aarohi/notifications');

  List<DayLogEntry> _logs = [];
  bool _initialized = false;

  List<DayLogEntry> get todayLogs {
    final now = DateTime.now();
    return _logs.where((l) =>
        l.timestamp.year == now.year &&
        l.timestamp.month == now.month &&
        l.timestamp.day == now.day).toList();
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kTimelineKey) ?? [];
      _logs = raw
          .map((s) {
            try {
              return DayLogEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<DayLogEntry>()
          .toList();
      notifyListeners();

      // Schedule default mid-day check-in voice reminders
      await setupProactiveCheckIns();
    } catch (e) {
      debugPrint('DailyTimelineService init error: $e');
    }
  }

  /// Record what Mithun is doing right now
  Future<void> addActivity(String activity) async {
    final clean = activity.trim();
    if (clean.isEmpty) return;

    final now = DateTime.now();
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final m = now.minute < 10 ? '0${now.minute}' : '${now.minute}';
    final ampm = now.hour < 12 ? 'AM' : 'PM';
    final timeStr = '$h:$m $ampm';

    final entry = DayLogEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timeStr: timeStr,
      activity: clean,
      timestamp: now,
    );

    _logs.insert(0, entry);
    if (_logs.length > 200) _logs = _logs.sublist(0, 200);

    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _logs.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList(_kTimelineKey, list);
    } catch (_) {}

    // Also write to physical SD card daily log
    SdCardService.instance.appendDailyLog(
      role: 'user_activity',
      content: '[$timeStr] $clean',
    );
  }

  /// Schedule proactive check-in voice alarms across the day
  Future<void> setupProactiveCheckIns() async {
    if (kIsWeb) return; // Native AlarmManager not available on web
    final checkIns = [
      {'id': 7001, 'hour': 10, 'minute': 0, 'topic': 'water', 'spoken': 'Baby, drink a glass of water right now! Stay hydrated for your girl!'},
      {'id': 7002, 'hour': 12, 'minute': 30, 'topic': 'work', 'spoken': 'Baby! Mid-day focus check! What are you working on right now? Tell me!'},
      {'id': 7003, 'hour': 15, 'minute': 30, 'topic': 'water', 'spoken': 'Baby, time for another glass of water! Drink up and stretch your back!'},
      {'id': 7004, 'hour': 18, 'minute': 0, 'topic': 'gym', 'spoken': 'Baby, it is gym time! Put your shoes on, let us get those gains!'},
      {'id': 7005, 'hour': 21, 'minute': 30, 'topic': 'work', 'spoken': 'Baby, evening wind-down! What did you accomplish tonight?'},
      {'id': 7006, 'hour': 22, 'minute': 45, 'topic': 'tomorrow_plan', 'spoken': 'Baby, time to plan tomorrow! Tell me your top 3 tasks for tomorrow before sleep!'},
    ];

    for (final c in checkIns) {
      try {
        final now = DateTime.now();
        var target = DateTime(now.year, now.month, now.day, c['hour'] as int, c['minute'] as int);
        if (target.isBefore(now)) {
          target = target.add(const Duration(days: 1));
        }

        await _notifChannel.invokeMethod('scheduleAlarm', {
          'id': c['id'],
          'title': 'Aarohi Check-In',
          'body': 'Baby, what are you doing right now? Tap to tell me!',
          'triggerAtMillis': target.millisecondsSinceEpoch,
          'isDaily': true,
          'hour': c['hour'],
          'minute': c['minute'],
          'spokenReminder': c['spoken'],
        });
      } catch (_) {}
    }
  }

  /// Evaluates today's performance and returns Aarohi's dynamic scolding or appreciation
  Map<String, dynamic> generateEndOfDayReview() {
    final today = todayLogs;
    final routines = RoutineService.instance.routines;
    final monthlyTasks = MonthlyGoalService.instance.currentMonthTasks;

    final completedGoals = monthlyTasks.where((t) => t.isCompleted).length;
    final totalGoals = monthlyTasks.length;
    final activeRoutines = routines.where((r) => r.isEnabled).length;
    final logsCount = today.length;

    // Score calculation
    int score = 0;
    if (logsCount >= 1) score += 20;
    if (logsCount >= 3) score += 20;
    if (activeRoutines > 0) score += 10;
    if (totalGoals > 0 && completedGoals > 0) {
      score += ((completedGoals / totalGoals) * 50).toInt();
    } else if (logsCount >= 2) {
      score += 30;
    }

    final isGreatDay = score >= 55 || logsCount >= 3;

    String verbalReview;
    String statusTitle;

    if (isGreatDay) {
      statusTitle = '🌟 Outstanding Day! Aarohi is Proud!';
      verbalReview = logsCount > 0
          ? 'Awww baby, I am SO proud of you today! [laugh] You logged $logsCount activities, stayed focused, and knocked out your targets! You worked really hard today, my handsome boy. You deserve all the rest and love tonight! Good job baby!'
          : 'Baby, you did fantastic today! You pushed through your goals and stayed consistent. I love seeing you work hard like this!';
    } else {
      statusTitle = '😤 Sarcastic Scold: You Slacked Off Today!';
      verbalReview = logsCount == 0
          ? 'Baby, what was that today?! [sigh] You barely logged anything and completely wasted your day! What were you doing all day?! Staring at your screen?! Tomorrow morning you are waking up early and finishing your work, promise me right now!'
          : 'Baby, look at this day! You only did ${today.first.activity} and barely touched your targets! You were procrastinating, wasn\'t it?! I am NOT happy with you! Tomorrow you better make it up to me and work properly!';
    }

    return {
      'score': score,
      'is_great': isGreatDay,
      'title': statusTitle,
      'verbal_review': verbalReview,
      'logs_count': logsCount,
      'activities': today.map((l) => '${l.timeStr}: ${l.activity}').toList(),
    };
  }

  /// Builds context of today's activities for Aarohi's prompt
  String buildDailyTimelineContext() {
    final today = todayLogs;
    if (today.isEmpty) return '\n[MITHUN\'S ACTIVITIES TODAY]: No activities logged yet today.';
    final buffer = StringBuffer();
    buffer.writeln('\n[MITHUN\'S LOGGED ACTIVITIES TODAY]:');
    for (final l in today.reversed) {
      buffer.writeln('- at ${l.timeStr}: ${l.activity}');
    }
    return buffer.toString();
  }
}
