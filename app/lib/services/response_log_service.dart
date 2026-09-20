import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sd_card_service.dart';

class SavedResponseItem {
  SavedResponseItem({
    required this.id,
    required this.userQuery,
    required this.assistantReply,
    required this.timestamp,
    this.tag = 'favorite',
  });

  factory SavedResponseItem.fromJson(Map<String, dynamic> j) => SavedResponseItem(
        id: j['id'] as String? ?? '',
        userQuery: j['user_query'] as String? ?? '',
        assistantReply: j['assistant_reply'] as String? ?? '',
        timestamp: DateTime.tryParse(j['timestamp'] as String? ?? '') ?? DateTime.now(),
        tag: j['tag'] as String? ?? 'favorite',
      );

  final String id;
  final String userQuery;
  final String assistantReply;
  final DateTime timestamp;
  final String tag;

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_query': userQuery,
        'assistant_reply': assistantReply,
        'timestamp': timestamp.toIso8601String(),
        'tag': tag,
      };
}

/// Service that explicitly logs and bookmarks Aarohi's AI responses
/// when Mithun commands: "log this response", "save this response", etc.
class ResponseLogService {
  ResponseLogService._();
  static final ResponseLogService instance = ResponseLogService._();

  static const String _kSavedResponsesKey = 'aarohi_saved_responses_list';
  final List<SavedResponseItem> _savedResponses = [];
  bool _initialized = false;

  List<SavedResponseItem> get savedResponses => List.unmodifiable(_savedResponses);

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kSavedResponsesKey) ?? [];
      _savedResponses.clear();
      for (final s in list) {
        try {
          _savedResponses.add(SavedResponseItem.fromJson(jsonDecode(s) as Map<String, dynamic>));
        } catch (_) {}
      }
      _initialized = true;
    } catch (e) {
      debugPrint('ResponseLogService init error: $e');
    }
  }

  /// Save an AI response to memory and persistent storage
  Future<SavedResponseItem> saveResponse({
    required String userQuery,
    required String assistantReply,
    String tag = 'saved',
  }) async {
    await init();
    final item = SavedResponseItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      userQuery: userQuery.trim(),
      assistantReply: assistantReply.trim(),
      timestamp: DateTime.now(),
      tag: tag,
    );

    _savedResponses.insert(0, item);
    // Keep last 100 saved responses
    if (_savedResponses.length > 100) {
      _savedResponses.removeLast();
    }

    final prefs = await SharedPreferences.getInstance();
    final serialized = _savedResponses.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(_kSavedResponsesKey, serialized);

    // Also persist to SD Card for permanent access
    await _writeToSdCard(item);

    return item;
  }

  /// Format all saved responses for AI context or export
  String buildSavedResponsesContext() {
    if (_savedResponses.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('\n[RESPONSES MITHUN ASKED YOU TO LOG & REMEMBER]:');
    for (final item in _savedResponses.take(5)) {
      buffer.writeln('- Saved Reply: "${item.assistantReply}" (Context: "${item.userQuery}")');
    }
    return buffer.toString();
  }

  Future<void> _writeToSdCard(SavedResponseItem item) async {
    if (kIsWeb) return; // No file I/O on web
    try {
      final basePath = SdCardService.instance.basePath;
      // Use SdCardService.appendDailyLog for web-safe logging
      await SdCardService.instance.appendDailyLog(
        role: 'saved_response',
        content: 'TAG: ${item.tag} | USER: ${item.userQuery} | AAROHI: ${item.assistantReply}',
      );
    } catch (_) {}
  }
}
