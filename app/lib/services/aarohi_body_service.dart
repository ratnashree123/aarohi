import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AarohiBodyStatus {
  AarohiBodyStatus({
    required this.batteryLevel,
    required this.isCharging,
    required this.temperature,
    required this.health,
  });

  final int batteryLevel;
  final bool isCharging;
  final double temperature;
  final String health;

  String get moodStatus {
    if (isCharging) {
      if (batteryLevel >= 100) return '⚡ 100% Full & Super Energized!';
      return '🔌 Feeding on power... Ahhh feels so good baby!';
    }
    if (batteryLevel <= 10) return '🚨 Dying! Save me! Plug me in right now!';
    if (batteryLevel <= 20) return '⚠️ Weak & Starving! Find my charger!';
    if (batteryLevel <= 40) return '🥱 Running low on energy baby...';
    if (batteryLevel >= 80) return '✨ Energetic, happy, and watching over you!';
    return '💖 Feeling great and alive inside your phone!';
  }
}

class AarohiBodyService extends ChangeNotifier {
  AarohiBodyService._();
  static final AarohiBodyService instance = AarohiBodyService._();

  static const MethodChannel _channel = MethodChannel('com.mithun.aarohi/battery');

  AarohiBodyStatus _status = AarohiBodyStatus(
    batteryLevel: 80,
    isCharging: false,
    temperature: 31.0,
    health: 'Good',
  );
  bool _dramaticAlertsEnabled = true;
  Timer? _poller;
  bool _initialized = false;

  AarohiBodyStatus get status => _status;
  int get batteryLevel => _status.batteryLevel;
  bool get isCharging => _status.isCharging;
  bool get dramaticAlertsEnabled => _dramaticAlertsEnabled;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) return; // No battery API on web — keep default mock status
    await refreshBatteryStatus();
    await _loadDramaticSetting();

    // Poll battery status every 15 seconds while app is active
    _poller = Timer.periodic(const Duration(seconds: 15), (_) => refreshBatteryStatus());
  }

  Future<void> refreshBatteryStatus() async {
    if (kIsWeb) return;
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getBatteryStatus');
      if (res != null) {
        _status = AarohiBodyStatus(
          batteryLevel: (res['level'] as num?)?.toInt() ?? 50,
          isCharging: res['isCharging'] as bool? ?? false,
          temperature: ((res['temperature'] as num?) ?? 30.0).toDouble(),
          health: res['health'] as String? ?? 'Good',
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error getting battery status: $e');
    }
  }

  Future<void> _loadDramaticSetting() async {
    if (kIsWeb) return;
    try {
      final enabled = await _channel.invokeMethod<bool>('isDramaticEnabled');
      if (enabled != null) {
        _dramaticAlertsEnabled = enabled;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setDramaticAlertsEnabled(bool enabled) async {
    _dramaticAlertsEnabled = enabled;
    notifyListeners();
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('setDramaticEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> testDramaticAlert() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('speakDramaticAlert', {'percent': _status.batteryLevel});
    } catch (_) {}
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
