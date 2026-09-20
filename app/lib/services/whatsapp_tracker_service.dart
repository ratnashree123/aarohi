import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WhatsAppMessage {
  WhatsAppMessage({
    required this.sender,
    required this.message,
    required this.time,
    required this.timestamp,
    required this.packageName,
  });

  factory WhatsAppMessage.fromMap(Map<dynamic, dynamic> m) => WhatsAppMessage(
        sender: m['sender']?.toString() ?? 'Unknown',
        message: m['message']?.toString() ?? '',
        time: m['time']?.toString() ?? '',
        timestamp: int.tryParse(m['timestamp']?.toString() ?? '0') ?? 0,
        packageName: m['package']?.toString() ?? 'com.whatsapp',
      );

  final String sender;
  final String message;
  final String time;
  final int timestamp;
  final String packageName;
}

class WhatsAppTrackerService extends ChangeNotifier {
  WhatsAppTrackerService._();
  static final WhatsAppTrackerService instance = WhatsAppTrackerService._();

  static const MethodChannel _channel = MethodChannel('com.mithun.aarohi/whatsapp');

  List<WhatsAppMessage> _messages = [];
  bool _isAccessGranted = false;
  bool _voiceAlertsEnabled = false;
  bool _initialized = false;

  List<WhatsAppMessage> get messages => List.unmodifiable(_messages);
  bool get isAccessGranted => _isAccessGranted;
  bool get voiceAlertsEnabled => _voiceAlertsEnabled;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb) return; // No WhatsApp integration on web

    // Real-time notification receiver from native Kotlin
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWhatsAppMessage') {
        final raw = call.arguments as Map<dynamic, dynamic>?;
        if (raw != null) {
          final msg = WhatsAppMessage.fromMap(raw);
          _messages.insert(0, msg);
          if (_messages.length > 50) _messages.removeLast();
          notifyListeners();
        }
      }
    });

    await refresh();
  }

  Future<void> refresh() async {
    await checkAccess();
    await fetchMessages();
    await _loadVoiceAlertsSetting();
  }

  Future<void> checkAccess() async {
    if (kIsWeb) return;
    try {
      final granted = await _channel.invokeMethod<bool>('isAccessGranted');
      _isAccessGranted = granted ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> requestNotificationAccess() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('requestAccess');
    } catch (_) {}
  }

  Future<void> fetchMessages() async {
    if (kIsWeb) return;
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('getMessages');
      if (list != null) {
        _messages = list
            .map((item) => WhatsAppMessage.fromMap(item as Map<dynamic, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error fetching WhatsApp messages: $e');
    }
  }

  Future<void> _loadVoiceAlertsSetting() async {
    if (kIsWeb) return;
    try {
      final enabled = await _channel.invokeMethod<bool>('isVoiceAlertEnabled');
      _voiceAlertsEnabled = enabled ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setVoiceAlertsEnabled(bool enabled) async {
    _voiceAlertsEnabled = enabled;
    notifyListeners();
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('setVoiceAlertEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> clearMessages() async {
    _messages.clear();
    notifyListeners();
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('clearMessages');
    } catch (_) {}
  }

  /// Builds a friendly prompt context of recent WhatsApp messages for Aarohi's AI brain
  String buildWhatsAppContext() {
    if (_messages.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('\n[RECENT INCOMING WHATSAPP MESSAGES YOU (AAROHI) SAW ON THE PHONE]:');
    for (final m in _messages.take(6)) {
      buffer.writeln('- From ${m.sender} (${m.time}): "${m.message}"');
    }
    buffer.writeln('(You know what people texted Mithun. You can tease him, remind him to reply, or answer when he asks about WhatsApp.)');
    return buffer.toString();
  }
}
