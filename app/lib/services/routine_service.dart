import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sd_card_service.dart';

class DailyRoutine {
  DailyRoutine({
    required this.id,
    required this.title,
    required this.description,
    required this.hour,
    required this.minute,
    this.isEnabled = true,
    this.isDaily = true,
    this.iconCode = 0xe6e1, // default Icons.alarm
  });

  factory DailyRoutine.fromJson(Map<String, dynamic> j) => DailyRoutine(
        id: j['id'] as int? ?? (DateTime.now().millisecondsSinceEpoch % 100000),
        title: j['title'] as String? ?? 'Daily Routine',
        description: j['description'] as String? ?? '',
        hour: j['hour'] as int? ?? 8,
        minute: j['minute'] as int? ?? 0,
        isEnabled: j['is_enabled'] as bool? ?? true,
        isDaily: j['is_daily'] as bool? ?? true,
        iconCode: j['icon_code'] as int? ?? 0xe6e1,
      );

  final int id;
  String title;
  String description;
  int hour;
  int minute;
  bool isEnabled;
  bool isDaily;
  int iconCode;

  String get timeFormatted {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    final m = minute < 10 ? '0$minute' : '$minute';
    final ampm = hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'hour': hour,
        'minute': minute,
        'is_enabled': isEnabled,
        'is_daily': isDaily,
        'icon_code': iconCode,
      };
}

class RoutineService {
  RoutineService._();
  static final RoutineService instance = RoutineService._();

  static const String _kRoutinesKey = 'aarohi_daily_routines_v1';
  static const MethodChannel _platform = MethodChannel('com.mithun.aarohi/notifications');

  List<DailyRoutine> _routines = [];
  bool _initialized = false;

