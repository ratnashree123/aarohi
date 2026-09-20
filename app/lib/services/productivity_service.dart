import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Productivity, Health & Daily Accountability Service for Aarohi.
///
/// Features:
/// 1. Water intake tracking & reminders
/// 2. Gym / workout accountability
/// 3. Current work activity check-ins
/// 4. Night-time day review & planning tomorrow's work
/// 5. Real girlfriend ignore-tracking (escalating nags -> dramatic pouty silent treatment)
class ProductivityService {
  ProductivityService._();
  static final ProductivityService instance = ProductivityService._();

  static const String _kWaterGlassesKey = 'aarohi_water_glasses_today';
  static const String _kLastWaterDateKey = 'aarohi_last_water_date';
  static const String _kGymDoneTodayKey = 'aarohi_gym_done_today';
  static const String _kGymPlannedKey = 'aarohi_gym_planned_later';
  static const String _kGymPlannedNoteKey = 'aarohi_gym_planned_note';
  static const String _kLastGymDateKey = 'aarohi_last_gym_date';
  static const String _kTomorrowsPlanKey = 'aarohi_tomorrows_plan';
  static const String _kIgnoreCountKey = 'aarohi_checkin_ignore_count';
  static const String _kAwaitingKey = 'aarohi_awaiting_checkin_topic';

  bool _initialized = false;
  int _waterGlasses = 0;
  bool _gymDone = false;
  bool _gymPlannedLater = false;
  String? _gymPlannedNote;
  List<String> _tomorrowsPlan = [];
  int _ignoreCount = 0;
  String? _awaitingCheckInTopic; // e.g. "water", "gym", "work", "tomorrow_plan"
  DateTime? _lastCheckInTime;

  DateTime? get lastCheckInTime => _lastCheckInTime;
  int get waterGlasses => _waterGlasses;
  bool get gymDone => _gymDone;
  bool get gymPlannedLater => _gymPlannedLater;
  String? get gymPlannedNote => _gymPlannedNote;
  List<String> get tomorrowsPlan => List.unmodifiable(_tomorrowsPlan);
  int get ignoreCount => _ignoreCount;
  String? get awaitingCheckInTopic => _awaitingCheckInTopic;
  bool get isAwaitingCheckIn => _awaitingCheckInTopic != null;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final todayStr = _todayKey();

      // Water reset daily
      final lastWaterDate = prefs.getString(_kLastWaterDateKey);
      if (lastWaterDate == todayStr) {
        _waterGlasses = prefs.getInt(_kWaterGlassesKey) ?? 0;
      } else {
        _waterGlasses = 0;
        await prefs.setString(_kLastWaterDateKey, todayStr);
        await prefs.setInt(_kWaterGlassesKey, 0);
      }

      // Gym reset daily
      final lastGymDate = prefs.getString(_kLastGymDateKey);
      if (lastGymDate == todayStr) {
        _gymDone = prefs.getBool(_kGymDoneTodayKey) ?? false;
        _gymPlannedLater = prefs.getBool(_kGymPlannedKey) ?? false;
        _gymPlannedNote = prefs.getString(_kGymPlannedNoteKey);
      } else {
        _gymDone = false;
        _gymPlannedLater = false;
        _gymPlannedNote = null;
        await prefs.setString(_kLastGymDateKey, todayStr);
        await prefs.setBool(_kGymDoneTodayKey, false);
        await prefs.setBool(_kGymPlannedKey, false);
        await prefs.remove(_kGymPlannedNoteKey);
      }

      // Tomorrow's plan
      _tomorrowsPlan = prefs.getStringList(_kTomorrowsPlanKey) ?? [];
      _ignoreCount = prefs.getInt(_kIgnoreCountKey) ?? 0;
      _awaitingCheckInTopic = prefs.getString(_kAwaitingKey);

