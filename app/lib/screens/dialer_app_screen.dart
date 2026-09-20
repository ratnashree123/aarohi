import 'dart:async';
import 'package:call_log/call_log.dart' as device_call_log;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../tts_service.dart';
import 'calls_screen.dart';

class DialerAppScreen extends StatefulWidget {
  const DialerAppScreen({super.key});

  @override
  State<DialerAppScreen> createState() => _DialerAppScreenState();
}

class _DialerAppScreenState extends State<DialerAppScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late TabController _tabController;

  // Keypad & Input State
  String _enteredNumber = '';
  String _searchQuery = '';

  // In-Call State
  bool _inCall = false;
  bool _isSpeaking = false;
  bool _isListening = false;
  bool _callPickedUp = false;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  String _callerName = '';
  String _callerPhone = '';
  String _liveReason = 'Active Call';
  String _aiStatus = 'Connecting…';
  String _liveStreamingWords = '';
  String _currentlySpeakingText = '';
  final List<Map<String, String>> _activeTranscript = [];

  // Call Duration Timer
  Timer? _callTimer;
  int _callDurationSeconds = 0;

  // Services
  final Tts _tts = Tts.instance;
  final SpeechToText _stt = SpeechToText();

  // Real Device Data
  List<Contact> _deviceContacts = [];
  List<device_call_log.CallLogEntry> _deviceCallLogs = [];
  List<Map<String, String>> _deviceSms = [];

  bool _loading = false;
  bool _contactsPermGranted = false;
  bool _callLogPermGranted = false;
  bool _smsPermGranted = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _requestPermissionsAndLoad();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _callTimer?.cancel();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  Future<void> _requestPermissionsAndLoad() async {
    if (kIsWeb) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);

    // 1. Check permissions fast without triggering system prompts if already granted
    final pContacts = await Permission.contacts.status;
    final pPhone = await Permission.phone.status;
    final pSms = await Permission.sms.status;

    _contactsPermGranted = pContacts.isGranted;
    _callLogPermGranted = pPhone.isGranted;
    _smsPermGranted = pSms.isGranted;

    if (!_contactsPermGranted || !_callLogPermGranted || !_smsPermGranted) {
      final results = await [
        Permission.contacts,
        Permission.phone,
        Permission.sms,
      ].request();
      _contactsPermGranted = results[Permission.contacts]?.isGranted ?? false;
      _callLogPermGranted = results[Permission.phone]?.isGranted ?? false;
      _smsPermGranted = results[Permission.sms]?.isGranted ?? false;
    }

    // 2. Load data non-blockingly so tab renders immediately
    _loadDeviceContacts();
    _loadDeviceCallLog();
    _loadDeviceSms();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadDeviceContacts() async {
    if (!_contactsPermGranted) return;
    try {
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withThumbnail: false,
      );
      if (mounted) setState(() => _deviceContacts = contacts);
    } catch (e) {
      debugPrint('Error loading contacts: $e');
    }
  }

  Future<void> _loadDeviceCallLog() async {
    if (!_callLogPermGranted) return;
    try {
      final entries = await device_call_log.CallLog.get();
      if (mounted) {
        setState(() => _deviceCallLogs = entries.toList().take(100).toList());
      }
    } catch (e) {
      debugPrint('Error loading call log: $e');
    }
  }

  Future<void> _loadDeviceSms() async {
    if (!_smsPermGranted) return;
    try {
      const platform = MethodChannel('com.mithun.aarohi/sms');
      final List<dynamic> smsRaw = await platform.invokeMethod('getSmsInbox');
      if (mounted) {
        setState(() {
          _deviceSms = smsRaw.map((s) => Map<String, String>.from(
            (s as Map).map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
          )).toList();
        });
      }
    } catch (e) {
      // SMS platform channel not available — fallback to empty
      debugPrint('SMS channel not available: $e');
    }
  }

  // --- Echo-Safe Continuous Speech & Pause-to-Listen Engine ---

  bool _isSelfEcho(String words) {
    if (_currentlySpeakingText.isEmpty) return false;
    final w = words.trim().toLowerCase();
    if (w.isEmpty || w.length < 3) return true;

    final aarohiTokens = _currentlySpeakingText
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 3)
        .toSet();

    final inputTokens = w
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 3)
        .toList();

    if (inputTokens.isEmpty) return true;

    int matches = 0;
    for (final token in inputTokens) {
      if (aarohiTokens.contains(token)) matches++;
    }

    return (matches / inputTokens.length) >= 0.4;
  }

  Future<void> _speakWithContinuousMic(
    String text, {
    double emotion = 0.6,
    VoidCallback? onCompleted,
  }) async {
    if (!_inCall || _callPickedUp) return;
    final clean = text.trim();
    if (clean.isEmpty) {
      onCompleted?.call();
      return;
    }

    setState(() {
      _currentlySpeakingText = clean.toLowerCase();
      _isSpeaking = true;
      _aiStatus = 'Aarohi speaking…';
    });

    _startListeningToParty();

    try {
      await _tts.speak(clean, emotion: emotion);
    } catch (_) {}

    if (mounted && _inCall && !_callPickedUp) {
      setState(() {
        _isSpeaking = false;
        _currentlySpeakingText = '';
        if (_aiStatus.contains('speaking')) {
          _aiStatus = 'Listening…';
        }
      });
      onCompleted?.call();
    }
  }

  Future<void> _startListeningToParty() async {
    if (!_inCall || _callPickedUp || _isMuted) return;

    final hasSpeech = await _stt.initialize(
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (mounted && _isListening && !_isSpeaking && _inCall && !_callPickedUp) {
            Future.delayed(const Duration(milliseconds: 400), () {
              if (mounted && _inCall && !_callPickedUp && !_isListening && !_isSpeaking) {
                _startListeningToParty();
              }
            });
          }
        }
      },
      onError: (_) {
        if (mounted && _inCall && !_callPickedUp && !_isSpeaking) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted && _inCall && !_callPickedUp) {
              _startListeningToParty();
            }
          });
        }
      },
    );

    if (hasSpeech && mounted && !_callPickedUp) {
      setState(() => _isListening = true);
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.confirmation,
          cancelOnError: false,
          partialResults: true,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 2),
        ),
        onResult: (result) async {
          final words = result.recognizedWords.trim();
          // Filter out short noise clicks, breathing, and single-letter artifacts
          if (words.length < 3) return;

          final lower = words.toLowerCase();
          const noiseFillers = {'uh', 'um', 'ah', 'er', 'mm', 'hmm', 'huh', 'shh', 'oh', 'ha'};
          if (noiseFillers.contains(lower)) return;

          if (_isSpeaking) {
            // Require at least 2 distinct words OR an explicit intentional keyword
            final wordCount = words.split(RegExp(r'\s+')).length;
            const intentionalKeywords = {
              'stop', 'wait', 'hold', 'pause', 'hello', 'listen', 'no', 'yes', 'hey', 'aarohi', 'excuse'
            };
            final hasKeyword = intentionalKeywords.any((k) => lower.contains(k));

            if ((wordCount >= 2 || hasKeyword) && !_isSelfEcho(words)) {
              // Valid human speech detected: pause Aarohi immediately!
              await _tts.stop();
              if (mounted) {
                setState(() {
                  _isSpeaking = false;
                  _currentlySpeakingText = '';
                  _aiStatus = 'Caller speaking • Pausing to listen…';
                  _liveStreamingWords = words;
                });
              }
            }
          } else {
            if (mounted) {
              setState(() => _liveStreamingWords = words);
            }
          }

          if (result.finalResult && words.isNotEmpty) {
            if (!_isSelfEcho(words)) {
              if (mounted) setState(() => _liveStreamingWords = '');
              _handlePartySpoke(words);
            }
          }
        },
      );
    }
  }

  Future<void> _handlePartySpoke(String text) async {
    await _stt.stop();
    if (mounted) {
      setState(() {
        _isListening = false;
        _activeTranscript.add({'role': 'caller', 'content': text});
        _aiStatus = 'Aarohi thinking…';
      });
    }

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'call_agent',
        body: {
          'action': 'dialogue',
          'direction': 'outbound',
          'caller_name': _callerName,
          'caller_phone': _callerPhone,
          'caller_message': text,
          'transcript': _activeTranscript,
        },
      );

      final data = res.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? 'I have noted that.';
      final reason = data['call_reason'] as String?;
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();
      final callDone = data['call_completed'] as bool? ?? false;

      if (mounted) {
        setState(() {
          if (reason != null && reason.isNotEmpty) _liveReason = reason;
          _activeTranscript.add({'role': 'assistant', 'content': reply});
        });
      }

      await _speakWithContinuousMic(
        reply,
        emotion: emotion,
        onCompleted: () {
          if (callDone) _endCall();
        },
      );
    } catch (e) {
      if (mounted) setState(() => _aiStatus = 'Connection error');
    }
  }

  // --- Call Control Operations ---

  void _startCall({required String name, required String phone, bool isVoicemail = false}) {
    final cleanPhone = phone.trim().isEmpty ? _enteredNumber.trim() : phone.trim();
    if (cleanPhone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a phone number to dial')),
      );
      return;
    }

    setState(() {
      _inCall = true;
      _callerName = name.isNotEmpty ? name : 'Contact ($cleanPhone)';
      _callerPhone = cleanPhone;
      _callDurationSeconds = 0;
      _callPickedUp = false;
      _isMuted = false;
      _liveStreamingWords = '';
      _activeTranscript.clear();
      _liveReason = isVoicemail ? 'Live Voicemail Screening' : 'Outbound AI Call';
      _aiStatus = 'Call connected • Aarohi ready';
    });

    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _inCall) {
        setState(() => _callDurationSeconds++);
      }
    });

    final greeting = isVoicemail
        ? "Hi, I'm Aarohi, Mithun's AI assistant. He is not available right now. Please state your name and reason for calling after the tone."
        : "Hello! This is Aarohi, Mithun's AI phone assistant calling for $_callerName. How can I assist you today?";

    setState(() {
      _activeTranscript.add({'role': 'assistant', 'content': greeting});
    });

    _speakWithContinuousMic(greeting);
  }

  Future<void> _endCall() async {
    _callTimer?.cancel();
    await _tts.stop();
    await _stt.stop();
    if (mounted) {
      setState(() {
        _inCall = false;
        _isListening = false;
        _isSpeaking = false;
        _liveStreamingWords = '';
        _aiStatus = 'Call ended';
      });
      _loadDeviceCallLog();
    }
  }

  Future<void> _pickUpCall() async {
    await _tts.stop();
    await _stt.stop();
    if (mounted) {
      setState(() {
        _callPickedUp = true;
        _isListening = false;
        _isSpeaking = false;
        _liveStreamingWords = '';
        _aiStatus = 'Call Picked Up by Mithun';
        _activeTranscript.add({
          'role': 'assistant',
          'content': '⚡ [Mithun Picked Up the Call — Speaking Directly]',
        });
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You picked up the call with $_callerName! Speak directly.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    }
  }

  Future<void> _launchCellularCall(String phone, {bool direct = false}) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    const platform = MethodChannel('com.mithun.aarohi/telephony');

    try {
      final res = await platform.invokeMethod(direct ? 'call' : 'dial', {'phone': clean});
      if (res == true) return;
    } catch (e) {
      debugPrint('Native telephony channel error: $e');
    }

    // Fallback to url_launcher
    final uri = Uri.parse(clean.isEmpty ? 'tel:' : 'tel:$clean');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    } catch (_) {}
    try {
      await launchUrl(uri);
      return;
    } catch (_) {}

    // In-app AI fallback
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Starting Aarohi call for ${clean.isNotEmpty ? clean : "contact"}...'),
          backgroundColor: Colors.green.shade800,
        ),
      );
      _startCall(name: '', phone: clean.isNotEmpty ? clean : '+1 555 0100');
    }
  }

  Future<void> _requestDefaultDialer() async {
    const platform = MethodChannel('com.mithun.aarohi/telephony');
    try {
      await platform.invokeMethod('requestDefaultDialer');
    } catch (e) {
      debugPrint('Request default dialer error: $e');
    }
  }

  Future<void> _launchSms(String phone, {String body = ''}) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('sms:$clean${body.isNotEmpty ? '?body=${Uri.encodeComponent(body)}' : ''}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        await launchUrl(uri);
      } catch (e) {
        debugPrint('Could not launch sms: $e');
      }
    }
  }

  // --- Keypad Functions ---

  void _onKeypadTap(String val) {
    setState(() {
      _enteredNumber += val;
    });
  }

  void _onKeypadBackspace() {
    if (_enteredNumber.isNotEmpty) {
      setState(() {
        _enteredNumber = _enteredNumber.substring(0, _enteredNumber.length - 1);
      });
    }
  }

  List<Contact> _getFilteredContacts() {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty && _enteredNumber.isEmpty) {
      return _deviceContacts;
    }
    final filter = query.isNotEmpty ? query : _enteredNumber.toLowerCase();
    return _deviceContacts.where((c) {
      final name = c.displayName.toLowerCase();
      final phones = c.phones.map((p) => p.number.replaceAll(RegExp(r'[^0-9]'), '')).join(' ');
      return name.contains(filter) || phones.contains(filter);
    }).toList();
  }

  String _formatDuration(int totalSec) {
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // --- UI Layout ---

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // On web, show a friendly placeholder instead of the full dialer
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: Aura.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Aura.amber.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.phone_android, color: Aura.amber, size: 64),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Phone Features',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Dialer, contacts, call logs, and SMS\nare available on the Android app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 15, height: 1.5),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aura.amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  ),
                  onPressed: () {},
                  icon: const Icon(Icons.android),
                  label: const Text('Download Android App', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_inCall) {
      return _buildInCallOverlay();
    }

    return Scaffold(
      backgroundColor: Aura.bg,
      appBar: AppBar(
        backgroundColor: Aura.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Aura.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.dialpad, color: Aura.amber, size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'Aarohi Phone & Dialer',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Open Full Assistant Hub',
            icon: const Icon(Icons.hub, color: Aura.amberSoft),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CallsScreen()),
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Aura.amber,
          labelColor: Aura.amber,
          unselectedLabelColor: Aura.textDim,
          tabs: const [
            Tab(icon: Icon(Icons.dialpad, size: 20), text: 'Keypad'),
            Tab(icon: Icon(Icons.history, size: 20), text: 'Recents'),
            Tab(icon: Icon(Icons.contacts, size: 20), text: 'Contacts'),
            Tab(icon: Icon(Icons.chat, size: 20), text: 'Messages'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildKeypadTab(),
          _buildRecentsTab(),
          _buildContactsTab(),
          _buildMessagesTab(),
        ],
      ),
    );
  }

  // ================= TAB 1: KEYPAD =================

  Widget _buildKeypadTab() {
    final matchingContacts = _getFilteredContacts();

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          // Number & Autocomplete Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            color: Aura.surfaceLow,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        _enteredNumber.isEmpty ? 'Enter number' : _enteredNumber,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: _enteredNumber.length > 12 ? 22 : 30,
                          fontWeight: FontWeight.bold,
                          color: _enteredNumber.isEmpty ? Aura.textDim : Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    if (_enteredNumber.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.backspace, color: Colors.white70, size: 22),
                        onPressed: _onKeypadBackspace,
                      ),
                  ],
                ),
                if (matchingContacts.isNotEmpty && _enteredNumber.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: matchingContacts.length,
                      separatorBuilder: (context, index) => const SizedBox(width: 8),
                      itemBuilder: (ctx, i) {
                        final c = matchingContacts[i];
                        final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
                        return ActionChip(
                          backgroundColor: Aura.surface,
                          side: BorderSide(color: Aura.amber.withValues(alpha: 0.5)),
                          avatar: const Icon(Icons.person, size: 14, color: Aura.amber),
                          label: Text(
                            '${c.displayName} ($phone)',
                            style: const TextStyle(fontSize: 12, color: Colors.white),
                          ),
                          onPressed: () {
                            setState(() => _enteredNumber = phone);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 12-Key Numeric Keypad (Truecaller Grid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              children: [
                _buildKeypadRow([
                  _buildKey('1', ''),
                  _buildKey('2', 'ABC'),
                  _buildKey('3', 'DEF'),
                ]),
                const SizedBox(height: 10),
                _buildKeypadRow([
                  _buildKey('4', 'GHI'),
                  _buildKey('5', 'JKL'),
                  _buildKey('6', 'MNO'),
                ]),
                const SizedBox(height: 10),
                _buildKeypadRow([
                  _buildKey('7', 'PQRS'),
                  _buildKey('8', 'TUV'),
                  _buildKey('9', 'WXYZ'),
                ]),
                const SizedBox(height: 10),
                _buildKeypadRow([
                  _buildKey('*', ''),
                  _buildKey('0', '+'),
                  _buildKey('#', ''),
                ]),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Action Buttons: AI Agent Call, Big Cellular Call, Set Default Dialer
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Aarohi AI Agent Call (Voice Conversation Assistant)
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Aura.amber.withValues(alpha: 0.2),
                    padding: const EdgeInsets.all(16),
                  ),
                  icon: const Icon(Icons.record_voice_over, color: Aura.amber, size: 24),
                  tooltip: 'Call with Aarohi AI Assistant',
                  onPressed: () {
                    final numToDial = _enteredNumber.isNotEmpty ? _enteredNumber : '+1 555 0100';
                    _startCall(
                      name: _enteredNumber.isNotEmpty ? 'Contact ($_enteredNumber)' : 'AI Call',
                      phone: numToDial,
                    );
                  },
                ),
                // Truecaller / Launcher Big Round CELLULAR CALL Button
                GestureDetector(
                  onTap: () {
                    if (_enteredNumber.isNotEmpty) {
                      _launchCellularCall(_enteredNumber, direct: true);
                    } else if (_deviceCallLogs.isNotEmpty && _deviceCallLogs.first.number != null) {
                      setState(() => _enteredNumber = _deviceCallLogs.first.number!);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a phone number to call')),
                      );
                    }
                  },
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.shade600,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withValues(alpha: 0.5),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.call, color: Colors.white, size: 36),
                  ),
                ),
                // Set as Default Phone App / System Dialer
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Aura.surfaceHigh,
                    padding: const EdgeInsets.all(16),
                  ),
                  icon: const Icon(Icons.settings_phone, color: Colors.white70, size: 24),
                  tooltip: 'Set as Default Phone App',
                  onPressed: _requestDefaultDialer,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildKeypadRow(List<Widget> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: keys,
    );
  }

  Widget _buildKey(String digit, String sub) {
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: () => _onKeypadTap(digit),
      onLongPress: digit == '0' ? () => _onKeypadTap('+') : null,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: Aura.surface,
          shape: BoxShape.circle,
          border: Border.all(color: Aura.outline.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              digit,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: const TextStyle(fontSize: 9, color: Aura.textDim, letterSpacing: 1),
              ),
          ],
        ),
      ),
    );
  }

  // ================= TAB 2: RECENTS (DEVICE CALL HISTORY) =================

  Widget _buildRecentsTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Aura.amber));
    }
    if (!_callLogPermGranted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.phone_disabled, size: 50, color: Aura.textDim),
            const SizedBox(height: 12),
            const Text('Call log permission not granted', style: TextStyle(color: Aura.textDim, fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: _requestPermissionsAndLoad,
              child: const Text('Grant Permission'),
            ),
          ],
        ),
      );
    }
    if (_deviceCallLogs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 50, color: Aura.textDim),
            const SizedBox(height: 12),
            const Text('No recent calls', style: TextStyle(color: Aura.textDim, fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: () => _tabController.animateTo(0),
              child: const Text('Open Keypad'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: Aura.amber,
      onRefresh: _loadDeviceCallLog,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _deviceCallLogs.length,
        separatorBuilder: (context, index) => const Divider(color: Colors.white12, height: 1),
        itemBuilder: (ctx, i) {
          final log = _deviceCallLogs[i];
          final name = (log.name ?? '').isNotEmpty ? log.name! : 'Unknown';
          final phone = log.number ?? '';
          final duration = log.duration ?? 0;
          final timestamp = log.timestamp != null
              ? DateTime.fromMillisecondsSinceEpoch(log.timestamp!)
              : null;

          // Call type icon & color
          IconData typeIcon;
          Color typeColor;
          String typeLabel;
          switch (log.callType) {
            case device_call_log.CallType.outgoing:
              typeIcon = Icons.call_made;
              typeColor = Colors.lightBlueAccent;
              typeLabel = 'Outgoing';
              break;
            case device_call_log.CallType.incoming:
              typeIcon = Icons.call_received;
              typeColor = Colors.greenAccent;
              typeLabel = 'Incoming';
              break;
            case device_call_log.CallType.missed:
              typeIcon = Icons.call_missed;
              typeColor = Colors.redAccent;
              typeLabel = 'Missed';
              break;
            case device_call_log.CallType.rejected:
              typeIcon = Icons.call_end;
              typeColor = Colors.orangeAccent;
              typeLabel = 'Rejected';
              break;
            default:
              typeIcon = Icons.phone;
              typeColor = Aura.textDim;
              typeLabel = 'Unknown';
          }

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: CircleAvatar(
              backgroundColor: typeColor.withValues(alpha: 0.2),
              child: Icon(typeIcon, color: typeColor, size: 18),
            ),
            title: Text(
              name,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: log.callType == device_call_log.CallType.missed ? Colors.redAccent : Colors.white,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(phone, style: const TextStyle(color: Aura.textDim, fontSize: 13)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(typeIcon, size: 12, color: typeColor),
                    const SizedBox(width: 4),
                    Text(
                      '$typeLabel • ${_formatDuration(duration)}',
                      style: TextStyle(color: typeColor, fontSize: 12),
                    ),
                    if (timestamp != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatTimestamp(timestamp),
                        style: const TextStyle(color: Aura.textDim, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline, size: 20, color: Colors.white70),
                  tooltip: 'Send SMS',
                  onPressed: () => _launchSms(phone),
                ),
                IconButton(
                  icon: const Icon(Icons.phone, size: 20, color: Colors.greenAccent),
                  tooltip: 'Call Back',
                  onPressed: () => _launchCellularCall(phone),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  // ================= TAB 3: CONTACTS (DEVICE) =================

  Widget _buildContactsTab() {
    if (!_contactsPermGranted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.contacts, size: 50, color: Aura.textDim),
            const SizedBox(height: 12),
            const Text('Contacts permission not granted', style: TextStyle(color: Aura.textDim, fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: _requestPermissionsAndLoad,
              child: const Text('Grant Permission'),
            ),
          ],
        ),
      );
    }

    final contacts = _getFilteredContacts();

    return Column(
      children: [
        // Contact Search
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            onChanged: (val) => setState(() => _searchQuery = val),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search contacts by name or number…',
              hintStyle: const TextStyle(color: Aura.textDim),
              prefixIcon: const Icon(Icons.search, color: Aura.amber),
              filled: true,
              fillColor: Aura.surface,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),

        // Contact count banner
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                '${_deviceContacts.length} contacts on device',
                style: const TextStyle(color: Aura.textDim, fontSize: 13),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20, color: Aura.amber),
                tooltip: 'Reload Contacts',
                onPressed: _loadDeviceContacts,
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: contacts.length,
            separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
            itemBuilder: (ctx, i) {
              final c = contacts[i];
              final name = c.displayName;
              final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
              final phoneLabel = c.phones.isNotEmpty ? (c.phones.first.label.name) : '';
              final hasPhoto = c.photo != null && c.photo!.isNotEmpty;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: Aura.surfaceHigh,
                  backgroundImage: hasPhoto ? MemoryImage(c.photo!) : null,
                  child: hasPhoto
                      ? null
                      : Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(color: Aura.amber, fontWeight: FontWeight.bold),
                        ),
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                subtitle: Text(
                  phone.isNotEmpty ? '$phone${phoneLabel.isNotEmpty ? ' ($phoneLabel)' : ''}' : 'No phone number',
                  style: const TextStyle(color: Aura.textDim, fontSize: 13),
                ),
                onTap: () => _showContactOptions(c),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (phone.isNotEmpty) ...[
                      IconButton(
                        icon: const Icon(Icons.message, size: 19, color: Colors.white70),
                        onPressed: () => _launchSms(phone),
                      ),
                      IconButton(
                        icon: const Icon(Icons.call, size: 19, color: Colors.greenAccent),
                        onPressed: () => _launchCellularCall(phone),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showContactOptions(Contact contact) {
    final phones = contact.phones;
    if (phones.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              contact.displayName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            ...phones.map((p) => ListTile(
              leading: const Icon(Icons.phone, color: Aura.amber),
              title: Text(p.number, style: const TextStyle(color: Colors.white)),
              subtitle: Text(p.label.name, style: const TextStyle(color: Aura.textDim, fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.message, color: Colors.white70),
                    tooltip: 'Send SMS',
                    onPressed: () {
                      Navigator.pop(ctx);
                      _launchSms(p.number);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.call, color: Colors.greenAccent),
                    tooltip: 'Call via SIM',
                    onPressed: () {
                      Navigator.pop(ctx);
                      _launchCellularCall(p.number);
                    },
                  ),
                ],
              ),
            )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ================= TAB 4: MESSAGES & SMS (DEVICE) =================

  Widget _buildMessagesTab() {
    if (!_smsPermGranted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.sms_failed, size: 50, color: Aura.textDim),
            const SizedBox(height: 12),
            const Text('SMS permission not granted', style: TextStyle(color: Aura.textDim, fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
              onPressed: _requestPermissionsAndLoad,
              child: const Text('Grant Permission'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Smart AI Quick Reply Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Aura.surfaceLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('QUICK AI SMS REPLIES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Aura.amberSoft, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _buildQuickReplyChip("I'm in a meeting, call you back"),
                  _buildQuickReplyChip("On my way now"),
                  _buildQuickReplyChip("Please send the details"),
                  _buildQuickReplyChip("Can you call later?"),
                ],
              ),
            ],
          ),
        ),

        // Message count & refresh banner
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${_deviceSms.length} messages on device',
                style: const TextStyle(color: Aura.textDim, fontSize: 13),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20, color: Aura.amber),
                tooltip: 'Reload SMS',
                onPressed: _loadDeviceSms,
              ),
            ],
          ),
        ),

        Expanded(
          child: _deviceSms.isEmpty
              ? const Center(
                  child: Text('No SMS messages found in inbox', style: TextStyle(color: Aura.textDim)),
                )
              : RefreshIndicator(
                  color: Aura.amber,
                  onRefresh: _loadDeviceSms,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _deviceSms.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final m = _deviceSms[i];
                      final sender = m['sender'] ?? 'Unknown';
                      final phone = m['phone'] ?? sender;
                      final body = m['body'] ?? '';
                      final time = m['time'] ?? '';

                      return Card(
                        color: Aura.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Aura.outline.withValues(alpha: 0.3)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.sms, size: 16, color: Colors.lightBlueAccent),
                                      const SizedBox(width: 8),
                                      Text(
                                        sender,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                                      ),
                                    ],
                                  ),
                                  Text(time, style: const TextStyle(fontSize: 12, color: Aura.textDim)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(body, style: const TextStyle(fontSize: 13.5, color: Colors.white70, height: 1.35)),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white70,
                                      side: BorderSide(color: Aura.outline.withValues(alpha: 0.5)),
                                    ),
                                    icon: const Icon(Icons.reply, size: 16),
                                    label: const Text('Reply SMS'),
                                    onPressed: () => _launchSms(phone),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.green.shade700,
                                      foregroundColor: Colors.white,
                                    ),
                                    icon: const Icon(Icons.phone, size: 16),
                                    label: const Text('Call'),
                                    onPressed: () => _launchCellularCall(phone),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildQuickReplyChip(String text) {
    return ActionChip(
      backgroundColor: Aura.surface,
      side: BorderSide(color: Aura.outline.withValues(alpha: 0.4)),
      label: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
      onPressed: () {
        if (_deviceContacts.isNotEmpty && _deviceContacts.first.phones.isNotEmpty) {
          _launchSms(_deviceContacts.first.phones.first.number, body: text);
        } else {
          _launchSms('', body: text);
        }
      },
    );
  }

  // ================= TRUECALLER-STYLE IN-CALL OVERLAY =================

  Widget _buildInCallOverlay() {
    return Scaffold(
      backgroundColor: Aura.bg,
      appBar: AppBar(
        backgroundColor: Aura.surfaceLow,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.greenAccent),
            ),
            const SizedBox(width: 8),
            Text(_aiStatus, style: const TextStyle(fontSize: 14, color: Aura.amberSoft, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          // ALWAYS VISIBLE TOP HANG UP BUTTON
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              icon: const Icon(Icons.call_end, size: 18),
              label: const Text('HANG UP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: _endCall,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            children: [
              // Caller Avatar & Ring
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Aura.surfaceHigh,
                  border: Border.all(color: Aura.amber, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: Aura.amber.withValues(alpha: 0.35),
                      blurRadius: 20,
                      spreadRadius: 3,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/aarohi_avatar.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.record_voice_over, size: 36, color: Aura.amber),
                  ),
                ),
              ),

              const SizedBox(height: 10),
              Text(
                _callerName,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(
                _callerPhone,
                style: const TextStyle(fontSize: 14, color: Aura.textDim),
              ),
              const SizedBox(height: 6),

              // Call Duration Stopwatch
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: Aura.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Aura.outline.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.greenAccent)),
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(_callDurationSeconds),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '• $_aiStatus',
                      style: const TextStyle(fontSize: 12, color: Aura.amberSoft),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Reason: $_liveReason',
                style: const TextStyle(fontSize: 12, color: Aura.amberSoft, fontStyle: FontStyle.italic),
              ),

              const SizedBox(height: 10),

              // Live Conversation Box
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Aura.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Aura.outline.withValues(alpha: 0.3)),
                  ),
                  child: ListView.builder(
                    itemCount: _activeTranscript.length + (_liveStreamingWords.isNotEmpty ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i == _activeTranscript.length && _liveStreamingWords.isNotEmpty) {
                        return Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.green.shade900.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.greenAccent),
                            ),
                            child: Text(
                              'Caller: "$_liveStreamingWords ▋"',
                              style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic),
                            ),
                          ),
                        );
                      }
                      final turn = _activeTranscript[i];
                      final isAarohi = turn['role'] == 'assistant';

                      return Align(
                        alignment: isAarohi ? Alignment.centerLeft : Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isAarohi ? Aura.hearth : Aura.surfaceHigh,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isAarohi ? Aura.amber.withValues(alpha: 0.4) : Colors.white24),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isAarohi ? 'Aarohi AI' : 'Caller', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isAarohi ? Aura.amberSoft : Colors.lightBlueAccent)),
                              const SizedBox(height: 4),
                              Text(turn['content'] ?? '', style: const TextStyle(fontSize: 13.5, color: Colors.white)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // PERMANENTLY ANCHORED BOTTOM BAR WITH HANG UP BUTTON
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Aura.surfaceLow,
          border: Border(top: BorderSide(color: Aura.outline.withValues(alpha: 0.3))),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // In-Call Action Bar: Mute, Speaker, Takeover
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _isMuted ? Colors.redAccent.shade700 : Aura.surfaceHigh,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(_isMuted ? Icons.mic_off : Icons.mic, color: Colors.white),
                    tooltip: 'Mute Mic',
                    onPressed: () => setState(() => _isMuted = !_isMuted),
                  ),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _isSpeakerOn ? Aura.amber : Aura.surfaceHigh,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(_isSpeakerOn ? Icons.volume_up : Icons.volume_down, color: _isSpeakerOn ? Colors.black : Colors.white),
                    tooltip: 'Speaker',
                    onPressed: () => setState(() => _isSpeakerOn = !_isSpeakerOn),
                  ),
                  if (!_callPickedUp)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: const Icon(Icons.phone, size: 18),
                      label: const Text('Pick Up', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: _pickUpCall,
                    ),
                ],
              ),
              const SizedBox(height: 10),

              // HUGE ALWAYS-VISIBLE RED HANG UP BUTTON
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent.shade700,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(54),
                  elevation: 6,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.call_end, size: 24),
                label: const Text('HANG UP / END CALL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                onPressed: _endCall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
