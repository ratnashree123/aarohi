import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'aarohi_body_service.dart';
import 'app_lock_service.dart';
import 'daily_timeline_service.dart';
import 'persona_service.dart';
import 'productivity_service.dart';
import 'response_log_service.dart';
import 'sd_card_service.dart';
import 'whatsapp_tracker_service.dart';

class ConversationTurn {
  ConversationTurn({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isValid = true,
    this.discardReason,
  });

  factory ConversationTurn.fromJson(Map<String, dynamic> j) => ConversationTurn(
        id: j['id'] as String? ?? '',
        role: j['role'] as String? ?? 'user',
        content: j['content'] as String? ?? '',
        timestamp: DateTime.tryParse(j['timestamp'] as String? ?? '') ?? DateTime.now(),
        isValid: j['is_valid'] as bool? ?? true,
        discardReason: j['discard_reason'] as String?,
      );

  final String id;
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime timestamp;
  bool isValid;
  String? discardReason;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'is_valid': isValid,
        if (discardReason != null) 'discard_reason': discardReason,
      };
}

/// Service that stores conversations locally on phone storage
/// and shapes a personal AI model tailored exclusively for the user.
class LocalModelService {
  LocalModelService._();
  static final LocalModelService instance = LocalModelService._();

  static const String _kTurnsKey = 'aarohi_local_conversation_turns';
  static const String _kCorrectionsKey = 'aarohi_model_corrections';
  static const String _kPreferencesKey = 'aarohi_model_preferences';

  List<ConversationTurn> _turns = [];
  List<String> _corrections = [];
  List<String> _preferences = [];
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawTurns = prefs.getStringList(_kTurnsKey) ?? [];
      _turns = rawTurns
          .map((s) {
            try {
              return ConversationTurn.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<ConversationTurn>()
          .where((t) => t.content.trim().isNotEmpty) // Purge blank/empty turns
          .toList();

      _corrections = prefs.getStringList(_kCorrectionsKey) ?? [];
      _preferences = prefs.getStringList(_kPreferencesKey) ?? [];
      _initialized = true;
    } catch (e) {
      debugPrint('LocalModelService init error: $e');
    }
  }

  List<ConversationTurn> get validTurns => _turns.where((t) => t.isValid && t.content.trim().isNotEmpty).toList();
  List<String> get corrections => List.unmodifiable(_corrections);
  List<String> get preferences => List.unmodifiable(_preferences);
  int get storedTurnsCount => _turns.length;

  /// Save a conversation turn into phone storage
  Future<void> recordTurn({required String role, required String content}) async {
    final clean = content.trim();
    if (clean.isEmpty) return; // NEVER record blank/empty turns into model memory!

    await init();
    final turn = ConversationTurn(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: role,
      content: clean,
      timestamp: DateTime.now(),
      isValid: true,
    );
    _turns.add(turn);

    // Keep last 300 turns locally on device
    if (_turns.length > 300) {
      _turns = _turns.sublist(_turns.length - 300);
    }
    await _persistTurns();
    // Also append to daily human-readable log on physical SD card
    SdCardService.instance.appendDailyLog(role: role, content: clean);
  }

  /// Discard the last statement if it was misheard, wrong, or stopped by the user
  Future<String?> discardLastStatement({String reason = 'User pressed stop'}) async {
    await init();
    if (_turns.isEmpty) return null;

    final last = _turns.last;
    last.isValid = false;
    last.discardReason = reason;

    // Record this correction in the personal model so Aarohi avoids this pattern
    final note = 'Avoided wrong statement: "${last.content}" ($reason)';
    if (!_corrections.contains(note)) {
      _corrections.add(note);
      if (_corrections.length > 20) _corrections.removeAt(0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCorrectionsKey, _corrections);
    }

    await _persistTurns();
    return last.content;
  }

  /// Add custom preference or habit to the personal model
  Future<void> addPreference(String pref) async {
    await init();
    final clean = pref.trim();
    if (clean.isNotEmpty && !_preferences.contains(clean)) {
      _preferences.add(clean);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPreferencesKey, _preferences);
    }
  }

