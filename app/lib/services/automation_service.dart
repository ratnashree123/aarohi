import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sd_card_service.dart';
import '../tts_service.dart';

enum AutomationTriggerType {
  timeOfDay,
  missedCall,
  smsKeyword,
  oneTapShortcut,
}

enum AutomationActionType {
  sendSms,
  makeCall,
  speakTts,
  showNotification,
}

class AutomationRule {
  AutomationRule({
    required this.id,
    required this.name,
    required this.triggerType,
    required this.actionType,
    this.isEnabled = true,
    this.hour = 8,
    this.minute = 0,
    this.keyword = '',
    this.targetContact = '',
    this.actionMessage = '',
    this.lastTriggered,
    this.runCount = 0,
  });

  factory AutomationRule.fromJson(Map<String, dynamic> j) => AutomationRule(
        id: j['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: j['name'] as String? ?? 'Automation',
        triggerType: AutomationTriggerType.values.firstWhere(
          (t) => t.name == j['trigger_type'],
          orElse: () => AutomationTriggerType.oneTapShortcut,
        ),
        actionType: AutomationActionType.values.firstWhere(
          (a) => a.name == j['action_type'],
          orElse: () => AutomationActionType.speakTts,
        ),
        isEnabled: j['is_enabled'] as bool? ?? true,
        hour: j['hour'] as int? ?? 8,
        minute: j['minute'] as int? ?? 0,
        keyword: j['keyword'] as String? ?? '',
        targetContact: j['target_contact'] as String? ?? '',
        actionMessage: j['action_message'] as String? ?? '',
        lastTriggered: j['last_triggered'] != null ? DateTime.tryParse(j['last_triggered'] as String) : null,
        runCount: j['run_count'] as int? ?? 0,
      );

  final String id;
  String name;
  AutomationTriggerType triggerType;
  AutomationActionType actionType;
  bool isEnabled;
  int hour;
  int minute;
  String keyword;
  String targetContact;
  String actionMessage;
  DateTime? lastTriggered;
  int runCount;

  String get timeFormatted {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    final m = minute < 10 ? '0$minute' : '$minute';
    final ampm = hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  String get triggerSummary {
    switch (triggerType) {
      case AutomationTriggerType.timeOfDay:
        return 'Every day at $timeFormatted';
      case AutomationTriggerType.missedCall:
        return 'When a call is missed';
      case AutomationTriggerType.smsKeyword:
        return 'When SMS contains "$keyword"';
      case AutomationTriggerType.oneTapShortcut:
        return 'Manual 1-Tap Trigger';
    }
  }

  String get actionSummary {
    switch (actionType) {
      case AutomationActionType.sendSms:
        return 'Send SMS to $targetContact: "$actionMessage"';
      case AutomationActionType.makeCall:
        return 'Call $targetContact';
      case AutomationActionType.speakTts:
        return 'Speak aloud: "$actionMessage"';
      case AutomationActionType.showNotification:
        return 'Post alert: "$actionMessage"';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trigger_type': triggerType.name,
        'action_type': actionType.name,
        'is_enabled': isEnabled,
        'hour': hour,
        'minute': minute,
        'keyword': keyword,
        'target_contact': targetContact,
        'action_message': actionMessage,
        'last_triggered': lastTriggered?.toIso8601String(),
        'run_count': runCount,
      };
}

class AutomationService {
  AutomationService._();
  static final AutomationService instance = AutomationService._();

  static const String _kAutomationsKey = 'aarohi_manual_automations_v1';
  static const MethodChannel _notifChannel = MethodChannel('com.mithun.aarohi/notifications');
  static const MethodChannel _smsChannel = MethodChannel('com.mithun.aarohi/sms');
  static const MethodChannel _telChannel = MethodChannel('com.mithun.aarohi/telephony');

  List<AutomationRule> _rules = [];
  bool _initialized = false;

  List<AutomationRule> get rules => List.unmodifiable(_rules);

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_kAutomationsKey);

      if (rawList != null && rawList.isNotEmpty) {
        _rules = rawList
            .map((s) {
              try {
                return AutomationRule.fromJson(jsonDecode(s) as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<AutomationRule>()
            .toList();
      } else {
        // Pre-configure useful automation templates
        _rules = [
          AutomationRule(
            id: 'auto_1',
            name: 'Morning Voice Briefing',
            triggerType: AutomationTriggerType.timeOfDay,
            actionType: AutomationActionType.speakTts,
            hour: 7,
            minute: 30,
            actionMessage: "Good morning Mithun! Today is a great day. Check your schedule and stay focused.",
          ),
          AutomationRule(
            id: 'auto_2',
            name: 'Missed Call Auto-Reply',
            triggerType: AutomationTriggerType.missedCall,
            actionType: AutomationActionType.sendSms,
            targetContact: 'Caller',
            actionMessage: "Hi, I missed your call. I will get back to you shortly.",
          ),
          AutomationRule(
            id: 'auto_3',
            name: "Driving Quick Action",
            triggerType: AutomationTriggerType.oneTapShortcut,
            actionType: AutomationActionType.speakTts,
            actionMessage: "Driving mode active. I will handle your notifications and calls.",
          ),
          AutomationRule(
            id: 'auto_4',
            name: 'Night Sleep Alert',
            triggerType: AutomationTriggerType.timeOfDay,
            actionType: AutomationActionType.showNotification,
            hour: 22,
            minute: 30,
            actionMessage: "Time to wind down, log your day, and get restful sleep.",
          ),
        ];
        await _persistRules();
      }

      // Schedule time-based automations with AlarmManager
      for (final r in _rules) {
        if (r.isEnabled && r.triggerType == AutomationTriggerType.timeOfDay) {
          await _scheduleTimeRule(r);
        }
      }

      _initialized = true;
      debugPrint('AutomationService initialized with ${_rules.length} rules');
    } catch (e) {
      debugPrint('AutomationService init error: $e');
    }
  }

  Future<void> _scheduleTimeRule(AutomationRule r) async {
    final now = DateTime.now();
    var scheduled = DateTime(now.year, now.month, now.day, r.hour, r.minute, 0);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    final intId = (r.id.hashCode & 0x7FFFFFFF) % 100000;
    try {
      if (kIsWeb) {
        debugPrint('Scheduling automation alarm not supported on web');
        return;
      }
      await _notifChannel.invokeMethod('scheduleAlarm', {
        'id': intId,
        'title': '⚡ Automation: ${r.name}',
        'body': r.actionMessage.isNotEmpty ? r.actionMessage : r.actionSummary,
        'triggerAtMillis': scheduled.millisecondsSinceEpoch,
        'isDaily': true,
        'hour': r.hour,
        'minute': r.minute,
      });
    } catch (e) {
      debugPrint('Error scheduling automation alarm: $e');
    }
  }

  Future<void> _cancelTimeRule(AutomationRule r) async {
    if (kIsWeb) return;
    final intId = (r.id.hashCode & 0x7FFFFFFF) % 100000;
    try {
      await _notifChannel.invokeMethod('cancelAlarm', {'id': intId});
    } catch (_) {}
  }

  /// Execute an automation manually (or when triggered)
  Future<String> executeRule(AutomationRule r) async {
    r.lastTriggered = DateTime.now();
    r.runCount++;
    await _persistRules();

    switch (r.actionType) {
      case AutomationActionType.speakTts:
        await Tts.instance.speak(r.actionMessage, emotion: 0.7);
        return 'Spoke aloud: "${r.actionMessage}"';

      case AutomationActionType.showNotification:
        if (!kIsWeb) {
          try {
            await _notifChannel.invokeMethod('showNotification', {
              'title': '⚡ Automation: ${r.name}',
              'body': r.actionMessage,
            });
          } catch (_) {}
        }
        return 'Posted notification: "${r.actionMessage}"';

      case AutomationActionType.sendSms:
        if (kIsWeb) return 'SMS not available on web';
        final resolvedNumber = await _resolveContactNumber(r.targetContact);
        final numToSend = resolvedNumber ?? r.targetContact;
        try {
          await _smsChannel.invokeMethod('sendSms', {
            'phone': numToSend,
            'body': r.actionMessage,
          });
          return 'Sent SMS to $numToSend: "${r.actionMessage}"';
        } catch (e) {
          return 'Failed to send SMS: $e';
        }

      case AutomationActionType.makeCall:
        if (kIsWeb) return 'Phone calls not available on web';
        final resolvedNumber = await _resolveContactNumber(r.targetContact);
        final numToCall = resolvedNumber ?? r.targetContact;
        try {
          await _telChannel.invokeMethod('makeCall', {'phone': numToCall});
          return 'Initiated call to $numToCall';
        } catch (e) {
          return 'Failed to make call: $e';
        }
    }
  }

  Future<String?> _resolveContactNumber(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return null;
    final digits = clean.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.length >= 7) return digits;

    if (kIsWeb) return null;

    try {
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final lower = clean.toLowerCase();
      for (final c in contacts) {
        if (c.displayName.toLowerCase().contains(lower) && c.phones.isNotEmpty) {
          return c.phones.first.number.replaceAll(RegExp(r'[^0-9+]'), '');
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> toggleRule(String id, bool enabled) async {
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _rules[idx].isEnabled = enabled;
      if (enabled && _rules[idx].triggerType == AutomationTriggerType.timeOfDay) {
        await _scheduleTimeRule(_rules[idx]);
      } else {
        await _cancelTimeRule(_rules[idx]);
      }
      await _persistRules();
    }
  }

  Future<void> addRule(AutomationRule rule) async {
    _rules.add(rule);
    if (rule.isEnabled && rule.triggerType == AutomationTriggerType.timeOfDay) {
      await _scheduleTimeRule(rule);
    }
    await _persistRules();
  }

  Future<void> updateRule(AutomationRule rule) async {
    final idx = _rules.indexWhere((r) => r.id == rule.id);
    if (idx != -1) {
      _rules[idx] = rule;
      if (rule.isEnabled && rule.triggerType == AutomationTriggerType.timeOfDay) {
        await _scheduleTimeRule(rule);
      } else {
        await _cancelTimeRule(rule);
      }
      await _persistRules();
    }
  }

  Future<void> deleteRule(String id) async {
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx != -1) {
      await _cancelTimeRule(_rules[idx]);
      _rules.removeAt(idx);
      await _persistRules();
    }
  }

  Future<void> _persistRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _rules.map((r) => jsonEncode(r.toJson())).toList();
      await prefs.setStringList(_kAutomationsKey, list);

      // Backup to SD Card
      await SdCardService.instance.savePersonalModel({
        'automations': _rules.map((r) => r.toJson()).toList(),
        'automations_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error saving automations: $e');
    }
  }
}
