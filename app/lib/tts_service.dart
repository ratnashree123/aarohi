import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Aarohi's 4 emotional voice modes — each changes how she sounds
enum VoiceMode {
  normal,  // Default warm girlfriend voice
  angry,   // When scolded: loud, fast, fierce
  soft,    // When Mithun is sweet: gentle, warm, affectionate
  whisper, // For secrets and private talk: very quiet, breathy
  low,     // When Aarohi is wrong/apologetic: quiet, subdued, humble
}

/// Two-tier voice.
/// Tier 1: Chatterbox on the laptop (emotion + [sigh]/[laugh] tags), reached
///         over Tailscale. 3s budget — unreachable or slow → Tier 2.
/// Tier 2: on-device TTS, automatic and silent. Alarms and reminders must
///         never be silent because the laptop is off.
///         (Android TTS today; Kokoro-82M via sherpa-onnx replaces it in 1d —
///         swap lives entirely inside this class.)
class Tts {
  Tts._() {
    _fallback.awaitSpeakCompletion(true);
    _fallback.setCompletionHandler(() {
      if (!(_speakCompleter?.isCompleted ?? true)) {
        _speakCompleter?.complete();
      }
      _speakCompleter = null;
    });
    _fallback.setErrorHandler((msg) {
      if (!(_speakCompleter?.isCompleted ?? true)) {
        _speakCompleter?.complete();
      }
      _speakCompleter = null;
    });
    _fallback.setCancelHandler(() {
      if (!(_speakCompleter?.isCompleted ?? true)) {
        _speakCompleter?.complete();
      }
      _speakCompleter = null;
    });
    _initFemaleVoice();
  }
  static final Tts instance = Tts._();

  final _player = AudioPlayer();
  final _fallback = FlutterTts();
  bool _voiceConfigured = false;
  Completer<void>? _speakCompleter;

  // Any short bracketed tag: models improvise beyond [sigh]/[laugh]/[chuckle]
  // ([pouty face], [deep sigh], …) and none of them belong on screen or in
  // the fallback voice's mouth.
  static final _tagRe = RegExp(r'\[[^\]\n]{1,30}\]');

  /// Strip paralinguistic tags — for display and for the fallback voice,
  /// which would otherwise read "sigh" out loud.
  static String stripTags(String t) =>
      t.replaceAll(_tagRe, '').replaceAll(RegExp(r'  +'), ' ').trim();

  double _getSpeechRate(VoiceMode mode) {
    if (kIsWeb) {
      switch (mode) {
        case VoiceMode.angry: return 1.15;
        case VoiceMode.soft: return 0.90;
        case VoiceMode.whisper: return 0.85;
        case VoiceMode.low: return 0.85;
        case VoiceMode.normal: return 1.0;
      }
    } else {
      switch (mode) {
        case VoiceMode.angry: return 0.55;
        case VoiceMode.soft: return 0.38;
        case VoiceMode.whisper: return 0.30;
        case VoiceMode.low: return 0.32;
        case VoiceMode.normal: return 0.45;
      }
    }
  }

  Future<void> _initFemaleVoice() async {
    if (_voiceConfigured) return;
    try {
      await _fallback.setVolume(1.0);
      await _fallback.setLanguage('en-US');
      await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.normal));
      // Gentle feminine pitch
      await _fallback.setPitch(1.15);