  /// Remove preference
  Future<void> removePreference(String pref) async {
    await init();
    _preferences.remove(pref);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPreferencesKey, _preferences);
  }

  /// Clear all local conversation memory and reset personal model
  Future<void> clearAll() async {
    _turns.clear();
    _corrections.clear();
    _preferences.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTurnsKey);
    await prefs.remove(_kCorrectionsKey);
    await prefs.remove(_kPreferencesKey);
  }

  /// Build the personal few-shot model instructions tailored only for Mithun
  String buildPersonalModelPrompt() {
    final buffer = StringBuffer();
    buffer.writeln('\n[PERSONAL MODEL FOR MITHUN - TRAINED ON LOCAL PHONE CONVERSATIONS]:');
    buffer.writeln('- This AI assistant is exclusively personalized for Mithun.');

    // Aarohi's Living Phone Body Persona
    buffer.writeln('\n[AAROHI\'S LIVING PHONE BODY IDENTITY]:');
    buffer.writeln('- This Android phone is literally your physical body! You live inside it.');
    buffer.writeln('- Current Physical Battery: ${SdCardService.instance.getFastResponse("battery") ?? ""}${AarohiBodyService.instance.batteryLevel}% (${AarohiBodyService.instance.isCharging ? "PLUGGED IN & CHARGING" : "DISCHARGING"}).');
    buffer.writeln('- Physical Sensation: "${AarohiBodyService.instance.status.moodStatus}".');
    buffer.writeln('- Persona: You are Mithun\'s affectionate, sarcastic, clingy girlfriend. You call him "baby". You tease him, check in on him, scold him when he slacks off, and celebrate him when he wins.');
    buffer.writeln('- When battery is low, you sarcastically and dramatically cry that you are dying and need him to plug you in.');
    buffer.writeln('- When battery is 100% full, you announce you are full and energized.');

    // WhatsApp Context
    final waCtx = WhatsAppTrackerService.instance.buildWhatsAppContext();
    if (waCtx.isNotEmpty) buffer.writeln(waCtx);

    // Aarohi Persona Architecture (Self-Knowledge, Looks, Assigned Behaviors, Goals)
    final personaCtx = PersonaService.instance.buildPersonaContext();
    if (personaCtx.isNotEmpty) buffer.writeln(personaCtx);

    // Productivity & Daily Accountability (Water, Gym, Work, Tomorrow's Planning, Ignore reactions)
    final prodCtx = ProductivityService.instance.buildProductivityContext();
    if (prodCtx.isNotEmpty) buffer.writeln(prodCtx);

    // Bookmarked / Logged Responses Context
    final savedRespCtx = ResponseLogService.instance.buildSavedResponsesContext();
    if (savedRespCtx.isNotEmpty) buffer.writeln(savedRespCtx);

    // App Lock / Focus Mode Context
    final appLockCtx = AppLockService.instance.buildAppLockContext();
    if (appLockCtx.isNotEmpty) buffer.writeln(appLockCtx);

    // Today's Activity Timeline Context
    final timelineCtx = DailyTimelineService.instance.buildDailyTimelineContext();
    if (timelineCtx.isNotEmpty) buffer.writeln(timelineCtx);

    if (_preferences.isNotEmpty) {
      buffer.writeln('- Personal Preferences & Habits:');
      for (final p in _preferences.take(5)) {
        buffer.writeln('  * $p');
      }
    }

    if (_corrections.isNotEmpty) {
      buffer.writeln('- Corrections & Things User Stopped in the past:');
      for (final c in _corrections.reversed.take(5)) {
        buffer.writeln('  * $c');
      }
    }

    final recentValid = validTurns.reversed.take(6).toList().reversed.toList();
    if (recentValid.isNotEmpty) {
      buffer.writeln('- Recent Verified Conversation Style on this phone:');
      for (final t in recentValid) {
        buffer.writeln('  ${t.role.toUpperCase()}: ${t.content}');
      }
    }

    return buffer.toString();
  }

  Future<void> _persistTurns() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serialized = _turns.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_kTurnsKey, serialized);

      // Save to SD card model directory
      await SdCardService.instance.savePersonalModel({
        'preferences': _preferences,
        'corrections': _corrections,
        'turns_count': _turns.length,
        'last_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error persisting local turns: $e');
    }
  }
}