  List<DailyRoutine> get routines => List.unmodifiable(_routines);

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_kRoutinesKey);

      if (rawList != null && rawList.isNotEmpty) {
        _routines = rawList
            .map((s) {
              try {
                return DailyRoutine.fromJson(jsonDecode(s) as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<DailyRoutine>()
            .toList();
      } else {
        // Setup default daily routine templates for Mithun
        _routines = [
          DailyRoutine(
            id: 2001,
            title: 'Morning Wakeup & Hydrate',
            description: 'Good morning Mithun! Drink 500ml water and start your day.',
            hour: 7,
            minute: 0,
            iconCode: 0xe6e8, // wb_sunny
          ),
          DailyRoutine(
            id: 2002,
            title: 'Fitness & Gym Workout',
            description: 'Time to crush your workout session and stay fit.',
            hour: 8,
            minute: 30,
            iconCode: 0xe28f, // fitness_center
          ),
          DailyRoutine(
            id: 2003,
            title: 'Deep Work & Daily Goals',
            description: 'Review top priorities and enter deep focus.',
            hour: 10,
            minute: 0,
            iconCode: 0xe6f2, // work
          ),
          DailyRoutine(
            id: 2004,
            title: 'Healthy Lunch & Break',
            description: 'Step away from screens, eat a nutritious meal.',
            hour: 13,
            minute: 30,
            iconCode: 0xe3e6, // lunch_dining
          ),
          DailyRoutine(
            id: 2005,
            title: 'Evening Walk & Recharge',
            description: 'Stretch, take an evening walk, and get fresh air.',
            hour: 18,
            minute: 30,
            iconCode: 0xe1eb, // directions_walk
          ),
          DailyRoutine(
            id: 2006,
            title: 'Night Wind-down & Sleep',
            description: 'Reflect on wins today, plan tomorrow, and rest well.',
            hour: 22,
            minute: 30,
            iconCode: 0xe0e3, // bedtime
          ),
        ];
        await _persistRoutines();
      }

      // Schedule all enabled routines with native Android AlarmManager
      for (final r in _routines) {
        if (r.isEnabled) {
          await scheduleRoutineAlarm(r);
        }
      }

      _initialized = true;
      debugPrint('RoutineService initialized with ${_routines.length} routines');
    } catch (e) {
      debugPrint('RoutineService init error: $e');
    }
  }

  /// Schedule an exact alarm with Android OS AlarmManager
  /// This will wake the device and fire notification even if Aarohi is killed or closed!
  Future<void> scheduleRoutineAlarm(DailyRoutine r, {String? spokenReminder}) async {
    if (kIsWeb) return; // Native AlarmManager not available on web
    final now = DateTime.now();
    var scheduled = DateTime(now.year, now.month, now.day, r.hour, r.minute, 0);

    // If time for today has already passed, schedule for tomorrow
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    final spoken = spokenReminder != null && spokenReminder.isNotEmpty
        ? spokenReminder
        : (r.description.isNotEmpty
            ? 'Baby, ${r.title}! ${r.description}'
            : 'Baby, ${r.title}! You said to remind you.');

    try {
      await _platform.invokeMethod('scheduleAlarm', {
        'id': r.id,
        'title': '⏰ ${r.title}',
        'body': r.description.isNotEmpty ? r.description : 'Scheduled for ${r.timeFormatted}',
        'spokenReminder': spoken,
        'triggerAtMillis': scheduled.millisecondsSinceEpoch,
        'isDaily': r.isDaily,
        'hour': r.hour,
        'minute': r.minute,
      });
      debugPrint('Scheduled alarm "${r.title}" for ${scheduled.toIso8601String()} with voice: "$spoken"');
    } catch (e) {
      debugPrint('Error scheduling alarm in AlarmManager: $e');
    }
  }

  /// Schedule one-shot reminder using native AlarmManager (fires even when app is closed)
  Future<void> scheduleExactReminder({
    required String title,
    required String timeStr,
    required int delaySeconds,
    String? spokenReminder,
  }) async {
    if (kIsWeb) return; // Native AlarmManager not available on web
    final id = (DateTime.now().millisecondsSinceEpoch % 100000);
    final triggerAtMillis = DateTime.now().millisecondsSinceEpoch + (delaySeconds * 1000);

    final spoken = spokenReminder != null && spokenReminder.isNotEmpty
        ? spokenReminder
        : (title.toLowerCase().contains('drink') || title.toLowerCase().contains('water')
            ? 'Baby, drink water! You said to remind you.'
            : 'Baby, $title! You said to remind you.');

    try {
      await _platform.invokeMethod('scheduleAlarm', {
        'id': id,
        'title': '⏰ Aarohi Reminder: $title',
        'body': 'Scheduled for $timeStr — Tap to open Aarohi',
        'spokenReminder': spoken,
        'triggerAtMillis': triggerAtMillis,
        'isDaily': false,
        'hour': -1,
        'minute': -1,
      });
      debugPrint('Scheduled exact reminder alarm: "$title" in $delaySeconds seconds with voice: "$spoken"');
    } catch (e) {
      debugPrint('Error scheduling exact reminder: $e');
    }
  }

  Future<void> cancelRoutineAlarm(int id) async {
    if (kIsWeb) return;
    try {
      await _platform.invokeMethod('cancelAlarm', {'id': id});
      debugPrint('Cancelled alarm ID: $id');
    } catch (e) {
      debugPrint('Error cancelling alarm: $e');
    }
  }

  Future<void> toggleRoutine(int id, bool enabled) async {
    final idx = _routines.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _routines[idx].isEnabled = enabled;
      if (enabled) {
        await scheduleRoutineAlarm(_routines[idx]);
      } else {
        await cancelRoutineAlarm(id);
      }
      await _persistRoutines();
    }
  }

  Future<void> updateRoutineTime(int id, int hour, int minute) async {
    final idx = _routines.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _routines[idx].hour = hour;
      _routines[idx].minute = minute;
      if (_routines[idx].isEnabled) {
        await scheduleRoutineAlarm(_routines[idx]);
      }
      await _persistRoutines();
    }
  }

  Future<void> addRoutine({
    required String title,
    required String description,
    required int hour,
    required int minute,
    bool isDaily = true,
    String? spokenReminder,
  }) async {
    final r = DailyRoutine(
      id: (DateTime.now().millisecondsSinceEpoch % 100000),
      title: title.trim(),
      description: description.trim(),
      hour: hour,
      minute: minute,
      isEnabled: true,
      isDaily: isDaily,
    );
    _routines.add(r);
    await scheduleRoutineAlarm(r, spokenReminder: spokenReminder);
    await _persistRoutines();
  }

  Future<void> deleteRoutine(int id) async {
    await cancelRoutineAlarm(id);
    _routines.removeWhere((r) => r.id == id);
    await _persistRoutines();
  }

  Future<void> _persistRoutines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _routines.map((r) => jsonEncode(r.toJson())).toList();
      await prefs.setStringList(_kRoutinesKey, list);

      // Also backup to SD Card / storage
      await SdCardService.instance.savePersonalModel({
        'routines': _routines.map((r) => r.toJson()).toList(),
        'routines_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error persisting routines: $e');
    }
  }
}
