import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../tts_service.dart';

/// Service controlling screen brightness and TTS voice for Aarohi's emotional reactivity.
///
/// IMPORTANT: We only control TTS-internal volume (via flutter_tts setVolume),
/// NOT system volume. This way physical volume buttons always work normally.
/// Brightness is controlled via window.attributes (works while app is in foreground).
class BrightnessVolumeService {
  BrightnessVolumeService._();
  static final BrightnessVolumeService instance = BrightnessVolumeService._();

  static const MethodChannel _channel = MethodChannel('com.mithun.aarohi/display');

  double _currentBrightness = 0.65;
  double _normalBrightness = 0.65;
  bool _isWhisperMode = false;
  Timer? _resetTimer;

  double get currentBrightness => _currentBrightness;
  bool get isWhisperMode => _isWhisperMode;

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      final b = await _channel.invokeMethod<double>('getBrightness');
      if (b != null && b > 0) {
        _currentBrightness = b;
        _normalBrightness = b;
      }
    } catch (_) {}

    // Request WRITE_SETTINGS permission for system-wide brightness control
    try {
      final canWrite = await _channel.invokeMethod<bool>('canWriteSettings') ?? false;
      if (!canWrite) {
        await _channel.invokeMethod('requestWriteSettings');
      }
    } catch (_) {}
  }

  /// Sets screen brightness (0.01 to 1.0)
  Future<void> setBrightness(double level) async {
    _currentBrightness = level.clamp(0.05, 1.0);
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('setBrightness', {'brightness': _currentBrightness});
    } catch (e) {
      debugPrint('Brightness error: $e');
    }
  }

  /// Increase brightness (e.g. on "increase brightness" command)
  Future<double> increaseBrightness([double step = 0.25]) async {
    _cancelResetTimer();
    final target = (_currentBrightness + step).clamp(0.10, 1.0);
    _normalBrightness = target;
    await setBrightness(target);
    return target;
  }

  /// Decrease brightness (e.g. on "decrease brightness" or "dim screen" command)
  Future<double> decreaseBrightness([double step = 0.25]) async {
    _cancelResetTimer();
    final target = (_currentBrightness - step).clamp(0.05, 1.0);
    _normalBrightness = target;
    await setBrightness(target);
    return target;
  }

  double? _savedSystemVolume;

  Future<double> getSystemVolume() async {
    if (kIsWeb) return 0.8;
    try {
      final v = await _channel.invokeMethod<double>('getVolume');
      return v ?? 0.8;
    } catch (_) {
      return 0.8;
    }
  }

  Future<void> setSystemVolume(double level) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('setVolume', {'volume': level.clamp(0.0, 1.0)});
    } catch (e) {
      debugPrint('Volume error: $e');
    }
  }

  // ── VOICE MODES ─────────────────────────────────────────────────

  /// ANGRY mode — loud, fast, fierce: cranks system volume to MAXIMUM!
  Future<void> activateAngryMode() async {
    _cancelResetTimer();
    _isWhisperMode = false;

    // Save current media volume and crank it to 100% maximum so she yells loud!
    try {
      _savedSystemVolume ??= await getSystemVolume();
      await setSystemVolume(1.0);
    } catch (_) {}

    await Tts.instance.angryVoice();

    _resetTimer = Timer(const Duration(seconds: 14), () {
      activateNormalMode();
    });
  }

  /// SOFT/SWEET mode — gentle, warm (auto-resets in 15s)
  Future<void> activateSoftMode() async {
    _cancelResetTimer();
    _isWhisperMode = false;
    await Tts.instance.softVoice();
    // Brightness glow
    await setBrightness(0.98);
    _resetTimer = Timer(const Duration(seconds: 15), () {
      activateNormalMode();
    });
  }

  /// WHISPER mode — quiet, breathy, secretive (auto-resets in 20s)
  Future<void> activateWhisperMode() async {
    _cancelResetTimer();
    _isWhisperMode = true;
    await Tts.instance.whisper();
    // Slightly dim screen for intimate feel
    await setBrightness(0.45);

    // AUTO-RESET after 20 seconds so volume doesn't get stuck
    _resetTimer = Timer(const Duration(seconds: 20), () {
      activateNormalMode();
    });
  }

  /// LOW/APOLOGETIC mode — quiet, subdued (auto-resets in 15s)
  Future<void> activateLowMode() async {
    _cancelResetTimer();
    _isWhisperMode = false;
    await Tts.instance.lowVoice();
    // Dim screen
    await setBrightness(0.35);

    _resetTimer = Timer(const Duration(seconds: 15), () {
      activateNormalMode();
    });
  }

  /// Normal mode: restores everything to default
  Future<void> activateNormalMode() async {
    _cancelResetTimer();
    _isWhisperMode = false;
    await Tts.instance.normalVoice();
    await setBrightness(_normalBrightness);

    // Restore system volume if it was boosted
    if (_savedSystemVolume != null) {
      await setSystemVolume(_savedSystemVolume!);
      _savedSystemVolume = null;
    }
  }

  void _cancelResetTimer() {
    _resetTimer?.cancel();
    _resetTimer = null;
  }
}
