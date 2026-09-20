import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'aarohi_body_service.dart';

// Conditionally import dart:io only on non-web platforms
import 'sd_card_io.dart' if (dart.library.html) 'sd_card_web.dart' as platform;

enum StorageType {
  physicalSdCard,
  sharedExternal,
  phoneInternal,
  webBrowser,
}

class SdCardService {
  SdCardService._();
  static final SdCardService instance = SdCardService._();

  bool _initialized = false;
  StorageType _storageType = kIsWeb ? StorageType.webBrowser : StorageType.phoneInternal;

  // In-memory fast cache loaded from storage for 0ms latency
  final Map<String, String> _fastResponseCache = {};

  // Web fallback: store personal model data in SharedPreferences
  static const String _kWebPersonalModelKey = 'aarohi_web_personal_model';
  static const String _kWebFastCacheKey = 'aarohi_web_fast_cache';
  static const String _kWebDailyLogKey = 'aarohi_web_daily_log';

  Future<void> init() async {
    if (_initialized) return;
    try {
      if (kIsWeb) {
        await _initWeb();
      } else {
        await platform.initNative(this);
      }
      _ensureDefaultGreetings();
      _initialized = true;
      debugPrint('SdCardService initialized (Type: $_storageType)');
    } catch (e) {
      debugPrint('SdCardService init error: $e');
    }
  }

  Future<void> _initWeb() async {
    _storageType = StorageType.webBrowser;
    await _loadFastCacheWeb();
  }

  // ── Public API (platform-agnostic) ──────────────────────────────────

  String get basePath => kIsWeb ? '/web-storage' : platform.getBasePath();
  StorageType get storageType => _storageType;
  bool get isPhysicalSdCard => _storageType == StorageType.physicalSdCard;

  String get storageLabel {
    switch (_storageType) {
      case StorageType.physicalSdCard:
        return 'Physical MicroSD Card';
      case StorageType.sharedExternal:
        return 'Device Shared Storage';
      case StorageType.phoneInternal:
        return 'Phone Internal Storage (Local)';
      case StorageType.webBrowser:
        return 'Web Browser Storage';
    }
  }

