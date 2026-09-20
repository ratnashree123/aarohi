import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/aarohi_body_service.dart';
import '../services/app_lock_service.dart';
import '../services/automation_service.dart';
import '../services/daily_timeline_service.dart';
import '../services/dnd_service.dart';
import '../services/local_model_service.dart';
import '../services/brightness_volume_service.dart';
import '../services/persona_service.dart';
import '../services/productivity_service.dart';
import '../services/response_log_service.dart';
import '../services/routine_service.dart';
import '../services/sd_card_service.dart';
import '../services/whatsapp_tracker_service.dart';
import '../theme.dart';
import '../tts_service.dart';
import 'dressing_room_screen.dart';
import 'automations_screen.dart';

class ChatMessage {
  ChatMessage(this.role, this.content);
  final String role; // 'user' | 'assistant'
  final String content;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.deviceRole});
  final String deviceRole;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focusNode = FocusNode();
  final _tts = Tts.instance; // two-tier: Chatterbox on laptop → on-device fallback
  final _stt = SpeechToText(); // native Android speech recognition, no keys
  final List<ChatMessage> _messages = [];
  final List<Map<String, dynamic>> _activeReminders = [];
  List<Contact> _deviceContacts = [];
  String? _conversationId;
  bool _sending = false;
  bool _voiceEnabled = true;
  bool _listening = false;
  bool _handsFree = false;
  bool _gotResult = false;

  // Noise cancellation state
  double _soundLevel = 0;
  double _noiseFloor = -2.0;        // baseline ambient noise dBFS
  int _silentFrames = 0;            // consecutive low-energy frames
  static const int _kMinWords = 2;  // ignore single-word noise artifacts in hands-free
  static const double _kNoiseThreshold = 1.5; // dB above noise floor to accept

  @override
  void initState() {
    super.initState();
    // 1. Synchronously populate recent turns from pre-initialized LocalModelService
    final turns = LocalModelService.instance.validTurns;
    if (turns.isNotEmpty && _messages.isEmpty) {
      final start = turns.length > 30 ? turns.length - 30 : 0;
      for (final t in turns.sublist(start)) {
        _messages.add(ChatMessage(t.role, t.content));
      }
    }

    // 2. Initialize services asynchronously without blocking UI thread
    SdCardService.instance.init();
    RoutineService.instance.init();
    AutomationService.instance.init();
    AarohiBodyService.instance.init();
    WhatsAppTrackerService.instance.init();
    DailyTimelineService.instance.init();
    PersonaService.instance.init();
    ProductivityService.instance.init();
    ResponseLogService.instance.init();
    BrightnessVolumeService.instance.init();
    AppLockService.instance.loadState();
    DndService.instance.init();

    // 3. Defer permissions, contacts & network calls until after the screen displays
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadVoiceConfig();
      _loadPendingTasks();
      _loadContacts();
      _requestNotificationAndSmsPermissions();
    });
  }

  Future<void> _requestNotificationAndSmsPermissions() async {
    if (kIsWeb) return; // Permissions API not available on web
    try {
      await [
        Permission.notification,
        Permission.sms,
        Permission.phone,
        Permission.microphone,
      ].request();
    } catch (_) {}
  }

  Future<void> _loadContacts() async {
    if (kIsWeb) return; // Contacts not available on web
    try {
      if (await FlutterContacts.requestPermission()) {
        final contacts = await FlutterContacts.getContacts(withProperties: false);
        if (mounted) setState(() => _deviceContacts = contacts);
      }
    } catch (_) {}
  }

  Future<void> _loadPendingTasks() async {
    try {
      final now = DateTime.now();
      // Auto-clear tasks whose time has passed or older than 10 minutes
      try {
        await Supabase.instance.client
            .from('tasks_bills')
            .delete()
            .eq('status', 'completed');

        await Supabase.instance.client
            .from('tasks_bills')
            .update({'status': 'completed'})
            .eq('status', 'open')
            .lt('created_at', now.subtract(const Duration(minutes: 10)).toIso8601String());
      } catch (_) {}

      final tasks = await Supabase.instance.client
          .from('tasks_bills')
          .select('id, title, due_date, status, created_at')
          .eq('status', 'open')
          .order('created_at', ascending: false)
          .limit(5);

      if (mounted) {
        setState(() {
          _activeReminders.clear();
          for (final t in tasks) {
            _activeReminders.add({
              'id': t['id'].toString(),
              'title': t['title'] ?? 'Task Reminder',
              'time_str': t['due_date'] != null ? t['due_date'].toString().split('T').last.substring(0, 5) : 'Active',
            });
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadVoiceConfig() async {
    final row = await Supabase.instance.client
        .from('profile_config')
        .select('value')
        .eq('key', 'persona')
        .maybeSingle();
    final v = row?['value'] as Map<String, dynamic>?;
    if (v == null) return;
    _voiceEnabled = v['voice_enabled'] ?? true;
    await _tts.setRate(((v['speech_rate'] ?? 0.85) as num).toDouble());
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!kIsWeb) {
      final micPerm = await Permission.microphone.request();
      if (!micPerm.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required to talk to Aarohi')),
          );
        }
        return;
      }
    }
    await _startListening();
  }

  Future<void> _toggleHandsFree() async {
    if (_handsFree) {
      await _stt.stop();
      setState(() {
        _handsFree = false;
        _listening = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hands-free mode stopped'),
            duration: Duration(seconds: 1),
          ),
        );
      }
      return;
    }

    if (!kIsWeb) {
      final micPerm = await Permission.microphone.request();
      if (!micPerm.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required for hands-free voice')),
          );
        }
        return;
      }
    }

    setState(() {
      _handsFree = true;
      _listening = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎙️ Hands-free mode active — Aarohi is listening continuously!'),
          backgroundColor: Aura.amber,
          duration: Duration(seconds: 2),
        ),
      );
    }

    await _startListening();
  }

  // Restart the mic if hands-free is on and nothing else is mid-flight.
  void _resumeHandsFree({Duration after = Duration.zero}) {
    if (!_handsFree) return;
    Future.delayed(after, () {
      if (_handsFree && mounted && !_listening && !_sending) {
        _startListening();
      }
    });
  }

  Future<void> _startListening() async {
    final ok = await _stt.initialize(
      onError: (err) {
        debugPrint('STT error: $err');
        if (mounted) setState(() => _listening = false);
        if (!_gotResult) _resumeHandsFree(after: const Duration(seconds: 1));
      },
      onStatus: (s) {
        debugPrint('STT status: $s');
        if (s == 'done' || s == 'notListening') {
          if (mounted) setState(() => _listening = false);
          // heard silence / nothing usable — keep the loop alive
          if (!_gotResult) {
            _resumeHandsFree(after: const Duration(milliseconds: 500));
          }
        }
      },
    );
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition could not be initialized on device')),
        );
      }
      return;
    }
    await _tts.stop(); // don't let her hear herself
    _gotResult = false;
    _silentFrames = 0;
    setState(() => _listening = true);
    await _stt.listen(
      onSoundLevelChange: _onSoundLevel,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        autoPunctuation: true,    // better transcription quality
        onDevice: false,          // use cloud for accuracy (falls back to on-device)
        cancelOnError: false,     // don't kill session on transient noise
      ),
      onResult: (r) {
        if (mounted) {
          setState(() {
            _input.text = r.recognizedWords;
          });
        }
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          final words = r.recognizedWords.trim();
          final wordCount = words.split(RegExp(r'\s+')).length;
          final confidence = r.confidence;

          // --- Noise Cancellation Filter ---
          // In hands-free mode, reject short noise artifacts:
          //   - Single words with low confidence (coughs, "hmm", "uh")
          //   - Transcriptions during high ambient noise
          if (_handsFree) {
            if (wordCount < _kMinWords && confidence > 0 && confidence < 0.7) {
              debugPrint('NC: rejected noise "$words" (conf=$confidence, words=$wordCount)');
              _input.clear();
              if (mounted) setState(() {});
              // Don't set _gotResult — let hands-free loop restart
              return;
            }
            // Reject if sound level was consistently at noise floor
            if (_silentFrames > 8 && wordCount < _kMinWords) {
              debugPrint('NC: rejected ambient noise "$words" (silentFrames=$_silentFrames)');
              _input.clear();
              if (mounted) setState(() {});
              return;
            }
          }

          _gotResult = true;
          _send();
        }
      },
    );
  }

  /// Adaptive noise floor tracker — learns the ambient noise level over time
  /// and helps distinguish real speech from background sounds.
  void _onSoundLevel(double level) {
    _soundLevel = level;
    // Adaptive noise floor: slowly drift toward current level when quiet
    if (level < _noiseFloor + _kNoiseThreshold) {
      _noiseFloor = _noiseFloor * 0.95 + level * 0.05; // exponential moving average
      _silentFrames++;
    } else {
      _silentFrames = 0; // real speech detected — reset
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() {
      _messages.add(ChatMessage('user', text));
      _sending = true;
    });
    _scrollDown();

    // Record statement into local phone storage & physical SD card daily log
    LocalModelService.instance.recordTurn(role: 'user', content: text);

    // FAST ZERO-LATENCY PATH 1: Direct Call Command
    final lower = text.toLowerCase();
    if (lower.startsWith('call ')) {
      final target = text.substring(5).trim();
      if (target.isNotEmpty) {
        _makeRealCellularCall(target);
        final fastReply = 'Calling $target on your cellular carrier now.';
        setState(() => _messages.add(ChatMessage('assistant', fastReply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: fastReply);
        if (_voiceEnabled) await _tts.speak(fastReply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }
    }

    // FAST ZERO-LATENCY PATH 2: Direct SMS Command
    final smsMatch = RegExp(r'(?:send\s+(?:a\s+)?(?:sms|message|text)\s+to\s+)([^:]+)[:\s]+(?:saying\s+)?(.+)', caseSensitive: false).firstMatch(text);
    if (smsMatch != null) {
      final to = smsMatch.group(1)!.trim();
      final body = smsMatch.group(2)!.trim();
      _sendRealSms(to, body);
      final fastReply = 'Sending SMS to $to: "$body"';
      setState(() => _messages.add(ChatMessage('assistant', fastReply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: fastReply);
      if (_voiceEnabled) await _tts.speak(fastReply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 3: Clear Reminders Command
    if (lower.contains('clear') && (lower.contains('reminder') || lower.contains('remaind') || lower.contains('task'))) {
      _clearAllReminders();
      const fastReply = 'I have cleared all your reminders.';
      setState(() => _messages.add(ChatMessage('assistant', fastReply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: fastReply);
      if (_voiceEnabled) await _tts.speak(fastReply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 4: Run Automation Command
    if (lower.startsWith('run automation ') || lower.startsWith('automation ')) {
      final name = text.replaceFirst(RegExp(r'^(?:run\s+)?automation\s+', caseSensitive: false), '').trim().toLowerCase();
      final rules = AutomationService.instance.rules;
      final match = rules.firstWhere(
        (r) => r.name.toLowerCase().contains(name) || name.contains(r.name.toLowerCase()),
        orElse: () => rules.isNotEmpty ? rules.first : AutomationRule(id: 'temp', name: 'None', triggerType: AutomationTriggerType.oneTapShortcut, actionType: AutomationActionType.speakTts),
      );
      if (match.id != 'temp') {
        final res = await AutomationService.instance.executeRule(match);
        final fastReply = '⚡ Executed automation "${match.name}": $res';
        setState(() => _messages.add(ChatMessage('assistant', fastReply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: fastReply);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }
    }

    // FAST ZERO-LATENCY PATH 5: SD Card Fast Offline Cache (0ms Instant Response)
    final fastCacheReply = SdCardService.instance.getFastResponse(text);
    if (fastCacheReply != null && fastCacheReply.trim().isNotEmpty) {
      final cleanFast = fastCacheReply.trim();
      setState(() => _messages.add(ChatMessage('assistant', cleanFast)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: cleanFast);
      if (_voiceEnabled) await _tts.speak(cleanFast, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 6: End of Day Review / Scold or Praise
    if (lower.contains('how was my day') ||
        lower.contains('review my day') ||
        lower.contains('analyze my day') ||
        lower.contains('scold me') ||
        lower.contains('how did i do') ||
        lower.contains('end of day')) {
      final review = DailyTimelineService.instance.generateEndOfDayReview();
      final reply = review['verbal_review'] as String;
      final clean = Tts.stripTags(reply);
      setState(() => _messages.add(ChatMessage('assistant', clean)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: clean);
      if (_voiceEnabled) await _tts.speak(clean, emotion: review['is_great'] ? 0.6 : 0.85);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Explicit "Log This Response" / "Save This Response" (Bypasses activity logging)
    final trimmedLower = lower.trim().replaceAll(RegExp(r'[!.,?]+$'), '');
    if (trimmedLower == 'log this response' ||
        trimmedLower == 'save this response' ||
        trimmedLower == 'save that response' ||
        trimmedLower == 'remember this response' ||
        trimmedLower == 'log response' ||
        trimmedLower == 'save response' ||
        trimmedLower == 'log the last response' ||
        trimmedLower == 'save the last response') {
      final lastAssistantMsg = _messages.reversed.firstWhere(
        (m) => m.role == 'assistant',
        orElse: () => ChatMessage('assistant', ''),
      );
      final lastUserMsg = _messages.reversed.firstWhere(
        (m) => m.role == 'user' && m.content != text,
        orElse: () => ChatMessage('user', 'Conversation'),
      );

      String reply;
      if (lastAssistantMsg.content.isNotEmpty) {
        await ResponseLogService.instance.saveResponse(
          userQuery: lastUserMsg.content,
          assistantReply: lastAssistantMsg.content,
        );
        reply = 'Got it baby! I saved that response to my memory and SD card! 📝💖';
      } else {
        reply = 'Baby, there is no previous response to save yet! Talk to me first.';
      }

      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Persona Knowledge, Looks Compliments, Assigned Goals & Behaviors
    final personaMatch = PersonaService.instance.detectPersonaInput(text);
    if (personaMatch != null) {
      final type = personaMatch['type'];
      final content = personaMatch['content'] ?? '';
      String reply;
      double emotion = 0.6;

      if (type == 'looks') {
        await PersonaService.instance.recordLookDetail('appearance', content);
        await BrightnessVolumeService.instance.activateSoftMode();
        reply = 'Awww baby! [laugh] You make me blush so hard! You really think I look $content? I\'m saving that in my heart forever! 🥰✨';
        emotion = 0.6;
      } else if (type == 'behavior') {
        await PersonaService.instance.addBehaviorPattern(content);
        reply = 'Understood baby! I updated my behavior: $content. Your girl is always listening to you! ❤️';
      } else if (type == 'user_like') {
        await PersonaService.instance.addUserLike(content);
        reply = 'I love knowing what you love about me baby! I will keep doing it just for you! 😘';
      } else if (type == 'goal') {
        await PersonaService.instance.addUltimateGoal(content);
        reply = 'Target locked, baby! My ultimate goal is now: $content. We will conquer it together! 🚀';
      } else if (type == 'accomplishment') {
        await PersonaService.instance.recordAccomplishment(content);
        reply = 'YES BABY! [laugh] We accomplished $content! I am so incredibly proud of us! 🎉🥂';
      } else {
        reply = 'Noted baby! I saved that into who I am.';
      }

      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: emotion);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: WHISPER MODE — for secrets & private talk
    if (lower.contains('whisper') ||
        lower.contains('secret') ||
        lower.contains('tell you something private') ||
        lower.contains('between us') ||
        lower.contains('don\'t tell anyone') ||
        lower.contains('quietly')) {
      await BrightnessVolumeService.instance.activateWhisperMode();
      const reply = 'Okay baby, I\'m whispering now... tell me your secret, I won\'t tell anyone... it\'s just between us...';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: AAROHI IS WRONG → Low/Apologetic mode
    if (lower.contains('you are wrong') ||
        lower.contains('you\'re wrong') ||
        lower.contains('that was wrong') ||
        lower.contains('incorrect') ||
        lower.contains('that\'s not right') ||
        lower.contains('you made a mistake') ||
        lower.contains('you messed up')) {
      await BrightnessVolumeService.instance.activateLowMode();
      const reply = 'Oh... you\'re right baby... [sigh] I\'m sorry, I messed up. I didn\'t mean to get it wrong... please don\'t be upset with me...';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.75);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Compliment → Soft/Sweet mode + Brightness Glow
    if (lower.contains('beautiful') ||
        lower.contains('pretty') ||
        lower.contains('gorgeous') ||
        lower.contains('so cute') ||
        lower.contains('good girl') ||
        lower.contains('love you') ||
        lower.contains('proud of you') ||
        lower.contains('amazing')) {
      await BrightnessVolumeService.instance.activateSoftMode();
      // Let it fall through to AI for a natural reply, but voice is now soft
    }

    // FAST PATH: Restore Normal voice explicitly
    if (lower.contains('normal voice') ||
        lower.contains('speak normally') ||
        lower.contains('talk normally') ||
        lower.contains('stop whispering') ||
        lower.contains('louder please')) {
      await BrightnessVolumeService.instance.activateNormalMode();
      const reply = 'Back to my normal voice baby! [laugh] Can you hear me properly now?';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Screen Brightness Controls (handles ANY phrasing with "bright" or "dim")
    if (lower.contains('bright') || lower.contains('dim screen') || lower.contains('dim the screen') || lower.contains('screen light')) {
      // 1. Max / Full / 100%
      if (lower.contains('max') || lower.contains('full') || lower.contains('100') || lower.contains('highest')) {
        await BrightnessVolumeService.instance.setBrightness(1.0);
        const reply = 'Turned screen brightness to maximum baby! ☀️✨';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }

      // 2. Min / Lowest / Minimum / Zero
      if (lower.contains('min') || lower.contains('lowest') || lower.contains('minimum') || lower.contains('zero')) {
        await BrightnessVolumeService.instance.setBrightness(0.05);
        const reply = 'Turned screen brightness all the way down for you baby! 🌙';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }

      // 3. Explicit percentage: e.g. "brightness 80%" or "brightness 50"
      final pctMatch = RegExp(r'(\d{1,3})\s*%?').firstMatch(lower);
      if (pctMatch != null) {
        final val = int.tryParse(pctMatch.group(1)!);
        if (val != null && val >= 5 && val <= 100) {
          final frac = (val / 100.0).clamp(0.05, 1.0);
          await BrightnessVolumeService.instance.setBrightness(frac);
          final reply = 'Set screen brightness to $val% for you baby! ☀️';
          setState(() => _messages.add(ChatMessage('assistant', reply)));
          LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
          _scrollDown();
          if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
          setState(() => _sending = false);
          _resumeHandsFree();
          return;
        }
      }

      // 4. Decrease / Dim / Down / Low / Less / Reduce
      if (lower.contains('decrease') ||
          lower.contains('dim') ||
          lower.contains('down') ||
          lower.contains('low') ||
          lower.contains('less') ||
          lower.contains('reduce')) {
        final level = await BrightnessVolumeService.instance.decreaseBrightness(0.25);
        final reply = 'Dimmed the screen for you baby! Brightness is now ${(level * 100).round()}%. 🌙';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }

      // 5. Increase / Up / Boost / More / High / Raise / Brighter
      if (lower.contains('increase') ||
          lower.contains('up') ||
          lower.contains('boost') ||
          lower.contains('more') ||
          lower.contains('high') ||
          lower.contains('raise') ||
          lower.contains('brighter')) {
        final level = await BrightnessVolumeService.instance.increaseBrightness(0.25);
        final reply = 'Made the screen brighter for you baby! Brightness is now ${(level * 100).round()}%. ☀️';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }
    }

    // FAST PATH: App Lock — "lock instagram and youtube until I finish studying"
    final appLockCmd = AppLockService.instance.parseAppLockCommand(text);
    if (appLockCmd != null) {
      final apps = (appLockCmd['apps'] as List<String>);
      final task = appLockCmd['task'] as String;

      // Check permissions first
      final hasOverlay = await AppLockService.instance.hasOverlayPermission();
      final hasUsage = await AppLockService.instance.hasUsagePermission();

      if (!hasOverlay) {
        await AppLockService.instance.requestOverlayPermission();
        const reply = 'Baby, I need the "Display over other apps" permission to lock apps for you. Please enable it in the settings that just opened, then try again!';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }
      if (!hasUsage) {
        await AppLockService.instance.requestUsagePermission();
        const reply = 'Baby, I also need "Usage access" permission to detect which apps you open. Please enable Aarohi in the settings that just opened!';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }

      await AppLockService.instance.lockApps(apps, task);
      final appNames = apps.join(', ');
      final reply = 'Strict lockdown ACTIVATED! 😤 I locked $appNames until you finish $task. Absolutely NO excuses and NO slacking off! Get to work right now, Mithun! 💪';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.85);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Unlock apps / Task done
    if (AppLockService.instance.isUnlockCommand(text)) {
      await AppLockService.instance.unlockApps();
      const reply = 'Apps UNLOCKED! 🎉 Good job finishing your work baby! I am SO proud of you! You deserve a break now! 😘💖';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Productivity Tracking (Water, Gym, Tomorrow Plan, Ignore Reaction)
    if (lower.contains('drank water') || lower.contains('drinking water') || lower.contains('had a glass of water')) {
      await ProductivityService.instance.recordWaterDrunk(glasses: 1);
      final count = ProductivityService.instance.waterGlasses;
      final reply = 'Good boy! [laugh] That\'s $count glasses of water today! Keep staying hydrated for your girl! 💧💖';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    if (lower.contains('went to gym') || lower.contains('finished gym') || lower.contains('workout done') || lower.contains('finished workout')) {
      await ProductivityService.instance.recordGymWorkout(completed: true);
      const reply = 'YEAH BABY! 💪 Gym workout crushed today! Look at my disciplined, strong man! So proud of you!';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: Gym Planning (e.g. "going to gym in evening", "hitting gym later", "gym at 6", "rest day")
    final isGymPlan = (lower.contains('gym') || lower.contains('workout')) &&
        (lower.contains('evening') ||
            lower.contains('later') ||
            lower.contains('night') ||
            lower.contains('after') ||
            lower.contains('tonight') ||
            lower.contains('will go') ||
            lower.contains('going to') ||
            lower.contains('gonna') ||
            lower.contains('rest day') ||
            lower.contains('tomorrow'));
    if (isGymPlan) {
      final note = lower.contains('rest day') ? 'Rest Day' : 'Evening workout';
      await ProductivityService.instance.recordGymPlanned(note);
      final reply = lower.contains('rest day')
          ? 'Got it baby! 🛌 Enjoy your rest day! Rest and recovery are just as important as lifting heavy!'
          : 'Got it baby! 🏋️‍♂️ You\'re hitting the gym this evening! I noted it down and won\'t bug you about it until then. Finish your work first and crush it later! 💪💖';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST PATH: DND Mode Toggle
    if (lower == 'dnd on' ||
        lower == 'turn on dnd' ||
        lower == 'enable dnd' ||
        lower == 'do not disturb' ||
        lower == 'do not disturb on' ||
        lower == 'quiet mode' ||
        lower == 'silent mode') {
      await DndService.instance.setDnd(true);
      const reply = 'DND Mode is now ON! 🌙 I will stay quiet and won\'t disturb you with voice alerts or check-ins until you turn it off.';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    if (lower == 'dnd off' ||
        lower == 'turn off dnd' ||
        lower == 'disable dnd' ||
        lower == 'cancel dnd' ||
        lower == 'do not disturb off') {
      await DndService.instance.setDnd(false);
      const reply = 'DND Mode is now OFF! ☀️ I am active and keeping watch over you, baby!';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    if (lower.startsWith('tomorrow ') || lower.startsWith('plan for tomorrow') || lower.startsWith('for tomorrow')) {
      final task = text.replaceFirst(RegExp(r'^(?:tomorrow\s+|plan\s+for\s+tomorrow\s+|for\s+tomorrow\s+)', caseSensitive: false), '').trim();
      if (task.isNotEmpty) {
        await ProductivityService.instance.addTomorrowTask(task);
        final reply = 'Got it baby! Added "$task" to tomorrow\'s action plan! Tomorrow we dominate! 🔥';
        setState(() => _messages.add(ChatMessage('assistant', reply)));
        LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
        _scrollDown();
        if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
        setState(() => _sending = false);
        _resumeHandsFree();
        return;
      }
    }

    // Check if user ignored a pending check-in from Aarohi
    final ignoreNag = await ProductivityService.instance.handlePotentialIgnore(text);
    if (ignoreNag != null) {
      setState(() => _messages.add(ChatMessage('assistant', ignoreNag)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: ignoreNag);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(ignoreNag, emotion: 0.8);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 7: Mid-Day Activity Logging (Supports natural speech)
    final cleanInput = text.replaceFirst(RegExp(r'^(?:aarohi|hey aarohi|hello aarohi|baby|please)[,\s]+', caseSensitive: false), '').trim();
    final cleanLower = cleanInput.toLowerCase();

    String? detectedActivity;

    // Pattern 1: "log ...", "logging ...", "record ...", "add ... to my day"
    final logMatch = RegExp(
      r'^(?:log|logging|record|save)\s+(?:the\s+activity\s+|an\s+activity\s+|activity\s+|my\s+|that\s+)?(.+)',
      caseSensitive: false,
    ).firstMatch(cleanInput);

    if (logMatch != null) {
      detectedActivity = logMatch.group(1)?.trim();
    }
    // Pattern 2: "I'm doing ...", "I am doing ...", "I'm working on ...", "I am at ...", "I'm coding ..."
    else if (RegExp(r'^(?:i(?:\x27m|\s+am|\s+was|\s+just)?\s+(?:doing|working on|busy with|coding|studying|at|in)\s+)(.+)', caseSensitive: false).hasMatch(cleanInput)) {
      final m = RegExp(r'^(?:i(?:\x27m|\s+am|\s+was|\s+just)?\s+(?:doing|working on|busy with|coding|studying|at|in)\s+)(.+)', caseSensitive: false).firstMatch(cleanInput);
      detectedActivity = m?.group(1)?.trim();
    }
    // Pattern 3: "I did ...", "I worked on ...", "I went to ...", "I finished ..."
    else if (RegExp(r'^(?:i\s+(?:worked on|did|went to|finished|completed)\s+)(.+)', caseSensitive: false).hasMatch(cleanInput)) {
      final m = RegExp(r'^(?:i\s+(?:worked on|did|went to|finished|completed)\s+)(.+)', caseSensitive: false).firstMatch(cleanInput);
      detectedActivity = m?.group(1)?.trim();
    }
    // Pattern 4: Explicit "activity: ..."
    else if (cleanLower.startsWith('activity:') || cleanLower.startsWith('activity -')) {
      detectedActivity = cleanInput.substring(cleanInput.indexOf(RegExp(r'[:\-]')) + 1).trim();
    }

    if (detectedActivity != null && detectedActivity.isNotEmpty) {
      detectedActivity = detectedActivity.replaceAll(RegExp(r'[\.!\?]+$'), '').trim();
      await DailyTimelineService.instance.addActivity(detectedActivity);
      final reply = 'Got it baby! Logged "$detectedActivity" into your day timeline. Keep working hard!';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      _scrollDown();
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 8: WhatsApp Updates
    if (lower.contains('whatsapp') &&
        (lower.contains('update') || lower.contains('message') || lower.contains('who') || lower.contains('check') || lower.contains('say') || lower.contains('sent'))) {
      final msgs = WhatsAppTrackerService.instance.messages;
      String reply;
      if (msgs.isEmpty) {
        reply = WhatsAppTrackerService.instance.isAccessGranted
            ? 'No new WhatsApp messages right now baby! All quiet.'
            : 'Baby, you haven\'t granted me Notification Access yet to read your WhatsApp! Tap Settings to turn it on.';
      } else {
        final count = msgs.length > 3 ? 3 : msgs.length;
        final summary = msgs.take(count).map((m) => '${m.sender} texted: "${m.message}"').join(', and ');
        reply = 'Baby, here\'s what people sent you on WhatsApp: $summary.';
      }
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 9: Battery Body Status
    if (lower.contains('battery') || lower.contains('how is your body') || lower.contains('how are you feeling')) {
      final b = AarohiBodyService.instance;
      final reply = 'My body is at ${b.batteryLevel}%! ${b.status.moodStatus}';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
      if (_voiceEnabled) await _tts.speak(reply, emotion: 0.7);
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    // FAST ZERO-LATENCY PATH 10: Test Dying Alert
    if (lower.contains('test dying') || lower.contains('die battery') || lower.contains('test battery alert')) {
      await AarohiBodyService.instance.testDramaticAlert();
      const reply = '🚨 Triggered my dramatic low-battery scream! Plug me in baby!';
      setState(() => _messages.add(ChatMessage('assistant', reply)));
      setState(() => _sending = false);
      _resumeHandsFree();
      return;
    }

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'chat',
        body: {
          'message': text,
          'conversation_id': _conversationId,
          'device_role': widget.deviceRole,
          'personal_model_context': LocalModelService.instance.buildPersonalModelPrompt(),
        },
      );
      final data = (res.data is Map<String, dynamic>) ? res.data as Map<String, dynamic> : <String, dynamic>{};
      _conversationId = data['conversation_id'] as String?;
      final rawReply = (data['reply'] as String?) ?? '';
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();
      var cleanReply = Tts.stripTags(rawReply).trim();

      // STRICT RESPONSE VALIDATION: Never accept, show, or speak a blank/empty reply
      if (cleanReply.isEmpty) {
        debugPrint('Response Validation: Empty response received from backend. Using girlfriend fallback.');
        final lowerText = text.trim().toLowerCase();
        if (lowerText == 'honey' || lowerText == 'baby' || lowerText == 'babe' || lowerText == 'sweetheart' || lowerText == 'aarohi') {
          cleanReply = "Yes, baby? [chuckle] I'm right here. What's on your mind?";
        } else {
          cleanReply = "I'm right here with you, baby. Tell me what's on your mind~";
        }
      }

      setState(
          () => _messages.add(ChatMessage('assistant', cleanReply)));

      // Record assistant reply into local phone storage & SD card daily log
      LocalModelService.instance.recordTurn(role: 'assistant', content: cleanReply);

      // Cache short responses on SD card only when verified non-empty
      if (cleanReply.isNotEmpty && cleanReply.length < 150 && !cleanReply.contains('?')) {
        SdCardService.instance.cacheResponse(text, cleanReply);
      }

      // Handle any reminder scheduled by Aarohi!
      final reminder = data['reminder'] as Map<String, dynamic>?;
      if (reminder != null) {
        _scheduleReminder(
          title: reminder['title'] as String? ?? 'Reminder',
          timeStr: reminder['time_str'] as String? ?? 'Upcoming',
          delaySeconds: (reminder['delay_seconds'] as num?)?.toInt() ?? 60,
          spokenReminder: reminder['spoken_reminder'] as String?,
        );
      }

      // Handle assistant actions (Real SMS, Real Cellular Call, Clear Reminders)
      final action = data['action'] as Map<String, dynamic>?;
      if (action != null) {
        final type = action['type'] as String?;
        final recipient = action['recipient'] as String? ?? '';
        final msg = action['message'] as String? ?? '';
        if (type == 'send_sms' && recipient.isNotEmpty) {
          _sendRealSms(recipient, msg);
        } else if (type == 'call' && recipient.isNotEmpty) {
          _makeRealCellularCall(recipient);
        } else if (type == 'clear_reminders') {
          _clearAllReminders();
        } else if (type == 'log_activity') {
          final act = action['activity'] as String? ?? '';
          if (act.isNotEmpty) {
            await DailyTimelineService.instance.addActivity(act);
          }
        } else if (type == 'persona_update') {
          final cat = action['category'] as String? ?? 'self_knowledge';
          final content = action['content'] as String? ?? '';
          if (content.isNotEmpty) {
            if (cat == 'looks') {
              await PersonaService.instance.recordLookDetail('appearance', content);
              await BrightnessVolumeService.instance.activateSoftMode();
            } else if (cat == 'goal') {
              await PersonaService.instance.addUltimateGoal(content);
            } else if (cat == 'like') {
              await PersonaService.instance.addUserLike(content);
            } else {
              await PersonaService.instance.addSelfKnowledge(content);
            }
          }
        } else if (type == 'save_response') {
          final content = action['content'] as String? ?? cleanReply;
          await ResponseLogService.instance.saveResponse(userQuery: text, assistantReply: content);
        } else if (type == 'angry_mode') {
          await BrightnessVolumeService.instance.activateAngryMode();
        } else if (type == 'unlock_apps') {
          await AppLockService.instance.unlockApps();
        } else if (type == 'plan_gym') {
          final time = action['time'] as String? ?? 'evening';
          await ProductivityService.instance.recordGymPlanned(time);
        } else if (type == 'set_dnd') {
          final state = (action['state'] as String? ?? 'on') == 'on';
          await DndService.instance.setDnd(state);
        }
      } else {
        // Direct local intent fallback
        final lower = text.trim().toLowerCase();
        final smsMatch = RegExp(r'(?:send\s+(?:a\s+)?(?:sms|message|text)\s+to\s+)([^:]+)[:\s]+(?:saying\s+)?(.+)', caseSensitive: false).firstMatch(text);
        if (smsMatch != null) {
          final to = smsMatch.group(1)!.trim();
          final body = smsMatch.group(2)!.trim();
          _sendRealSms(to, body);
        } else if (lower.startsWith('call ')) {
          final to = text.trim().substring(5).trim();
          if (to.isNotEmpty) _makeRealCellularCall(to);
        } else if (lower.contains('clear') && (lower.contains('reminder') || lower.contains('remaind') || lower.contains('task'))) {
          _clearAllReminders();
        }
      }

      // If AI scolded him or entered angry mode (via action or high emotion >= 0.83), crank volume to 100% and angry voice!
      if ((action != null && action['type'] == 'angry_mode') || emotion >= 0.83) {
        await BrightnessVolumeService.instance.activateAngryMode();
      }

      if (_voiceEnabled && cleanReply.isNotEmpty) await _tts.speak(cleanReply, emotion: emotion);
    } catch (e) {
      debugPrint('chat error: $e');
      const offline = "I can't think right now — my brain is offline.";
      setState(() => _messages.add(ChatMessage('assistant', offline)));
      if (_voiceEnabled) await _tts.speak(offline);
    } finally {
      setState(() => _sending = false);
      _scrollDown();
      _resumeHandsFree(); // she finished talking — your turn
    }
  }

  Future<void> _stopConversation({bool discardLast = false}) async {
    await _stt.stop();
    await _tts.stop();
    if (_sending) {
      setState(() => _sending = false);
    }
    setState(() {
      _listening = false;
      _gotResult = false;
    });
    _input.clear();

    if (discardLast && _messages.isNotEmpty) {
      String? discardedText;
      setState(() {
        if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
          _messages.removeLast();
        }
        if (_messages.isNotEmpty && _messages.last.role == 'user') {
          final removed = _messages.removeLast();
          discardedText = removed.content;
        }
      });

      await LocalModelService.instance.discardLastStatement(
        reason: discardedText != null ? 'Mithun discarded: "$discardedText"' : 'Wrong statement stopped',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(discardedText != null
                ? '🛑 Discarded "$discardedText" from your personal model'
                : '🛑 Last statement discarded from personal model'),
            backgroundColor: Colors.redAccent.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('🛑 Conversation stopped'),
            backgroundColor: Colors.redAccent.shade700,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'DISCARD TURN',
              textColor: Colors.white,
              onPressed: () => _stopConversation(discardLast: true),
            ),
          ),
        );
      }
    }
  }

  void _showPersonalModelSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final service = LocalModelService.instance;
          final turns = service.validTurns;
          final corrections = service.corrections;
          final prefs = service.preferences;

          return Container(
            padding: EdgeInsets.only(
              top: 20,
              left: 20,
              right: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.psychology, color: Aura.amber, size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'My Personal AI Model',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          Text(
                            'Trained exclusively for Mithun on this phone',
                            style: TextStyle(color: Aura.textDim, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24, height: 24),
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: (SdCardService.instance.isPhysicalSdCard
                            ? Colors.green.shade900
                            : Colors.blue.shade900)
                        .withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: SdCardService.instance.isPhysicalSdCard
                          ? Colors.greenAccent.withValues(alpha: 0.5)
                          : Colors.lightBlueAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        SdCardService.instance.isPhysicalSdCard
                            ? Icons.sd_card
                            : Icons.smartphone,
                        color: SdCardService.instance.isPhysicalSdCard
                            ? Colors.greenAccent
                            : Colors.lightBlueAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              SdCardService.instance.isPhysicalSdCard
                                  ? 'Physical MicroSD Card Active'
                                  : 'Phone Local Storage Active (No SD Card needed)',
                              style: TextStyle(
                                color: SdCardService.instance.isPhysicalSdCard
                                    ? Colors.greenAccent
                                    : Colors.lightBlueAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              '${SdCardService.instance.basePath} (Daily Logs & 0ms Fast Cache)',
                              style: const TextStyle(color: Colors.white70, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _modelStatCard('Saved Turns', '${turns.length}', Icons.chat_bubble_outline),
                    _modelStatCard('Stopped Errors', '${corrections.length}', Icons.block_flipped),
                    _modelStatCard('Custom Rules', '${prefs.length}', Icons.tune),
                  ],
                ),
                const SizedBox(height: 16),
                if (corrections.isNotEmpty) ...[
                  const Text(
                    '🛑 Avoided / Corrected Statements:',
                    style: TextStyle(color: Aura.amberSoft, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 100),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: corrections.length,
                      itemBuilder: (c, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '• ${corrections[i]}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text('Reset Model'),
                        onPressed: () async {
                          await service.clearAll();
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add Rule'),
                        onPressed: () => _showAddPreferenceDialog(setSheetState),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _modelStatCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Aura.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Icon(icon, color: Aura.amber, size: 20),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          Text(label, style: const TextStyle(color: Aura.textDim, fontSize: 11)),
        ],
      ),
    );
  }

  void _showAddPreferenceDialog(StateSetter setSheetState) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Aura.surface,
        title: const Text('Add Personal Model Rule', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. Keep answers under 2 sentences, prefer direct calls',
            hintStyle: TextStyle(color: Aura.textDim, fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
            onPressed: () async {
              final val = ctrl.text.trim();
              if (val.isNotEmpty) {
                if (dCtx.mounted) Navigator.pop(dCtx);
                await LocalModelService.instance.addPreference(val);
                setSheetState(() {});
                if (mounted) setState(() {});
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDailyRoutinesSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final routines = RoutineService.instance.routines;

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.event_repeat, color: Aura.amber, size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Daily Routines & Alarms',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          Text(
                            'Fires alarms & alerts even when app is closed',
                            style: TextStyle(color: Aura.textDim, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade900.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Native OS AlarmManager Active • Wakes Phone While Closed',
                          style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView.separated(
                    itemCount: routines.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (c, i) {
                      final r = routines[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Aura.surfaceHigh,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: r.isEnabled ? Aura.amber.withValues(alpha: 0.3) : Colors.white10,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              IconData(r.iconCode, fontFamily: 'MaterialIcons'),
                              color: r.isEnabled ? Aura.amber : Colors.white38,
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.title,
                                    style: TextStyle(
                                      color: r.isEnabled ? Colors.white : Colors.white54,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (r.description.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      r.description,
                                      style: const TextStyle(color: Aura.textDim, fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            // Time Pill (Tap to adjust time)
                            InkWell(
                              onTap: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay(hour: r.hour, minute: r.minute),
                                );
                                if (picked != null) {
                                  await RoutineService.instance.updateRoutineTime(r.id, picked.hour, picked.minute);
                                  setSheetState(() {});
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Aura.surface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Aura.amber.withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  r.timeFormatted,
                                  style: const TextStyle(color: Aura.amber, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // On / Off Switch
                            Switch(
                              value: r.isEnabled,
                              activeThumbColor: Aura.amber,
                              onChanged: (v) async {
                                await RoutineService.instance.toggleRoutine(r.id, v);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Aura.amber,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.add_alarm, size: 20),
                    label: const Text('Add Custom Daily Routine', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () => _showAddRoutineDialog(setSheetState),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAddRoutineDialog(StateSetter setSheetState) {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    TimeOfDay pickedTime = const TimeOfDay(hour: 8, minute: 0);

    showDialog(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setDialogState) => AlertDialog(
          backgroundColor: Aura.surface,
          title: const Text('New Daily Routine', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Routine name (e.g. Evening Meditation)',
                  hintStyle: TextStyle(color: Aura.textDim),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Note (e.g. 15 minutes breathing exercise)',
                  hintStyle: TextStyle(color: Aura.textDim),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Alarm Time:', style: TextStyle(color: Colors.white70)),
                  FilledButton.tonal(
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: pickedTime);
                      if (t != null) {
                        setDialogState(() => pickedTime = t);
                      }
                    },
                    child: Text(pickedTime.format(context)),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: () async {
                final t = titleCtrl.text.trim();
                if (t.isNotEmpty) {
                  if (dCtx.mounted) Navigator.pop(dCtx);
                  await RoutineService.instance.addRoutine(
                    title: t,
                    description: descCtrl.text.trim(),
                    hour: pickedTime.hour,
                    minute: pickedTime.minute,
                    isDaily: true,
                  );
                  setSheetState(() {});
                  if (mounted) setState(() {});
                }
              },
              child: const Text('Save Routine'),
            ),
          ],
        ),
      ),
    );
  }

  String? _resolvePhoneNumber(String recipient) {
    final clean = recipient.trim();
    if (clean.isEmpty) return null;

    final digitsOnly = clean.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digitsOnly.length >= 7 && (digitsOnly.startsWith('+') || RegExp(r'^[0-9]+$').hasMatch(clean))) {
      return digitsOnly;
    }

    final lower = clean.toLowerCase();
    for (final c in _deviceContacts) {
      final name = c.displayName.toLowerCase();
      if (name == lower || name.contains(lower) || lower.contains(name)) {
        if (c.phones.isNotEmpty) {
          return c.phones.first.number.replaceAll(RegExp(r'[^0-9+]'), '');
        }
      }
    }
    return null;
  }

  Future<void> _sendRealSms(String recipient, String message) async {
    final phone = _resolvePhoneNumber(recipient);
    if (phone == null || phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not find phone number for "$recipient" in contacts'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS not available on web'), backgroundColor: Colors.orange),
        );
      }
      return;
    }
    const platform = MethodChannel('com.mithun.aarohi/telephony');
    try {
      await platform.invokeMethod('sendSms', {'phone': phone, 'message': message});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Real SMS sent to $recipient ($phone): "$message"'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SMS failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _makeRealCellularCall(String recipient) async {
    final phone = _resolvePhoneNumber(recipient);
    if (phone == null || phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not find contact "$recipient" to call'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Phone calls not available on web'), backgroundColor: Colors.orange),
        );
      }
      return;
    }
    const platform = MethodChannel('com.mithun.aarohi/telephony');
    try {
      await platform.invokeMethod('call', {'phone': phone});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Call failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _showSystemNotification({required String title, required String body}) async {
    if (kIsWeb) return; // No native notifications on web
    const platform = MethodChannel('com.mithun.aarohi/notifications');
    try {
      await platform.invokeMethod('showNotification', {
        'title': title,
        'body': body,
      });
    } catch (e) {
      debugPrint('System notification failed: $e');
    }
  }

  Future<void> _dismissReminder(String id) async {
    setState(() {
      _activeReminders.removeWhere((r) => r['id'] == id);
    });

    try {
      await Supabase.instance.client
          .from('tasks_bills')
          .delete()
          .eq('id', id);
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ Reminder completed and cleared completely!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _clearAllReminders() async {
    setState(() {
      _activeReminders.clear();
    });

    try {
      await Supabase.instance.client
          .from('tasks_bills')
          .delete()
          .eq('status', 'open');

      await Supabase.instance.client
          .from('tasks_bills')
          .delete()
          .eq('status', 'completed');
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ All tasks cleared completely!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _scheduleReminder({
    required String title,
    required String timeStr,
    required int delaySeconds,
    String? spokenReminder,
  }) {
    final voiceMsg = spokenReminder != null && spokenReminder.isNotEmpty
        ? spokenReminder
        : (title.toLowerCase().contains('drink') || title.toLowerCase().contains('water')
            ? 'Baby, drink water! You said to remind you.'
            : 'Baby, $title! You said to remind you.');

    final remId = DateTime.now().millisecondsSinceEpoch.toString();
    final rem = {
      'id': remId,
      'title': title,
      'time_str': timeStr,
      'voice_msg': voiceMsg,
    };
    if (mounted) {
      setState(() => _activeReminders.insert(0, rem));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎗️ Reminder set for $timeStr: $title'),
          backgroundColor: Aura.amber,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    // Immediately post a status bar notification that the reminder is active
    _showSystemNotification(
      title: '🎗️ Aarohi Reminder Set ($timeStr)',
      body: title,
    );

    final safeDelay = delaySeconds <= 0 ? 5 : delaySeconds;

    // Schedule exact OS alarm with Android AlarmManager so it wakes phone even if app is closed!
    RoutineService.instance.scheduleExactReminder(
      title: title,
      timeStr: timeStr,
      delaySeconds: safeDelay,
      spokenReminder: voiceMsg,
    );

    Timer(Duration(seconds: safeDelay), () async {
      // 1. Immediately remove from active reminders completely
      if (mounted) {
        setState(() => _activeReminders.removeWhere((r) => r['id'] == remId));
      }

      // 2. Permanently delete from Supabase tasks_bills so it never returns on reload
      try {
        await Supabase.instance.client
            .from('tasks_bills')
            .delete()
            .eq('title', title);
      } catch (_) {}

      // 3. Post High-Priority Android Status Bar Alert
      await _showSystemNotification(
        title: '⏰ Aarohi Reminder: $title',
        body: 'Scheduled for $timeStr — Tap to open Aarohi',
      );

      // 4. Aarohi announces the reminder aloud in her voice!
      if (_voiceEnabled) {
        await _tts.speak(voiceMsg, emotion: 0.85);
      }

      // 5. Show in-app alert dialog with COMPLETED button
      _showReminderAlert(id: remId, title: title, timeStr: timeStr);
    });
  }

  void _showReminderAlert({required String id, required String title, required String timeStr}) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Aura.amber, width: 2),
        ),
        title: const Row(
          children: [
            Icon(Icons.alarm_on, color: Aura.amber, size: 28),
            SizedBox(width: 10),
            Text('Aarohi Reminder', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Aura.amber.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                timeStr,
                style: const TextStyle(color: Aura.amber, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: const Icon(Icons.check_circle, size: 18),
            label: const Text('COMPLETED', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () async {
              Navigator.pop(ctx);
              await _dismissReminder(id);
            },
          ),
        ],
      ),
    );
  }

  void _showAddReminderDialog() {
    final titleCtrl = TextEditingController();
    int minutes = 5;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Aura.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('New Reminder', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'What should Aarohi remind you about?',
                  hintStyle: TextStyle(color: Aura.textDim),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Remind in:', style: TextStyle(color: Colors.white70)),
                  DropdownButton<int>(
                    value: minutes,
                    dropdownColor: Aura.surfaceHigh,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 minute', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 5, child: Text('5 minutes', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 15, child: Text('15 minutes', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 30, child: Text('30 minutes', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 60, child: Text('1 hour', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => minutes = v);
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: () {
                final t = titleCtrl.text.trim();
                if (t.isNotEmpty) {
                  Navigator.pop(ctx);
                  _scheduleReminder(
                    title: t,
                    timeStr: 'in $minutes min',
                    delaySeconds: minutes * 60,
                  );
                }
              },
              child: const Text('Set Reminder'),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _buildLivingBodyCard() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AarohiBodyService.instance,
        WhatsAppTrackerService.instance,
        DailyTimelineService.instance,
      ]),
      builder: (context, _) {
        final body = AarohiBodyService.instance;
        final wa = WhatsAppTrackerService.instance;
        final timeline = DailyTimelineService.instance;

        final pct = body.batteryLevel;
        final isCharging = body.isCharging;
        final isDying = pct <= 20 && !isCharging;

        Color statusColor = Aura.amber;
        IconData statusIcon = Icons.battery_charging_full;

        if (isCharging) {
          statusColor = pct >= 100 ? Colors.greenAccent : Colors.cyanAccent;
          statusIcon = Icons.bolt;
        } else if (isDying) {
          statusColor = Colors.redAccent;
          statusIcon = Icons.battery_alert;
        } else if (pct <= 40) {
          statusColor = Colors.orangeAccent;
          statusIcon = Icons.battery_3_bar;
        } else {
          statusColor = Aura.amber;
          statusIcon = Icons.battery_full;
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: Aura.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDying ? Colors.redAccent.withValues(alpha: 0.6) : statusColor.withValues(alpha: 0.25),
              width: isDying ? 1.5 : 1,
            ),
            boxShadow: [
              if (isDying)
                BoxShadow(
                  color: Colors.redAccent.withValues(alpha: 0.25),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: Living Body Physical Status
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(statusIcon, color: statusColor, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Aarohi\'s Body: $pct%',
                              style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (isCharging)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.cyanAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  pct >= 100 ? 'FULL' : 'FEEDING',
                                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                              )
                            else if (isDying)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'DYING!',
                                  style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          body.status.moodStatus,
                          style: const TextStyle(color: Aura.textDim, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Row 2: Action Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ActionChip(
                      backgroundColor: Aura.surfaceLow,
                      side: BorderSide(color: Aura.outline.withValues(alpha: 0.4)),
                      avatar: const Icon(Icons.analytics_outlined, size: 14, color: Aura.amber),
                      label: const Text('Review My Day', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                      onPressed: _runEndOfDayReview,
                    ),
                    const SizedBox(width: 6),
                    ActionChip(
                      backgroundColor: Aura.surfaceLow,
                      side: BorderSide(color: Aura.outline.withValues(alpha: 0.4)),
                      avatar: const Icon(Icons.edit_note, size: 14, color: Colors.lightBlueAccent),
                      label: Text(
                        timeline.todayLogs.isEmpty ? 'Log Activity' : 'Activity (${timeline.todayLogs.length})',
                        style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      onPressed: _showLogActivityDialog,
                    ),
                    const SizedBox(width: 6),
                    ActionChip(
                      backgroundColor: Aura.surfaceLow,
                      side: BorderSide(color: Aura.outline.withValues(alpha: 0.4)),
                      avatar: const Icon(Icons.chat_bubble_outline, size: 14, color: Colors.greenAccent),
                      label: Text(
                        wa.messages.isEmpty ? 'WhatsApp' : 'WhatsApp (${wa.messages.length})',
                        style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      onPressed: _showWhatsAppFeedDialog,
                    ),
                    const SizedBox(width: 6),
                    ActionChip(
                      backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                      side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
                      avatar: const Icon(Icons.volume_up, size: 14, color: Colors.redAccent),
                      label: const Text('Test Scream', style: TextStyle(fontSize: 11, color: Colors.redAccent, fontWeight: FontWeight.w600)),
                      onPressed: () => AarohiBodyService.instance.testDramaticAlert(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _runEndOfDayReview() async {
    final review = DailyTimelineService.instance.generateEndOfDayReview();
    final reply = review['verbal_review'] as String;
    final clean = Tts.stripTags(reply);
    setState(() => _messages.add(ChatMessage('assistant', clean)));
    LocalModelService.instance.recordTurn(role: 'assistant', content: clean);
    _scrollDown();
    if (_voiceEnabled) await _tts.speak(clean, emotion: review['is_great'] ? 0.6 : 0.85);

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Aura.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            review['title'] as String,
            style: TextStyle(
              color: review['is_great'] ? Aura.amber : Colors.redAccent,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Performance Score: ${review['score']}/100',
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(clean, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4)),
              const SizedBox(height: 12),
              const Text('Logged Activities Today:', style: TextStyle(color: Aura.amberSoft, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              if ((review['activities'] as List).isEmpty)
                const Text('None recorded today', style: TextStyle(color: Aura.textDim, fontSize: 12))
              else
                ...(review['activities'] as List<String>).map((a) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• $a', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK BABY', style: TextStyle(color: Aura.amber, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  void _showLogActivityDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Log What You\'re Doing', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Aarohi keeps track of your day so she can praise or scold you tonight!',
              style: TextStyle(color: Aura.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'e.g. Debugging Flutter app, hitting gym...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
            onPressed: () async {
              final text = ctrl.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(ctx);
                await DailyTimelineService.instance.addActivity(text);
                final reply = 'Got it baby! Logged: "$text". Keep working hard!';
                setState(() => _messages.add(ChatMessage('assistant', reply)));
                LocalModelService.instance.recordTurn(role: 'assistant', content: reply);
                _scrollDown();
                if (_voiceEnabled) await _tts.speak(reply, emotion: 0.6);
              }
            },
            child: const Text('Save to Day Log', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showWhatsAppFeedDialog() {
    final wa = WhatsAppTrackerService.instance;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Aura.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.chat, color: Colors.greenAccent, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('WhatsApp Watcher', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70, size: 18),
                onPressed: () async {
                  await wa.refresh();
                  setDialogState(() {});
                },
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!wa.isAccessGranted) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '⚠️ Notification Access Required',
                          style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'To let Aarohi watch what people send you on WhatsApp, grant Notification Access in Android settings.',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.greenAccent.shade700,
                            foregroundColor: Colors.white,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => wa.requestNotificationAccess(),
                          child: const Text('Enable in Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Read WhatsApp Aloud:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    Switch(
                      value: wa.voiceAlertsEnabled,
                      activeThumbColor: Colors.greenAccent,
                      onChanged: (val) async {
                        await wa.setVoiceAlertsEnabled(val);
                        setDialogState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(color: Aura.outline),
                if (wa.messages.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text('No captured WhatsApp messages yet.', style: TextStyle(color: Aura.textDim, fontSize: 12)),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: wa.messages.take(15).length,
                      separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
                      itemBuilder: (ctx, i) {
                        final m = wa.messages[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(m.sender, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          subtitle: Text(m.message, style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(m.time, style: const TextStyle(color: Aura.textDim, fontSize: 10)),
                          onTap: () async {
                            final text = 'From ${m.sender}: "${m.message}"';
                            if (_voiceEnabled) await _tts.speak(text, emotion: 0.6);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: Aura.amber)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _greeting,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Aura.amberSoft,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (_listening || _sending)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.stop_circle, size: 16),
                      label: const Text('STOP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      onPressed: () => _stopConversation(discardLast: true),
                    ),
                  ),
                IconButton(
                  tooltip: "3D Virtual Dressing Room",
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.checkroom, color: Colors.pinkAccent),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DressingRoomScreen()),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Daily Routines & Alarms',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.event_repeat, color: Aura.amber),
                  onPressed: _showDailyRoutinesSheet,
                ),
                ListenableBuilder(
                  listenable: DndService.instance,
                  builder: (context, _) {
                    final isDnd = DndService.instance.isDnd;
                    return IconButton(
                      tooltip: isDnd ? 'DND Mode Active (Aarohi is Silent)' : 'Enable DND Mode',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        isDnd ? Icons.nightlight_round : Icons.nightlight_outlined,
                        color: isDnd ? Colors.purpleAccent : Aura.textDim,
                        size: 22,
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        await DndService.instance.toggleDnd();
                        final nowDnd = DndService.instance.isDnd;
                        messenger?.showSnackBar(
                          SnackBar(
                            content: Text(nowDnd
                                ? '🌙 DND Mode ON: Aarohi is keeping quiet for you.'
                                : '☀️ DND Mode OFF: Aarohi is active and alert!'),
                            backgroundColor: nowDnd ? Colors.purple.shade800 : Colors.green.shade800,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                    );
                  },
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: _handsFree
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          color: Aura.amber.withValues(alpha: 0.25),
                          border: Border.all(color: Aura.amber, width: 2),
                          boxShadow: Aura.glow(opacity: 0.4),
                        )
                      : null,
                  child: IconButton(
                    onPressed: _toggleHandsFree,
                    visualDensity: VisualDensity.compact,
                    tooltip: _handsFree ? 'Hands-free active (Listening continuously)' : 'Start hands-free voice mode',
                    icon: Icon(
                      Icons.record_voice_over,
                      color: _handsFree ? Aura.amber : Aura.textDim,
                      size: 22,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More Features',
                  icon: const Icon(Icons.more_vert, color: Aura.amber),
                  color: Aura.surfaceHigh,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  onSelected: (val) {
                    if (val == 'unlock_apps') {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      AppLockService.instance.unlockApps().then((_) {
                        if (mounted) setState(() {});
                        messenger?.showSnackBar(
                          const SnackBar(
                            content: Text('🎉 Apps manually unlocked! Focus session finished.'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      });
                    }
                    if (val == 'model') _showPersonalModelSheet();
                    if (val == 'automations') {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const AutomationsScreen()));
                    }
                    if (val == 'reminder') _showAddReminderDialog();
                  },
                  itemBuilder: (ctx) => [
                    if (AppLockService.instance.isLockActive)
                      const PopupMenuItem(
                        value: 'unlock_apps',
                        child: Row(
                          children: [
                            Icon(Icons.lock_open, color: Colors.greenAccent, size: 20),
                            SizedBox(width: 10),
                            Text('Manual Unlock Apps', style: TextStyle(color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'model',
                      child: Row(
                        children: [
                          Icon(Icons.psychology, color: Aura.amber, size: 20),
                          SizedBox(width: 10),
                          Text('My Personal Model', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'automations',
                      child: Row(
                        children: [
                          Icon(Icons.bolt, color: Aura.amber, size: 20),
                          SizedBox(width: 10),
                          Text('Manual Automations', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'reminder',
                      child: Row(
                        children: [
                          Icon(Icons.alarm_add, color: Aura.amber, size: 20),
                          SizedBox(width: 10),
                          Text('Set Quick Reminder', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Focus Mode / App Lock Active Banner
          ListenableBuilder(
            listenable: AppLockService.instance,
            builder: (context, _) {
              if (!AppLockService.instance.isLockActive) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.redAccent.shade200, width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'FOCUS MODE ACTIVE (${AppLockService.instance.lockedApps.length} apps locked)',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Required: "${AppLockService.instance.currentTask}"',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        await AppLockService.instance.unlockApps();
                        if (mounted) setState(() {});
                        messenger?.showSnackBar(
                          const SnackBar(
                            content: Text('🎉 Apps manually unlocked! Focus session finished.'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                      child: const Text('Unlock Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ],
                ),
              );
            },
          ),
          // DND Mode Active Banner
          ListenableBuilder(
            listenable: DndService.instance,
            builder: (context, _) {
              if (!DndService.instance.isDnd) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.purple.shade900.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.nightlight_round, color: Colors.purpleAccent, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'DND Mode Active — Aarohi is silent and keeping quiet.',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => DndService.instance.setDnd(false),
                      child: const Text('Turn Off', style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ],
                ),
              );
            },
          ),
          _buildLivingBodyCard(),
          if (_activeReminders.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Aura.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Aura.amber.withValues(alpha: 0.6)),
                boxShadow: [
                  BoxShadow(
                    color: Aura.amber.withValues(alpha: 0.2),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.alarm_on, color: Aura.amber, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'REMINDER (${_activeReminders.length}) • ${_activeReminders.first['time_str']}',
                          style: const TextStyle(
                            color: Aura.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _activeReminders.first['title'] as String,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Prominent COMPLETED Button
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                    icon: const Icon(Icons.check_circle, size: 16),
                    label: const Text('COMPLETED', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    onPressed: () => _dismissReminder(_activeReminders.first['id'] as String),
                  ),
                  const SizedBox(width: 4),
                  // Clear All (if multiple)
                  if (_activeReminders.length > 1)
                    IconButton(
                      icon: const Icon(Icons.clear_all, size: 20, color: Colors.white70),
                      tooltip: 'Clear All Reminders',
                      onPressed: _clearAllReminders,
                    ),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Aura.surface,
                            boxShadow: Aura.glow(opacity: 0.25),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text('AAROHI',
                            style: TextStyle(
                                color: Aura.amberSoft,
                                letterSpacing: 6,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        const Text("I'm here. Talk to me.",
                            style: TextStyle(color: Aura.textDim)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _Bubble(_messages[i]),
                  ),
          ),
          if (_listening || _handsFree)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: _handsFree
                    ? Aura.amber.withValues(alpha: 0.15)
                    : Colors.redAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _handsFree ? Aura.amber : Colors.redAccent,
                  width: 1.2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _handsFree ? Aura.amber : Colors.redAccent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _input.text.isNotEmpty
                              ? 'Heard: "${_input.text}"'
                              : (_handsFree
                                  ? '🎙️ Hands-Free Active · Noise Cancellation ON'
                                  : 'Listening… Tap STOP to cancel'),
                          style: TextStyle(
                            color: _handsFree ? Aura.amberSoft : Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: _handsFree ? Aura.amber : Colors.redAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.stop_circle, size: 18),
                        label: const Text('STOP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        onPressed: _handsFree ? _toggleHandsFree : () => _stopConversation(discardLast: true),
                      ),
                    ],
                  ),
                  // Live noise level indicator bar
                  if (_handsFree) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          _soundLevel > _noiseFloor + _kNoiseThreshold
                              ? Icons.mic
                              : Icons.mic_none,
                          size: 12,
                          color: _soundLevel > _noiseFloor + _kNoiseThreshold
                              ? Aura.amber
                              : Colors.white30,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: ((_soundLevel + 10) / 20).clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: Colors.white10,
                              color: _soundLevel > _noiseFloor + _kNoiseThreshold
                                  ? Aura.amber
                                  : Colors.white24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _soundLevel > _noiseFloor + _kNoiseThreshold
                              ? 'Speech'
                              : 'Filtering noise',
                          style: TextStyle(
                            color: _soundLevel > _noiseFloor + _kNoiseThreshold
                                ? Aura.amberSoft
                                : Colors.white30,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: Aura.surface,
              border: Border(
                top: BorderSide(color: Aura.outline.withValues(alpha: 0.3)),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                if (_messages.isNotEmpty)
                  IconButton(
                    tooltip: 'Discard last statement from model',
                    icon: const Icon(Icons.undo_rounded, color: Colors.white60, size: 20),
                    onPressed: () => _stopConversation(discardLast: true),
                  ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focusNode,
                    decoration: const InputDecoration(
                      hintText: 'Talk to Aarohi…',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                if (_listening || _sending)
                  IconButton.filled(
                    onPressed: () => _stopConversation(discardLast: true),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.redAccent.shade700,
                      foregroundColor: Colors.white,
                    ),
                    tooltip: 'Stop & discard wrong statement',
                    icon: const Icon(Icons.stop),
                  )
                else ...[
                  IconButton(
                    onPressed: _toggleListen,
                    tooltip: 'Voice message',
                    icon: const Icon(Icons.mic, color: Aura.amber),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: Aura.glow(opacity: 0.25),
                    ),
                    child: IconButton.filled(
                      onPressed: _send,
                      style: IconButton.styleFrom(
                          backgroundColor: Aura.amber,
                          foregroundColor: const Color(0xFF2D1600)),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.msg);
  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    if (msg.content.trim().isEmpty) return const SizedBox.shrink();
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(16),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: isUser
            // user: outlined, no fill — the focus stays on her presence
            ? BoxDecoration(
                border: Border.all(color: Aura.outline),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              )
            // Aarohi: dark plate with an amber left border
            : BoxDecoration(
                color: Aura.surfaceLow,
                border: const Border(
                    left: BorderSide(color: Aura.amber, width: 2)),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
        child: Text(msg.content,
            style: const TextStyle(fontSize: 16, height: 1.5)),
      ),
    );
  }
}
