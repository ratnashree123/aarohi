import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Do Not Disturb (DND) Service for Aarohi.
///
/// When DND is active:
/// 1. Aarohi silences unsolicited background voice alerts (battery, charging, unplug, WhatsApp reading).
/// 2. Routine alarms and proactive check-in voices are muted.
/// 3. In-chat responses remain text-focused or quiet.
/// 4. App lock screen warnings are silenced.
class DndService extends ChangeNotifier {
  DndService._();
  static final DndService instance = DndService._();

  static const String _kDndKey = 'aarohi_dnd_active';
  static const String _kDndUntilKey = 'aarohi_dnd_until';

  bool _isDnd = false;
  DateTime? _dndUntil;

  bool get isDnd => _isDnd;
  DateTime? get dndUntil => _dndUntil;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDnd = prefs.getBool(_kDndKey) ?? false;
      final untilMs = prefs.getInt(_kDndUntilKey);
      if (untilMs != null) {
        _dndUntil = DateTime.fromMillisecondsSinceEpoch(untilMs);
        if (DateTime.now().isAfter(_dndUntil!)) {
          _isDnd = false;
          _dndUntil = null;
          await prefs.setBool(_kDndKey, false);
          await prefs.remove(_kDndUntilKey);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setDnd(bool enabled, {Duration? duration}) async {
    _isDnd = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDndKey, enabled);

      if (enabled && duration != null) {
        _dndUntil = DateTime.now().add(duration);
        await prefs.setInt(_kDndUntilKey, _dndUntil!.millisecondsSinceEpoch);
      } else {
        _dndUntil = null;
        await prefs.remove(_kDndUntilKey);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggleDnd() async {
    await setDnd(!_isDnd);
  }
}
