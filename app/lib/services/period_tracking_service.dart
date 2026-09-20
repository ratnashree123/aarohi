import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sd_card_service.dart';

class PeriodTrackingService extends ChangeNotifier {
  PeriodTrackingService._();
  static final PeriodTrackingService instance = PeriodTrackingService._();

  static const String _kEnabledKey = 'aarohi_period_tracking_enabled';
  static const String _kLastPeriodKey = 'aarohi_last_period_date';
  static const String _kCycleLengthKey = 'aarohi_cycle_length';
  static const String _kPeriodDurationKey = 'aarohi_period_duration';
  static const String _kSymptomsKey = 'aarohi_cycle_symptoms';

  bool _isEnabled = false;
  DateTime _lastPeriodDate = DateTime.now().subtract(const Duration(days: 14));
  int _cycleLength = 28;
  int _periodDuration = 5;
  List<String> _todaySymptoms = [];
  bool _initialized = false;

  bool get isEnabled => _isEnabled;
  DateTime get lastPeriodDate => _lastPeriodDate;
  int get cycleLength => _cycleLength;
  int get periodDuration => _periodDuration;
  List<String> get todaySymptoms => List.unmodifiable(_todaySymptoms);

  DateTime get nextPeriodDate {
    var date = _lastPeriodDate;
    final now = DateTime.now();
    while (date.isBefore(DateTime(now.year, now.month, now.day))) {
      date = date.add(Duration(days: _cycleLength));
    }
    return date;
  }

  int get daysUntilNextPeriod {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final next = nextPeriodDate;
    final diff = next.difference(today).inDays;
    return diff < 0 ? 0 : diff;
  }

  int get currentCycleDay {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var start = DateTime(_lastPeriodDate.year, _lastPeriodDate.month, _lastPeriodDate.day);
    while (start.add(Duration(days: _cycleLength)).isBefore(today) ||
        start.add(Duration(days: _cycleLength)).isAtSameMomentAs(today)) {
      start = start.add(Duration(days: _cycleLength));
    }
    return today.difference(start).inDays + 1;
  }

  String get currentPhaseName {
    final day = currentCycleDay;
    if (day <= _periodDuration) return 'Menstrual Phase';
    if (day < 14) return 'Follicular Phase';
    if (day <= 16) return 'Ovulation Phase';
    return 'Luteal Phase';
  }

  String get currentPhaseDescription {
    final day = currentCycleDay;
    if (day <= _periodDuration) {
      return 'Flow days. Rest well, stay warm, hydrate, and take gentle care.';
    }
    if (day < 14) {
      return 'Estrogen rising! Great time for workouts, social energy, and creative projects.';
    }
    if (day <= 16) {
      return 'Peak energy, high mood, and natural glow.';
    }
    return 'Progesterone phase. Nourish with warm meals, magnesium, and restorative rest.';
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool(_kEnabledKey) ?? false;
      final rawDate = prefs.getString(_kLastPeriodKey);
      if (rawDate != null) {
        _lastPeriodDate = DateTime.tryParse(rawDate) ?? _lastPeriodDate;
      }
      _cycleLength = prefs.getInt(_kCycleLengthKey) ?? 28;
      _periodDuration = prefs.getInt(_kPeriodDurationKey) ?? 5;
      _todaySymptoms = prefs.getStringList(_kSymptomsKey) ?? [];
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('PeriodTrackingService init error: $e');
    }
  }

  Future<void> setEnabled(bool val) async {
    _isEnabled = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, val);
    await _persist();
    notifyListeners();
  }

  Future<void> setLastPeriodDate(DateTime date) async {
    _lastPeriodDate = date;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastPeriodKey, date.toIso8601String());
    await _persist();
    notifyListeners();
  }

  Future<void> setCycleParams({int? cycleLength, int? periodDuration}) async {
    if (cycleLength != null && cycleLength >= 20 && cycleLength <= 45) {
      _cycleLength = cycleLength;
    }
    if (periodDuration != null && periodDuration >= 2 && periodDuration <= 10) {
      _periodDuration = periodDuration;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCycleLengthKey, _cycleLength);
    await prefs.setInt(_kPeriodDurationKey, _periodDuration);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleSymptom(String symptom) async {
    if (_todaySymptoms.contains(symptom)) {
      _todaySymptoms.remove(symptom);
    } else {
      _todaySymptoms.add(symptom);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSymptomsKey, _todaySymptoms);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await SdCardService.instance.savePersonalModel({
        'period_tracking': {
          'is_enabled': _isEnabled,
          'last_period': _lastPeriodDate.toIso8601String(),
          'cycle_length': _cycleLength,
          'period_duration': _periodDuration,
          'symptoms': _todaySymptoms,
        }
      });
    } catch (_) {}
  }
}