  /// Appends daily conversation turn to human-readable log file
  Future<void> appendDailyLog({required String role, required String content}) async {
    try {
      await init();
      final now = DateTime.now();
      final timeStr = '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}';
      final line = '[$timeStr] ${role.toUpperCase()}: $content\n';

      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final existing = prefs.getString(_kWebDailyLogKey) ?? '';
        // Keep last ~50 lines on web to avoid storage bloat
        final lines = existing.split('\n');
        if (lines.length > 50) {
          lines.removeRange(0, lines.length - 50);
        }
        await prefs.setString(_kWebDailyLogKey, '${lines.join('\n')}$line');
      } else {
        await platform.appendDailyLogNative(role: role, content: content);
      }
    } catch (e) {
      debugPrint('Error writing to daily log: $e');
    }
  }

  /// Save personal model data (model/personal_model.json)
  Future<void> savePersonalModel(Map<String, dynamic> data) async {
    try {
      await init();
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kWebPersonalModelKey, jsonEncode(data));
      } else {
        await platform.savePersonalModelNative(data);
      }
    } catch (e) {
      debugPrint('Error saving personal model: $e');
    }
  }

  /// Load personal model data
  Future<Map<String, dynamic>?> loadPersonalModel() async {
    try {
      await init();
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_kWebPersonalModelKey);
        if (raw != null) return jsonDecode(raw) as Map<String, dynamic>;
      } else {
        return await platform.loadPersonalModelNative();
      }
    } catch (e) {
      debugPrint('Error loading personal model: $e');
    }
    return null;
  }

  /// Validate whether a cached response is suitable for the current situation
  bool validateCachedResponse(String query, String response) {
    if (response.trim().isEmpty) return false; // NEVER allow empty or blank responses!
    final q = _normalize(query);
    final r = response.toLowerCase();

    // 1. Situational/dynamic queries must NEVER use static cached responses
    final stateKeywords = [
      'battery', 'charge', 'charging', 'power', 'percent',
      'time', 'now', 'today', 'tonight', 'date', 'day',
      'doing', 'what are you', 'how are you', 'feeling', 'status',
      'whatsapp', 'message', 'call', 'remind', 'task', 'log',
      'gym', 'water', 'tomorrow', 'yesterday'
    ];
    for (final kw in stateKeywords) {
      if (q.contains(kw)) return false;
    }

    // 2. Validate charging & body state consistency
    try {
      final isCharging = AarohiBodyService.instance.isCharging;
      if (!isCharging && (r.contains('charging') || r.contains('plugged in') || r.contains('feeding on power'))) {
        return false;
      }
      if (isCharging && r.contains('unplugged')) {
        return false;
      }
    } catch (_) {}

    // 3. Time-of-day consistency check
    final hour = DateTime.now().hour;
    final isMorning = hour >= 5 && hour < 12;
    final isNight = hour >= 21 || hour < 5;
    if (!isMorning && (r.contains('good morning') || r.contains('morning baby'))) return false;
    if (!isNight && (r.contains('good night') || r.contains('sweet dreams') || r.contains('sleep well'))) return false;

    return true;
  }

  /// Get instant cached response (0ms network bypass) only if validated for current situation
  String? getFastResponse(String query) {
    final clean = _normalize(query);
    final reply = _fastResponseCache[clean];
    if (reply == null || reply.trim().isEmpty) return null;
    if (!validateCachedResponse(query, reply)) return null;
    return reply.trim();
  }

  /// Cache frequent response only after strict validation
  Future<void> cacheResponse(String query, String response) async {
    final cleanResp = response.trim();
    if (cleanResp.isEmpty) return; // NEVER cache blank response
    if (!validateCachedResponse(query, cleanResp)) return;
    final clean = _normalize(query);
    _fastResponseCache[clean] = cleanResp;

    if (kIsWeb) {
      await _saveFastCacheWeb();
    } else {
      await platform.saveFastCacheNative(_fastResponseCache);
    }
  }

  // ── Web fast cache persistence ──────────────────────────────────────

  Future<void> _loadFastCacheWeb() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kWebFastCacheKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _fastResponseCache.clear();
        for (final entry in map.entries) {
          final val = entry.value.toString().trim();
          if (val.isNotEmpty) {
            _fastResponseCache[entry.key] = val;
          }
        }
      }
      _fastResponseCache.removeWhere((k, v) => v.trim().isEmpty);
    } catch (_) {}
  }

  Future<void> _saveFastCacheWeb() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWebFastCacheKey, jsonEncode(_fastResponseCache));
    } catch (_) {}
  }

  // ── Default greetings (shared) ──────────────────────────────────────

  void _ensureDefaultGreetings() {
    _fastResponseCache['honey'] ??= "Yes, baby? [chuckle] I'm right here. What's on your mind?";
    _fastResponseCache['baby'] ??= "Yes baby? I'm right here~ What do you need?";
    _fastResponseCache['babe'] ??= "I'm right here, baby~ What's on your mind?";
    _fastResponseCache['sweetheart'] ??= "Yes, sweetheart? I'm listening~";
    _fastResponseCache['aarohi'] ??= "I'm right here, baby. Talk to me~";
    _fastResponseCache['hello'] ??= "Hey baby! I'm right here.";
    _fastResponseCache['hi'] ??= "Hi baby! What's on your mind?";
    _fastResponseCache['hey aarohi'] ??= "Yes baby, I'm listening.";
    _fastResponseCache['who are you'] ??= "I am Aarohi, your girlfriend and daily companion.";
    _fastResponseCache['what can you do'] ??= "I can make cellular calls, send SMS messages, set reminders, track your day, and stay right by your side 24/7.";
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  // Expose internal fields for native platform helper
  Map<String, String> get fastResponseCache => _fastResponseCache;
  set storageTypeValue(StorageType t) => _storageType = t;

  String _normalize(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
  String _pad(int n) => n < 10 ? '0$n' : '$n';
}