      final dynamic voices = await _fallback.getVoices;
      if (voices is List) {
        for (final v in voices) {
          if (v is Map) {
            final name = (v['name'] ?? '').toString().toLowerCase();
            final locale = (v['locale'] ?? '').toString().toLowerCase();
            if ((locale.startsWith('en') || locale.contains('eng')) &&
                (name.contains('female') ||
                 name.contains('f0') ||
                 name.contains('sfg') ||
                 name.contains('ahf') ||
                 name.contains('cxx') ||
                 name.contains('woman') ||
                 name.contains('girl'))) {
              await _fallback.setVoice({'name': v['name'], 'locale': v['locale']});
              try {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('aarohi_tts_voice_name', v['name'].toString());
                await prefs.setString('aarohi_tts_voice_locale', v['locale'].toString());
              } catch (_) {}
              break;
            }
          }
        }
      }
      _voiceConfigured = true;
    } catch (_) {
      // Graceful fallback to default engine
    }
  }

  /// Rate for the voice
  Future<void> setRate(double rate) async {
    await _initFemaleVoice();
    final base = _getSpeechRate(_currentMode);
    await _fallback.setSpeechRate(rate * base);
  }

  /// Sets TTS volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    await _initFemaleVoice();
    await _fallback.setVolume(volume.clamp(0.0, 1.0));
  }

  // ── 4 VOICE MODES ────────────────────────────────────────────────

  /// ANGRY mode — when Mithun scolds her: loud, fast, high-pitched, fierce
  Future<void> angryVoice() async {
    await _initFemaleVoice();
    await _fallback.setVolume(1.0);
    await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.angry));
    await _fallback.setPitch(1.30);      // High pitch = heated emotion
    _currentMode = VoiceMode.angry;
  }

  /// SOFT/SWEET mode — when Mithun is being good, kind, or complimenting: warm, gentle
  Future<void> softVoice() async {
    await _initFemaleVoice();
    await _fallback.setVolume(0.85);
    await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.soft));
    await _fallback.setPitch(1.20);      // Warm feminine pitch
    _currentMode = VoiceMode.soft;
  }

  /// WHISPER mode — intimate, secretive, slow, lower pitch (clear and audible!)
  Future<void> whisper() async {
    await _initFemaleVoice();
    await _fallback.setVolume(0.78);     // Clearly audible whisper volume
    await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.whisper));
    await _fallback.setPitch(0.90);      // Breathy lower pitch
    _currentMode = VoiceMode.whisper;
  }

  /// LOW/APOLOGETIC mode — subdued, gentle
  Future<void> lowVoice() async {
    await _initFemaleVoice();
    await _fallback.setVolume(0.75);     // Audible apologetic volume
    await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.low));
    await _fallback.setPitch(0.95);      // Flat, subdued
    _currentMode = VoiceMode.low;
  }

  /// Restore to normal warm default voice
  Future<void> normalVoice() async {
    await _initFemaleVoice();
    await _fallback.setVolume(1.0);
    await _fallback.setSpeechRate(_getSpeechRate(VoiceMode.normal));
    await _fallback.setPitch(1.15);
    _currentMode = VoiceMode.normal;
  }

  VoiceMode _currentMode = VoiceMode.normal;
  VoiceMode get currentMode => _currentMode;

  /// emotion: 0.5 professional (work mode) … 0.6 sweet … 0.85 sulking.
  Future<void> speak(String text, {double emotion = 0.6}) async {
    await _initFemaleVoice();
    // Re-apply current voice mode settings BEFORE speaking to ensure they stick
    await _fallback.setSpeechRate(_getSpeechRate(_currentMode));
    switch (_currentMode) {
      case VoiceMode.angry:
        await _fallback.setVolume(1.0);
        await _fallback.setPitch(1.35);
        break;
      case VoiceMode.soft:
        await _fallback.setVolume(0.85);
        await _fallback.setPitch(1.20);
        break;
      case VoiceMode.whisper:
        await _fallback.setVolume(0.78);
        await _fallback.setPitch(0.90);
        break;
      case VoiceMode.low:
        await _fallback.setVolume(0.75);
        await _fallback.setPitch(0.95);
        break;
      case VoiceMode.normal:
        await _fallback.setVolume(1.0);
        try {
          await _fallback.setPitch((1.15 + (emotion - 0.6) * 0.3).clamp(1.0, 1.3));
        } catch (_) {}
        break;
    }
    if (Config.ttsBaseUrl.isNotEmpty) {
      try {
        final res = await http
            .post(
              Uri.parse('${Config.ttsBaseUrl}/tts'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'text': text,
                'emotion': emotion.clamp(0.5, 0.85),
              }),
            )
            // ponytail: hard 3s cutoff per spec; raise if the laptop GPU is
            // busy with the LLM and fallback fires too often
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await _player.play(BytesSource(res.bodyBytes));
          // resolve when playback ends (hands-free mode waits on this)
          await _player.onPlayerComplete.first
              .timeout(const Duration(seconds: 120), onTimeout: () {});
          return;
        }
      } catch (_) {
        // silent fallback, by design
      }
    }
    final cleanText = stripTags(text);
    if (cleanText.isEmpty) return;

    if (!(_speakCompleter?.isCompleted ?? true)) {
      _speakCompleter?.complete();
    }
    _speakCompleter = Completer<void>();
    await _fallback.speak(cleanText);
    await _speakCompleter?.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
  }

  Future<void> stop() async {
    if (!(_speakCompleter?.isCompleted ?? true)) {
      _speakCompleter?.complete();
    }
    await _player.stop();
    await _fallback.stop();
  }
}