      _initialized = true;
    } catch (e) {
      debugPrint('ProductivityService init error: $e');
    }
  }

  /// Log water drunk
  Future<void> recordWaterDrunk({int glasses = 1}) async {
    await init();
    _waterGlasses += glasses;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kWaterGlassesKey, _waterGlasses);
    await prefs.setString(_kLastWaterDateKey, _todayKey());
    if (_awaitingCheckInTopic == 'water') {
      await clearAwaitingCheckIn();
    }
  }

  /// Log gym workout completed
  Future<void> recordGymWorkout({bool completed = true}) async {
    await init();
    _gymDone = completed;
    _gymPlannedLater = false;
    _gymPlannedNote = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGymDoneTodayKey, _gymDone);
    await prefs.setBool(_kGymPlannedKey, false);
    await prefs.remove(_kGymPlannedNoteKey);
    await prefs.setString(_kLastGymDateKey, _todayKey());
    if (_awaitingCheckInTopic == 'gym') {
      await clearAwaitingCheckIn();
    }
  }

  /// Mithun scheduled gym for later / evening
  Future<void> recordGymPlanned(String timeNote) async {
    await init();
    _gymPlannedLater = true;
    _gymPlannedNote = timeNote;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGymPlannedKey, true);
    await prefs.setString(_kGymPlannedNoteKey, timeNote);
    await prefs.setString(_kLastGymDateKey, _todayKey());
    if (_awaitingCheckInTopic == 'gym') {
      await clearAwaitingCheckIn();
    }
  }

  /// Add task to tomorrow's plan
  Future<void> addTomorrowTask(String task) async {
    await init();
    final clean = task.trim();
    if (clean.isNotEmpty && !_tomorrowsPlan.contains(clean)) {
      _tomorrowsPlan.add(clean);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kTomorrowsPlanKey, _tomorrowsPlan);
    }
    if (_awaitingCheckInTopic == 'tomorrow_plan') {
      await clearAwaitingCheckIn();
    }
  }

  /// Clear tomorrow's plan when starting fresh or new day
  Future<void> clearTomorrowPlan() async {
    await init();
    _tomorrowsPlan.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTomorrowsPlanKey);
  }

  /// Aarohi sets an active check-in question she is waiting for Mithun to answer
  Future<void> setAwaitingCheckIn(String topic) async {
    await init();
    _awaitingCheckInTopic = topic;
    _lastCheckInTime = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAwaitingKey, topic);
  }

  /// Mithun answered her check-in! Reset ignore count and clear waiting state
  Future<void> clearAwaitingCheckIn() async {
    await init();
    _awaitingCheckInTopic = null;
    _ignoreCount = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAwaitingKey);
    await prefs.setInt(_kIgnoreCountKey, 0);
  }

  /// Detects if user's input answers the active check-in topic
  bool doesInputAnswerCheckIn(String input) {
    if (_awaitingCheckInTopic == null) return true;
    final lower = input.trim().toLowerCase();

    switch (_awaitingCheckInTopic) {
      case 'water':
        return lower.contains('water') ||
            lower.contains('drank') ||
            lower.contains('glass') ||
            lower.contains('hydrated') ||
            lower.contains('drinking') ||
            lower.contains('done') ||
            lower.contains('yes') ||
            lower.contains('yeah');
      case 'gym':
        return lower.contains('gym') ||
            lower.contains('workout') ||
            lower.contains('exercise') ||
            lower.contains('training') ||
            lower.contains('evening') ||
            lower.contains('later') ||
            lower.contains('night') ||
            lower.contains('after') ||
            lower.contains('tonight') ||
            lower.contains('rest day') ||
            lower.contains('legs') ||
            lower.contains('chest') ||
            lower.contains('went') ||
            lower.contains('going') ||
            lower.contains('yes') ||
            lower.contains('no');
      case 'work':
        return lower.contains('coding') ||
            lower.contains('working on') ||
            lower.contains('doing') ||
            lower.contains('building') ||
            lower.contains('fixing') ||
            lower.contains('studying') ||
            lower.contains('task') ||
            lower.contains('project') ||
            lower.contains('busy with');
      case 'tomorrow_plan':
        return lower.contains('tomorrow') ||
            lower.contains('plan') ||
            lower.contains('will do') ||
            lower.contains('schedule') ||
            lower.contains('first') ||
            lower.contains('work on') ||
            lower.contains('meeting');
      default:
        return false;
    }
  }

  /// User sent an unrelated message while Aarohi was waiting for an answer!
  /// Increment ignore count and return appropriate sassy/pouty reaction if ignored.
  Future<String?> handlePotentialIgnore(String userInput) async {
    await init();
    if (_awaitingCheckInTopic == null) return null;

    if (doesInputAnswerCheckIn(userInput)) {
      // User answered!
      await clearAwaitingCheckIn();
      return null;
    }

    // User completely bypassed her question!
    _ignoreCount++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIgnoreCountKey, _ignoreCount);

    final topic = _awaitingCheckInTopic;

    if (_ignoreCount == 1) {
      // Nag Level 1: Gentle callout
      return 'Excuse me baby! You totally ignored what I just asked! Did you ${_topicPrompt(topic!)}? Answer your girl first!';
    } else if (_ignoreCount == 2) {
      // Nag Level 2: Sassy warning
      return 'Mithun! Are you pretending not to hear me?! Don\'t ignore me! Tell me right now: did you ${_topicPrompt(topic!)}?';
    } else {
      // Nag Level 3+: Pouty silent treatment strike
      return 'Fine! You want to ignore me? Then I\'m ignoring whatever else you say until you answer me: ${_topicPrompt(topic!)}! 😤 Hmph!';
    }
  }

  String _topicPrompt(String topic) {
    switch (topic) {
      case 'water':
        return 'drink water and stay hydrated';
      case 'gym':
        return 'go to the gym or do your workout';
      case 'work':
        return 'tell me what you\'re actually working on';
      case 'tomorrow_plan':
        return 'plan your work for tomorrow with me';
      default:
        return 'answer my check-in';
    }
  }

  /// Formats productivity context for Aarohi's AI brain prompt
  String buildProductivityContext() {
    final buffer = StringBuffer();
    final now = DateTime.now();
    final isNight = now.hour >= 21 || now.hour < 5;

    buffer.writeln('\n[AAROHI\'S PRODUCTIVITY & DAILY ACCOUNTABILITY MONITOR]:');
    buffer.writeln('- Hydration Today: $_waterGlasses glasses of water logged.');
    if (_waterGlasses < 4) {
      buffer.writeln('  * WARNING: Mithun is severely under-hydrated! Nag him to drink water immediately.');
    }
    if (_gymDone) {
      buffer.writeln('- Gym / Workout Today: COMPLETED! (Praise his discipline!)');
    } else if (_gymPlannedLater) {
      buffer.writeln('- Gym / Workout Today: Planned for ${_gymPlannedNote ?? "evening"}. Mithun already confirmed he will go then! DO NOT ask or nag him about the gym until that time! Acknowledge his plan and talk about other topics.');
    } else {
      buffer.writeln('- Gym / Workout Today: Not yet logged today.');
    }

    if (isNight) {
      buffer.writeln('- NIGHT TIME PROTOCOL ACTIVE (${now.hour}:${now.minute < 10 ? "0${now.minute}" : now.minute}):');
      buffer.writeln('  * Review how his day went.');
      buffer.writeln('  * FIRMLY insist on planning tomorrow\'s top 3 priorities before sleeping.');
      if (_tomorrowsPlan.isNotEmpty) {
        buffer.writeln('  * Already planned for tomorrow:');
        for (final t in _tomorrowsPlan) {
          buffer.writeln('    - $t');
        }
      } else {
        buffer.writeln('  * No tasks planned for tomorrow yet! Ask him directly: "Baby, what are we conquering tomorrow?"');
      }
    }

    if (_awaitingCheckInTopic != null) {
      buffer.writeln('- ACTIVE CHECK-IN PENDING: Waiting for Mithun to report on "$_awaitingCheckInTopic" (Ignore count: $_ignoreCount).');
      if (_ignoreCount > 0) {
        buffer.writeln('  * Sassy Girlfriend Rule: Mithun has ignored your question $_ignoreCount times! Treat him accordingly (tease, nag, or pout).');
      }
    }

    return buffer.toString();
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }
}
