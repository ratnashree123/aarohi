import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sd_card_service.dart';

class MonthlyTask {
  MonthlyTask({
    required this.id,
    required this.title,
    required this.category,
    required this.targetMonth,
    this.targetCount = 1,
    this.currentCount = 0,
    this.isCompleted = false,
    this.notes = '',
  });

  factory MonthlyTask.fromJson(Map<String, dynamic> j) => MonthlyTask(
        id: j['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
        title: j['title'] as String? ?? 'Monthly Goal',
        category: j['category'] as String? ?? 'Personal',
        targetMonth: j['target_month'] as String? ?? _currentMonthKey(),
        targetCount: j['target_count'] as int? ?? 1,
        currentCount: j['current_count'] as int? ?? 0,
        isCompleted: j['is_completed'] as bool? ?? false,
        notes: j['notes'] as String? ?? '',
      );

  final String id;
  String title;
  String category;
  String targetMonth;
  int targetCount;
  int currentCount;
  bool isCompleted;
  String notes;

  double get progress {
    if (isCompleted) return 1.0;
    if (targetCount <= 0) return 0.0;
    return (currentCount / targetCount).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'target_month': targetMonth,
        'target_count': targetCount,
        'current_count': currentCount,
        'is_completed': isCompleted,
        'notes': notes,
      };

  static String _currentMonthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month < 10 ? '0${now.month}' : '${now.month}'}';
  }
}

class MonthlyGoalService extends ChangeNotifier {
  MonthlyGoalService._();
  static final MonthlyGoalService instance = MonthlyGoalService._();

  static const String _kGoalsKey = 'aarohi_monthly_goals_v1';
  List<MonthlyTask> _tasks = [];
  bool _initialized = false;

  List<MonthlyTask> get tasks => List.unmodifiable(_tasks);

  List<MonthlyTask> get currentMonthTasks {
    final currentKey = currentMonthKey();
    return _tasks.where((t) => t.targetMonth.isEmpty || t.targetMonth == currentKey).toList();
  }

  double get currentMonthAchievementRate {
    final list = currentMonthTasks;
    if (list.isEmpty) return 0.0;
    final done = list.where((t) => t.isCompleted || (t.targetCount > 1 && t.currentCount >= t.targetCount)).length;
    return done / list.length;
  }

  static String currentMonthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month < 10 ? '0${now.month}' : '${now.month}'}';
  }

  static String currentMonthDisplayName() {
    final now = DateTime.now();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[now.month - 1]} ${now.year}';
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_kGoalsKey);

      if (rawList != null && rawList.isNotEmpty) {
        _tasks = rawList
            .map((s) {
              try {
                return MonthlyTask.fromJson(jsonDecode(s) as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<MonthlyTask>()
            .toList();
      } else {
        // Pre-populate with realistic, inspiring monthly tasks for this month
        final m = currentMonthKey();
        _tasks = [
          MonthlyTask(
            id: 'm1',
            title: 'Complete 20 Workout & Fitness Sessions',
            category: 'Fitness',
            targetMonth: m,
            targetCount: 20,
            currentCount: 8,
            notes: 'Consistent strength training & cardio',
          ),
          MonthlyTask(
            id: 'm2',
            title: 'Save Monthly Target Fund',
            category: 'Finance',
            targetMonth: m,
            targetCount: 1,
            currentCount: 1,
            isCompleted: true,
            notes: 'Transferred to savings reserve',
          ),
          MonthlyTask(
            id: 'm3',
            title: 'Read 2 High-Impact Books',
            category: 'Learning',
            targetMonth: m,
            targetCount: 2,
            currentCount: 1,
            notes: 'Atomic Habits & Deep Work',
          ),
          MonthlyTask(
            id: 'm4',
            title: 'Sleep 8 Hours for 25 Days',
            category: 'Health',
            targetMonth: m,
            targetCount: 25,
            currentCount: 18,
            notes: 'Proper sleep schedule & screen cutoff at 10 PM',
          ),
          MonthlyTask(
            id: 'm5',
            title: 'Drink 2.5 Liters Water Daily',
            category: 'Habits',
            targetMonth: m,
            targetCount: 30,
            currentCount: 22,
            notes: 'Hydration tracking',
          ),
        ];
        await _persist();
      }
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('MonthlyGoalService init error: $e');
    }
  }

  Future<void> toggleTaskCompleted(String id) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _tasks[idx].isCompleted = !_tasks[idx].isCompleted;
      if (_tasks[idx].isCompleted && _tasks[idx].currentCount < _tasks[idx].targetCount) {
        _tasks[idx].currentCount = _tasks[idx].targetCount;
      }
      await _persist();
      notifyListeners();
    }
  }

  Future<void> incrementProgress(String id) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      if (_tasks[idx].currentCount < _tasks[idx].targetCount) {
        _tasks[idx].currentCount++;
        if (_tasks[idx].currentCount >= _tasks[idx].targetCount) {
          _tasks[idx].isCompleted = true;
        }
      } else {
        _tasks[idx].isCompleted = true;
      }
      await _persist();
      notifyListeners();
    }
  }

  Future<void> addTask({
    required String title,
    required String category,
    required int targetCount,
    String notes = '',
  }) async {
    final t = MonthlyTask(
      id: 'm_${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim(),
      category: category,
      targetMonth: currentMonthKey(),
      targetCount: targetCount > 0 ? targetCount : 1,
      currentCount: 0,
      notes: notes.trim(),
    );
    _tasks.insert(0, t);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _tasks.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_kGoalsKey, list);

      // Also backup to SD Card / storage
      await SdCardService.instance.savePersonalModel({
        'monthly_tasks': _tasks.map((t) => t.toJson()).toList(),
        'monthly_tasks_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error saving monthly tasks: $e');
    }
  }
}
