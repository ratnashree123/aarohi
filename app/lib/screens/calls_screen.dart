import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../tts_service.dart';

class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _tts = Tts.instance;
  final _stt = SpeechToText();

  // Active call state
  bool _inCall = false;
  bool _isSpeaking = false;
  bool _isListening = false;
  String _callDirection = 'inbound'; // 'inbound' | 'outbound'
  String _callerName = 'Unknown Caller';
  String _callerPhone = '+91 98765 43210';
  String? _selectedBookingId;
  String _liveReason = 'Listening for reason of call…';
  String _aiStatus = 'Ready';
  String _liveStreamingWords = '';
  bool _callPickedUp = false;
  String _currentlySpeakingText = '';

  // Ringing & Contact Search State
  bool _isRinging = false;
  String _ringingCallerName = 'Apex Dental Clinic';
  String _ringingCallerPhone = '+91 98765 43210';
  String _searchQuery = '';

  final List<Map<String, String>> _activeTranscript = [];
  final TextEditingController _manualInputController = TextEditingController();
  final TextEditingController _phoneDialerController = TextEditingController();

  // Data state
  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _callLogs = [];
  bool _loadingData = true;

  List<Map<String, String>> _getFilteredContacts() {
    final list = <Map<String, String>>[];
    final seen = <String>{};

    for (final b in _bookings) {
      final name = (b['contact_name'] ?? b['title'] ?? '').toString().trim();
      final phone = (b['phone_number'] ?? '').toString().trim();
      if (phone.isNotEmpty && seen.add(phone)) {
        list.add({'name': name, 'phone': phone, 'subtitle': b['title'] ?? 'Booking'});
      }
    }

    for (final l in _callLogs) {
      final name = (l['caller_name'] ?? 'Caller').toString().trim();
      final phone = (l['caller_phone'] ?? '').toString().trim();
      if (phone.isNotEmpty && seen.add(phone)) {
        list.add({'name': name, 'phone': phone, 'subtitle': 'Recent Call'});
      }
    }

    if (_searchQuery.isEmpty) return list.take(5).toList();

    return list.where((c) {
      final n = c['name']!.toLowerCase();
      final p = c['phone']!.toLowerCase();
      return n.contains(_searchQuery) || p.contains(_searchQuery);
    }).toList();
  }

  void _triggerIncomingCallAlert({
    String name = 'Apex Dental Clinic',
    String phone = '+91 98765 43210',
  }) {
    _tts.stop();
    _stt.stop();
    setState(() {
      _isRinging = true;
      _ringingCallerName = name;
      _ringingCallerPhone = phone;
    });
  }

  void _declineRingingCall() {
    setState(() => _isRinging = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Incoming call declined.')),
    );
  }

  bool _permissionsGranted = false;

  void _answerCallWithAarohi() {
    setState(() => _isRinging = false);
    _startInboundScreening(caller: _ringingCallerName, phone: _ringingCallerPhone);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _checkPermissions();
    _loadTwilioConfig();
    _loadFonosterConfig();
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _manualInputController.dispose();
    _phoneDialerController.dispose();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    if (kIsWeb) {
      if (mounted) setState(() => _permissionsGranted = true);
      return;
    }
    try {
      final mic = await Permission.microphone.status;
      final phone = await Permission.phone.status;
      final contacts = await Permission.contacts.status;
      if (mounted) {
        setState(() {
          _permissionsGranted = mic.isGranted && phone.isGranted && contacts.isGranted;
        });
      }
    } catch (_) {}
  }

  Future<void> _requestAllPermissions() async {
    if (kIsWeb) {
      if (mounted) setState(() => _permissionsGranted = true);
      return;
    }
    try {
      final statuses = await [
        Permission.microphone,
        Permission.phone,
        Permission.contacts,
        Permission.notification,
      ].request();

      final micOk = statuses[Permission.microphone]?.isGranted ?? false;
      final phoneOk = statuses[Permission.phone]?.isGranted ?? false;
      final allOk = micOk && phoneOk;

      if (mounted) {
        setState(() => _permissionsGranted = allOk);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(allOk
                ? 'All permissions granted! Complete phone & audio access active.'
                : 'Permissions updated. You can also grant remaining in App Settings.'),
            backgroundColor: allOk ? Colors.green.shade800 : Colors.orange.shade900,
          ),
        );
      }
    } catch (e) {
      debugPrint('Permission request error: $e');
    }
  }

  // --- Twilio Cloud Telephony (Real Cellular Calling) ---
  String _twilioSid = '';
  String _twilioAuth = '';
  String _twilioNumber = '';
  bool _isTwilioDialing = false;
  String _twilioStatusMessage = '';

  Future<void> _loadTwilioConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _twilioSid = prefs.getString('twilio_sid') ?? '';
        _twilioAuth = prefs.getString('twilio_auth') ?? '';
        _twilioNumber = prefs.getString('twilio_number') ?? '';
      });
    }
  }

  Future<void> _saveTwilioConfig(String sid, String auth, String number) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('twilio_sid', sid.trim());
    await prefs.setString('twilio_auth', auth.trim());
    await prefs.setString('twilio_number', number.trim());
    if (mounted) {
      setState(() {
        _twilioSid = sid.trim();
        _twilioAuth = auth.trim();
        _twilioNumber = number.trim();
      });
    }
  }

  Future<void> _placeTwilioCellularCall(String toPhone, {String? bookingId, String? contactName}) async {
    final cleanPhone = toPhone.trim();
    if (cleanPhone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid phone number with country code (e.g. +91...)')),
      );
      return;
    }

    if (_twilioSid.isEmpty || _twilioAuth.isEmpty || _twilioNumber.isEmpty) {
      _showTwilioConfigDialog(pendingPhone: cleanPhone, pendingBookingId: bookingId, pendingName: contactName);
      return;
    }

    setState(() {
      _isTwilioDialing = true;
      _twilioStatusMessage = 'Dialing $cleanPhone via Twilio cellular network…';
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'twilio_voice',
        body: {
          'action': 'make_call',
          'to': cleanPhone,
          'booking_id': bookingId,
          'contact_name': contactName ?? 'Contact',
          'twilio_sid': _twilioSid,
          'twilio_auth': _twilioAuth,
          'twilio_number': _twilioNumber,
        },
      );

      final data = res.data as Map<String, dynamic>? ?? {};
      if (data['success'] == true) {
        if (mounted) {
          setState(() {
            _twilioStatusMessage = 'Call connected! Recipient phone is ringing via cellular carrier.';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Twilio is calling $cleanPhone! Aarohi will converse when answered.'),
              backgroundColor: Colors.green.shade800,
              duration: const Duration(seconds: 5),
            ),
          );
          _tabController.animateTo(2); // View Call History
          _loadData();
        }
      } else {
        final err = data['error'] ?? 'Call failed to initiate';
        if (mounted) {
          setState(() => _twilioStatusMessage = 'Failed: $err');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Twilio error: $err'), backgroundColor: Colors.red.shade800),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _twilioStatusMessage = 'Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error triggering Twilio call: $e'), backgroundColor: Colors.red.shade800),
        );
      }
    } finally {
      if (mounted) setState(() => _isTwilioDialing = false);
    }
  }

  void _showTwilioConfigDialog({String? pendingPhone, String? pendingBookingId, String? pendingName}) {
    final sidCtrl = TextEditingController(text: _twilioSid);
    final authCtrl = TextEditingController(text: _twilioAuth);
    final numCtrl = TextEditingController(text: _twilioNumber);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.cell_tower, color: Aura.amber),
            SizedBox(width: 10),
            Text('Twilio Voice Setup', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your Twilio credentials so Aarohi can place real telephone calls to mobile numbers over the cellular carrier network.',
                style: TextStyle(fontSize: 13, color: Aura.textDim, height: 1.35),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: sidCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Twilio Account SID (starts with AC...)',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: authCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Twilio Auth Token',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: numCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Twilio Phone Number (e.g. +1234567890)',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
            onPressed: () async {
              await _saveTwilioConfig(sidCtrl.text, authCtrl.text, numCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (pendingPhone != null && pendingPhone.isNotEmpty) {
                _placeTwilioCellularCall(pendingPhone, bookingId: pendingBookingId, contactName: pendingName);
              }
            },
            child: const Text('Save & Connect', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // --- Fonoster Open-Source Voice Telephony ---
  String _fonosterAccessKey = '';
  String _fonosterApiSecret = '';
  String _fonosterAppRef = '';
  String _fonosterFromNumber = '';
  String _fonosterEndpoint = 'https://api.fonoster.com';
  bool _isFonosterDialing = false;
  String _fonosterStatusMessage = '';

  Future<void> _loadFonosterConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _fonosterAccessKey = prefs.getString('fonoster_access_key') ?? '';
        _fonosterApiSecret = prefs.getString('fonoster_api_secret') ?? '';
        _fonosterAppRef = prefs.getString('fonoster_app_ref') ?? '';
        _fonosterFromNumber = prefs.getString('fonoster_from_number') ?? '';
        _fonosterEndpoint = prefs.getString('fonoster_endpoint') ?? 'https://api.fonoster.com';
      });
    }
  }

  Future<void> _saveFonosterConfig(String key, String secret, String appRef, String from, String endpoint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fonoster_access_key', key.trim());
    await prefs.setString('fonoster_api_secret', secret.trim());
    await prefs.setString('fonoster_app_ref', appRef.trim());
    await prefs.setString('fonoster_from_number', from.trim());
    await prefs.setString('fonoster_endpoint', endpoint.trim().isNotEmpty ? endpoint.trim() : 'https://api.fonoster.com');
    if (mounted) {
      setState(() {
        _fonosterAccessKey = key.trim();
        _fonosterApiSecret = secret.trim();
        _fonosterAppRef = appRef.trim();
        _fonosterFromNumber = from.trim();
        _fonosterEndpoint = endpoint.trim().isNotEmpty ? endpoint.trim() : 'https://api.fonoster.com';
      });
    }
  }

  Future<void> _placeFonosterCellularCall(String toPhone, {String? bookingId, String? contactName}) async {
    final cleanPhone = toPhone.trim();
    if (cleanPhone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid destination phone number')),
      );
      return;
    }

    if (_fonosterAccessKey.isEmpty || _fonosterApiSecret.isEmpty || _fonosterAppRef.isEmpty) {
      _showFonosterConfigDialog(pendingPhone: cleanPhone, pendingBookingId: bookingId, pendingName: contactName);
      return;
    }

    setState(() {
      _isFonosterDialing = true;
      _fonosterStatusMessage = 'Dialing $cleanPhone via Fonoster…';
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'fonoster_voice',
        body: {
          'action': 'make_call',
          'to': cleanPhone,
          'booking_id': bookingId,
          'contact_name': contactName ?? 'Contact',
          'fonoster_access_key': _fonosterAccessKey,
          'fonoster_api_secret': _fonosterApiSecret,
          'fonoster_app_ref': _fonosterAppRef,
          'fonoster_from': _fonosterFromNumber,
          'fonoster_endpoint': _fonosterEndpoint,
        },
      );

      final data = res.data as Map<String, dynamic>? ?? {};
      if (data['success'] == true) {
        if (mounted) {
          setState(() {
            _fonosterStatusMessage = 'Call connected! Fonoster is ringing the phone.';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Fonoster is calling $cleanPhone! Aarohi will converse when answered.'),
              backgroundColor: Colors.green.shade800,
              duration: const Duration(seconds: 5),
            ),
          );
          _tabController.animateTo(2); // View Call History
          _loadData();
        }
      } else {
        final err = data['error'] ?? 'Call failed to initiate';
        if (mounted) {
          setState(() => _fonosterStatusMessage = 'Failed: $err');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fonoster error: $err'), backgroundColor: Colors.red.shade800),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _fonosterStatusMessage = 'Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error triggering Fonoster call: $e'), backgroundColor: Colors.red.shade800),
        );
      }
    } finally {
      if (mounted) setState(() => _isFonosterDialing = false);
    }
  }

  void _showFonosterConfigDialog({String? pendingPhone, String? pendingBookingId, String? pendingName}) {
    final keyCtrl = TextEditingController(text: _fonosterAccessKey);
    final secretCtrl = TextEditingController(text: _fonosterApiSecret);
    final appRefCtrl = TextEditingController(text: _fonosterAppRef);
    final fromCtrl = TextEditingController(text: _fonosterFromNumber);
    final endpointCtrl = TextEditingController(text: _fonosterEndpoint);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.hub, color: Aura.amber),
            SizedBox(width: 10),
            Text('Fonoster Setup', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your Fonoster open-source credentials to place outbound telephone calls to mobile numbers.',
                style: TextStyle(fontSize: 13, color: Aura.textDim, height: 1.35),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: keyCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Access Key ID',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: secretCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'API Secret',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: appRefCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Voice App Reference (appRef)',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: fromCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'From / Virtual Number (e.g. +18005550100)',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: endpointCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Fonoster Endpoint (Default: https://api.fonoster.com)',
                  labelStyle: TextStyle(color: Aura.amberSoft),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Aura.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Aura.amber, foregroundColor: Colors.black),
            onPressed: () async {
              await _saveFonosterConfig(keyCtrl.text, secretCtrl.text, appRefCtrl.text, fromCtrl.text, endpointCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (pendingPhone != null && pendingPhone.isNotEmpty) {
                _placeFonosterCellularCall(pendingPhone, bookingId: pendingBookingId, contactName: pendingName);
              }
            },
            child: const Text('Save & Connect', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _makePhoneCall(String phoneNumber) async {
    _tts.stop();
    _stt.stop();
    final clean = phoneNumber.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    try {
      if (!kIsWeb) await Permission.phone.request();
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open phone dialer: $e')),
        );
      }
    }
  }

  Future<void> _loadData() async {
    setState(() => _loadingData = true);
    final db = Supabase.instance.client;
    try {
      final bRes = await db
          .from('bookings')
          .select()
          .order('booking_time', ascending: true);
      final cRes = await db
          .from('call_logs')
          .select()
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _bookings = List<Map<String, dynamic>>.from(bRes);
          _callLogs = List<Map<String, dynamic>>.from(cRes);
          _loadingData = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading call/booking data: $e');
      if (mounted) setState(() => _loadingData = false);
    }
  }

  // --- Call Screening & AI Dialogue Engine ---

  Future<void> _startInboundScreening({
    String caller = 'Apex Health Clinic',
    String phone = '+91 98765 43210',
  }) async {
    _tabController.animateTo(0);
    setState(() {
      _inCall = true;
      _callPickedUp = false;
      _liveStreamingWords = '';
      _callDirection = 'inbound';
      _callerName = caller;
      _callerPhone = phone;
      _selectedBookingId = null;
      _activeTranscript.clear();
      _liveReason = 'Live Voicemail screening started…';
      _aiStatus = 'Aarohi answering voicemail…';
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'call_agent',
        body: {
          'action': 'start',
          'direction': 'inbound',
          'caller_name': _callerName,
          'caller_phone': _callerPhone,
        },
      );

      final data = res.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ??
          "Hi, I'm Aarohi, Mithun's AI assistant. He is not available right now. Please state your name and reason for calling after the tone.";
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();

      setState(() {
        _activeTranscript.add({'role': 'assistant', 'content': reply});
      });

      await _speakWithLiveInterruption(reply, emotion: emotion);
    } catch (e) {
      debugPrint('Call agent start error: $e');
      _fallbackGreeting(
          "Hi, I'm Aarohi, Mithun's AI assistant. He is not available right now. Please leave a message after the tone.");
    }
  }

  Future<void> _startOutboundToNumber(String phone, {String? name}) async {
    _tabController.animateTo(0);
    setState(() {
      _inCall = true;
      _callDirection = 'outbound';
      _callerName = (name != null && name.isNotEmpty) ? name : 'Contact ($phone)';
      _callerPhone = phone;
      _selectedBookingId = null;
      _activeTranscript.clear();
      _liveReason = 'Calling: $_callerName';
      _aiStatus = 'Connecting call…';
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'call_agent',
        body: {
          'action': 'outbound_start',
          'direction': 'outbound',
          'caller_name': _callerName,
          'caller_phone': _callerPhone,
        },
      );

      final data = res.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ??
          "Hello! This is Aarohi calling on behalf of Mithun. May I know who I am speaking with?";
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();

      setState(() {
        _activeTranscript.add({'role': 'assistant', 'content': reply});
      });

      await _speakWithLiveInterruption(reply, emotion: emotion);
    } catch (e) {
      debugPrint('Outbound error: $e');
      _fallbackGreeting(
          "Hello! I am Aarohi, calling on behalf of Mithun. How are you doing today?");
    }
  }

  Future<void> _startOutboundConfirmation(Map<String, dynamic> booking) async {
    _tabController.animateTo(0);
    setState(() {
      _inCall = true;
      _callDirection = 'outbound';
      _callerName = booking['contact_name'] as String? ?? 'Contact';
      _callerPhone = booking['phone_number'] as String? ?? '';
      _selectedBookingId = booking['id'] as String?;
      _activeTranscript.clear();
      _liveReason = 'Confirming: ${booking['title']}';
      _aiStatus = 'Dialing…';
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'call_agent',
        body: {
          'action': 'outbound_start',
          'direction': 'outbound',
          'caller_name': _callerName,
          'caller_phone': _callerPhone,
          'booking_id': _selectedBookingId,
        },
      );

      final data = res.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ??
          "Hello! I'm Aarohi, calling on behalf of Mithun to confirm his booking.";
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();

      setState(() {
        _activeTranscript.add({'role': 'assistant', 'content': reply});
      });

      await _speakWithLiveInterruption(reply, emotion: emotion);
    } catch (e) {
      debugPrint('Outbound error: $e');
      _fallbackGreeting(
          "Hello! I'm Aarohi calling on behalf of Mithun to confirm his appointment.");
    }
  }

  void _fallbackGreeting(String msg) async {
    setState(() {
      _activeTranscript.add({'role': 'assistant', 'content': msg});
    });
    await _speakWithLiveInterruption(msg);
  }

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

  Future<void> _speakWithLiveInterruption(
    String reply, {
    double emotion = 0.6,
    VoidCallback? onCompleted,
  }) async {
    if (!_inCall || _callPickedUp) return;
    final cleanReply = reply.trim();
    if (cleanReply.isEmpty) {
      onCompleted?.call();
      return;
    }

    setState(() {
      _currentlySpeakingText = cleanReply.toLowerCase();
      _isSpeaking = true;
      _aiStatus = 'Aarohi speaking…';
    });

    // 1. Keep microphone actively listening in parallel (mic stays ON!)
    _startListeningToCaller();

    // 2. Play Aarohi's voice
    try {
      await _tts.speak(cleanReply, emotion: emotion);
    } catch (_) {}

    // 3. If finished speaking naturally (if the caller was quiet and didn't talk)
    if (mounted && _inCall && !_callPickedUp) {
      setState(() {
        _isSpeaking = false;
        _currentlySpeakingText = '';
        if (_aiStatus.contains('speaking')) {
          _aiStatus = 'Listening to caller…';
        }
      });
      onCompleted?.call();
    }
  }

  Future<void> _startListeningToCaller() async {
    if (!_inCall || _callPickedUp) return;
    final hasSpeech = await _stt.initialize(
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (mounted && _isListening && !_isSpeaking && _inCall && !_callPickedUp) {
            Future.delayed(const Duration(milliseconds: 400), () {
              if (mounted && _inCall && !_callPickedUp && !_isListening && !_isSpeaking) {
                _startListeningToCaller();
              }
            });
          }
        }
      },
      onError: (_) {
        if (mounted && _inCall && !_callPickedUp && !_isSpeaking) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted && _inCall && !_callPickedUp) {
              _startListeningToCaller();
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

          // If Aarohi is currently speaking and caller speaks something new
          if (_isSpeaking) {
            final wordCount = words.split(RegExp(r'\s+')).length;
            const intentionalKeywords = {
              'stop', 'wait', 'hold', 'pause', 'hello', 'listen', 'no', 'yes', 'hey', 'aarohi', 'excuse'
            };
            final hasKeyword = intentionalKeywords.any((k) => lower.contains(k));

            if ((wordCount >= 2 || hasKeyword) && !_isSelfEcho(words)) {
              // Caller started talking! Pause Aarohi for a moment to listen
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
            // Aarohi is not speaking: show words live on screen
            if (mounted) {
              setState(() => _liveStreamingWords = words);
            }
          }

          // When caller finishes speaking their sentence:
          if (result.finalResult && words.isNotEmpty) {
            if (!_isSelfEcho(words)) {
              if (mounted) setState(() => _liveStreamingWords = '');
              _handleCallerSpoke(words);
            }
          }
        },
      );
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
        _aiStatus = 'Call Picked Up by Mithun (Live)';
        _activeTranscript.add({
          'role': 'assistant',
          'content': '⚡ [Mithun Picked Up the Call — Speaking Directly]',
        });
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You picked up the call with $_callerName! Speak directly.'),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleCallerSpoke(String text) async {
    await _stt.stop();
    if (mounted) {
      setState(() {
        _isListening = false;
        _activeTranscript.add({'role': 'caller', 'content': text});
        _aiStatus = 'Aarohi processing response…';
      });
    }

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'call_agent',
        body: {
          'action': 'dialogue',
          'direction': _callDirection,
          'caller_name': _callerName,
          'caller_phone': _callerPhone,
          'booking_id': _selectedBookingId,
          'caller_message': text,
          'transcript': _activeTranscript,
        },
      );

      final data = res.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? 'Thank you, I have noted that.';
      final reason = data['call_reason'] as String?;
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();
      final callDone = data['call_completed'] as bool? ?? false;

      if (mounted) {
        setState(() {
          if (reason != null && reason.isNotEmpty) _liveReason = reason;
          _activeTranscript.add({'role': 'assistant', 'content': reply});
        });
      }

      await _speakWithLiveInterruption(
        reply,
        emotion: emotion,
        onCompleted: () {
          if (callDone) {
            _endCall();
          }
        },
      );
    } catch (e) {
      debugPrint('Dialogue step error: $e');
      if (mounted) {
        setState(() => _aiStatus = 'Connection error');
      }
    }
  }

  Future<void> _endCall() async {
    await _tts.stop();
    await _stt.stop();
    setState(() {
      _inCall = false;
      _isListening = false;
      _isSpeaking = false;
      _aiStatus = 'Call ended & saved';
    });
    // Refresh bookings and call logs
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Call completed: "$_liveReason"'),
          backgroundColor: Aura.surfaceHigh,
        ),
      );
    }
  }

  // --- Booking Management Dialog ---

  Future<void> _showAddBookingDialog() async {
    final titleCtrl = TextEditingController();
    final contactCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    TimeOfDay selectedTime = const TimeOfDay(hour: 15, minute: 0);

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: Aura.surface,
          title: const Text('Add New Booking',
              style: TextStyle(color: Aura.amberSoft)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Booking Title',
                    hintText: 'e.g. Dental Cleaning, Flight, Dinner',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contactCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Contact / Business Name',
                    hintText: 'e.g. Dr. Sharma Clinic',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    hintText: '+91 98765 43210',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                            '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: DateTime.now(),
                            lastDate:
                                DateTime.now().add(const Duration(days: 365)),
                          );
                          if (d != null) setDlgState(() => selectedDate = d);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.access_time, size: 16),
                        label: Text(selectedTime.format(context)),
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: selectedTime,
                          );
                          if (t != null) setDlgState(() => selectedTime = t);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notes (Optional)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: Aura.amberSoft),
              onPressed: () async {
                final title = titleCtrl.text.trim();
                final contact = contactCtrl.text.trim();
                if (title.isEmpty || contact.isEmpty) return;

                final bookingDateTime = DateTime(
                  selectedDate.year,
                  selectedDate.month,
                  selectedDate.day,
                  selectedTime.hour,
                  selectedTime.minute,
                );

                await Supabase.instance.client.from('bookings').insert({
                  'title': title,
                  'contact_name': contact,
                  'phone_number': phoneCtrl.text.trim(),
                  'booking_time': bookingDateTime.toIso8601String(),
                  'status': 'pending',
                  'notes': notesCtrl.text.trim(),
                });

                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) _loadData();
              },
              child: const Text('Save Booking',
                  style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aura.bg,
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.phone_in_talk, color: Aura.amber),
            SizedBox(width: 10),
            Text('Aarohi Calls & Bookings',
                style: TextStyle(
                    color: Aura.amberSoft,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Aura.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aura.outline.withValues(alpha: 0.5)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_done, size: 14, color: Colors.greenAccent),
                SizedBox(width: 6),
                Text('Gemini 24/7',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Aura.amber,
          labelColor: Aura.amberSoft,
          unselectedLabelColor: Aura.textDim,
          tabs: const [
            Tab(icon: Icon(Icons.record_voice_over), text: 'Call Assistant'),
            Tab(icon: Icon(Icons.event_available), text: 'Bookings'),
            Tab(icon: Icon(Icons.history), text: 'Call History'),
          ],
        ),
      ),
      body: _isRinging
          ? _buildIncomingCallView()
          : _inCall
              ? _buildLiveCallView()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildAssistantHub(),
                    _buildBookingsTab(),
                    _buildCallHistoryTab(),
                  ],
                ),
    );
  }

  // --- Tab 1: Call Assistant Hub ---
  Widget _buildAssistantHub() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Complete Access & Permissions Card
        if (!_permissionsGranted)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.amber.shade900.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Aura.amber.withValues(alpha: 0.6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.security, color: Aura.amber, size: 20),
                    SizedBox(width: 8),
                    Text('Give Complete Access',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Allow Phone, Microphone, and Contact access so Aarohi can answer calls, listen, and dial out with full device access.',
                  style: TextStyle(fontSize: 12.5, color: Aura.textDim, height: 1.3),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Aura.amber,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.check_circle, size: 18),
                        label: const Text('Grant All Access',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: _requestAllPermissions,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: BorderSide(color: Aura.outline.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: openAppSettings,
                      child: const Text('App Settings'),
                    ),
                  ],
                ),
              ],
            ),
          )
        else
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.green.shade900.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_user, color: Colors.greenAccent, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Full Access Active: Phone, Mic & Contacts Connected',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.white70,
                  ),
                  onPressed: openAppSettings,
                  child: const Text('Settings', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),

        // Live Screen Feature Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Aura.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Aura.outline.withValues(alpha: 0.4)),
            boxShadow: Aura.glow(opacity: 0.15),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Aura.hearth,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.phone_callback,
                        color: Aura.amber, size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI Call Screener',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Aura.amberSoft)),
                        Text('Answers callers & asks why they called',
                            style:
                                TextStyle(fontSize: 13, color: Aura.textDim)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'When active, Aarohi greets incoming callers, inquires their reason for calling, verifies booking confirmations against your calendar, and saves summaries to your phone.',
                style: TextStyle(fontSize: 13.5, color: Aura.text, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aura.amber,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.ring_volume),
                label: const Text('Simulate Incoming Call (Answer with AI)',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                onPressed: () => _triggerIncomingCallAlert(
                    name: 'Apex Dental Clinic', phone: '+91 98765 43210'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Direct Phone Dialer & Contact Search Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Aura.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color: Colors.greenAccent.withValues(alpha: 0.08),
                blurRadius: 16,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.phone_in_talk, color: Colors.greenAccent, size: 22),
                  SizedBox(width: 8),
                  Text('Search Contact or Type Number',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Type a contact name or phone number. Aarohi can talk out loud in the AI Call, or redirect to your phone dialer.',
                style: TextStyle(fontSize: 12.5, color: Aura.textDim, height: 1.3),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _phoneDialerController,
                keyboardType: TextInputType.text,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: 'Search contact (e.g. Apex, Dr. Alok) or number…',
                  hintStyle: const TextStyle(color: Aura.textDim),
                  filled: true,
                  fillColor: Aura.surfaceLow,
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, color: Aura.amberSoft, size: 20),
                  suffixIcon: _phoneDialerController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18, color: Aura.textDim),
                          onPressed: () {
                            _phoneDialerController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),

              // Filtered Contact Suggestions
              if (_getFilteredContacts().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _searchQuery.isEmpty ? 'QUICK CONTACTS & BOOKINGS' : 'MATCHING CONTACTS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                    color: Aura.amber.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _getFilteredContacts().map((contact) {
                    final name = contact['name'] ?? '';
                    final phone = contact['phone'] ?? '';
                    return ActionChip(
                      backgroundColor: Aura.surfaceLow,
                      side: BorderSide(color: Aura.outline.withValues(alpha: 0.4)),
                      avatar: const Icon(Icons.person, size: 14, color: Aura.amberSoft),
                      label: Text(
                        '$name ($phone)',
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                      ),
                      onPressed: () {
                        setState(() {
                          _phoneDialerController.text = phone;
                          _searchQuery = phone.toLowerCase();
                        });
                      },
                    );
                  }).toList(),
                ),
              ],

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.record_voice_over, size: 18),
                      label: const Text('AI Voice Call',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      onPressed: () {
                        final num = _phoneDialerController.text.trim();
                        if (num.isNotEmpty) {
                          _startOutboundToNumber(num);
                        } else {
                          _triggerIncomingCallAlert(
                              name: 'Apex Dental Clinic', phone: '+91 98765 43210');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: BorderSide(color: Aura.outline.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.dialpad, size: 16),
                      label: const Text('Phone App'),
                      onPressed: () {
                        final num = _phoneDialerController.text.trim();
                        if (num.isNotEmpty) {
                          _makePhoneCall(num);
                        } else {
                          _makePhoneCall('+919876543210');
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Cellular Calling Options: Fonoster (Open-Source) & Twilio
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Aura.amber,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.hub, size: 18),
                      label: Text(
                        _isFonosterDialing ? 'Dialing…' : 'Fonoster Call',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      onPressed: _isFonosterDialing
                          ? null
                          : () {
                              final num = _phoneDialerController.text.trim();
                              if (num.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please enter a phone number to call')),
                                );
                              } else {
                                _placeFonosterCellularCall(num);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Aura.amberSoft,
                        side: const BorderSide(color: Aura.amber),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.cell_tower, size: 18),
                      label: Text(
                        _isTwilioDialing ? 'Dialing…' : 'Twilio Call',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      onPressed: _isTwilioDialing
                          ? null
                          : () {
                              final num = _phoneDialerController.text.trim();
                              if (num.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please enter a phone number to call')),
                                );
                              } else {
                                _placeTwilioCellularCall(num);
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Telephony Settings Links Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: Aura.textDim,
                    ),
                    icon: const Icon(Icons.settings, size: 13),
                    label: const Text('Fonoster Setup', style: TextStyle(fontSize: 11.5)),
                    onPressed: () => _showFonosterConfigDialog(
                      pendingPhone: _phoneDialerController.text.trim(),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: Aura.textDim,
                    ),
                    icon: const Icon(Icons.settings, size: 13),
                    label: const Text('Twilio Setup', style: TextStyle(fontSize: 11.5)),
                    onPressed: () => _showTwilioConfigDialog(
                      pendingPhone: _phoneDialerController.text.trim(),
                    ),
                  ),
                ],
              ),
              if (_fonosterStatusMessage.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade900.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 15, color: Colors.purpleAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_fonosterStatusMessage,
                            style: const TextStyle(fontSize: 12, color: Colors.purpleAccent)),
                      ),
                    ],
                  ),
                ),
              ],
              if (_twilioStatusMessage.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade900.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 15, color: Colors.lightBlueAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_twilioStatusMessage,
                            style: const TextStyle(fontSize: 12, color: Colors.lightBlueAccent)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aura.amberSoft,
                  side: BorderSide(color: Aura.amber.withValues(alpha: 0.5)),
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.voicemail, size: 18),
                label: const Text('Test Apple Live Voicemail (Answer & Transcribe Live)'),
                onPressed: () {
                  final num = _phoneDialerController.text.trim();
                  final phone = num.isNotEmpty ? num : '+91 98765 43210';
                  _triggerIncomingCallAlert(
                      name: num.isNotEmpty ? 'Caller ($num)' : 'Apex Dental Clinic',
                      phone: phone);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Quick Outbound Confirmations
        Text('OUTBOUND BOOKING CONFIRMATIONS',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Aura.amber.withValues(alpha: 0.8))),
        const SizedBox(height: 12),
        if (_bookings.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Aura.surfaceLow,
                borderRadius: BorderRadius.circular(12)),
            child: const Text('No pending bookings to confirm.',
                style: TextStyle(color: Aura.textDim)),
          )
        else
          ..._bookings.take(3).map((b) {
            final isPending = (b['status'] ?? 'pending') == 'pending';
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Aura.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isPending
                      ? Aura.amber.withValues(alpha: 0.3)
                      : Aura.outline.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b['title'] ?? 'Booking',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                          '${b['contact_name']} • ${_formatDate(b['booking_time'])}',
                          style: const TextStyle(
                              fontSize: 13, color: Aura.textDim),
                        ),
                      ],
                    ),
                  ),
                  if ((b['phone_number'] ?? '').isNotEmpty) ...[
                    IconButton(
                      tooltip: 'Call Phone',
                      icon: const Icon(Icons.phone, color: Colors.greenAccent, size: 20),
                      onPressed: () => _makePhoneCall(b['phone_number']),
                    ),
                    const SizedBox(width: 4),
                  ],
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aura.amberSoft,
                      side: const BorderSide(color: Aura.amber),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.call_made, size: 16),
                    label: const Text('AI Call'),
                    onPressed: () => _startOutboundConfirmation(b),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  // --- Tab 2: Bookings Hub ---
  Widget _buildBookingsTab() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Aura.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('New Booking'),
        onPressed: _showAddBookingDialog,
      ),
      body: _loadingData
          ? const Center(child: CircularProgressIndicator(color: Aura.amber))
          : _bookings.isEmpty
              ? const Center(
                  child: Text('No bookings found. Tap + to add one.',
                      style: TextStyle(color: Aura.textDim)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                  itemCount: _bookings.length,
                  itemBuilder: (context, index) {
                    final b = _bookings[index];
                    final status = b['status'] as String? ?? 'pending';
                    Color statusColor = Aura.amber;
                    if (status == 'confirmed') {
                      statusColor = Colors.greenAccent;
                    } else if (status == 'rescheduled') {
                      statusColor = Aura.blue;
                    } else if (status == 'cancelled') {
                      statusColor = Colors.redAccent;
                    }

                    return Card(
                      color: Aura.surface,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                            color: Aura.outline.withValues(alpha: 0.3)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    b['title'] ?? '',
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color:
                                            statusColor.withValues(alpha: 0.5)),
                                  ),
                                  child: Text(
                                    status.toUpperCase(),
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: statusColor),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.person,
                                    size: 15, color: Aura.textDim),
                                const SizedBox(width: 6),
                                Text(b['contact_name'] ?? '',
                                    style: const TextStyle(
                                        fontSize: 14, color: Aura.textDim)),
                                if ((b['phone_number'] ?? '').isNotEmpty) ...[
                                  const SizedBox(width: 12),
                                  const Icon(Icons.phone,
                                      size: 15, color: Aura.textDim),
                                  const SizedBox(width: 6),
                                  Text(b['phone_number'],
                                      style: const TextStyle(
                                          fontSize: 14, color: Aura.textDim)),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.calendar_month,
                                    size: 15, color: Aura.amberSoft),
                                const SizedBox(width: 6),
                                Text(
                                  _formatDate(b['booking_time']),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      color: Aura.amberSoft,
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                            if ((b['notes'] ?? '').isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('Notes: ${b['notes']}',
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: Aura.textDim,
                                      fontStyle: FontStyle.italic)),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if ((b['phone_number'] ?? '').isNotEmpty) ...[
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Aura.amberSoft,
                                      side: BorderSide(
                                          color: Aura.amber
                                              .withValues(alpha: 0.6)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.hub, size: 13),
                                    label: const Text('Fonoster',
                                        style: TextStyle(fontSize: 12)),
                                    onPressed: () => _placeFonosterCellularCall(
                                      b['phone_number'],
                                      bookingId: b['id'],
                                      contactName: b['contact_name'],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white70,
                                      side: BorderSide(
                                          color: Aura.outline
                                              .withValues(alpha: 0.5)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.dialpad, size: 13),
                                    label: const Text('Phone',
                                        style: TextStyle(fontSize: 12)),
                                    onPressed: () =>
                                        _makePhoneCall(b['phone_number']),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                if (status != 'confirmed')
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.green.shade700,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.record_voice_over,
                                        size: 15),
                                    label: const Text('AI Call',
                                        style: TextStyle(fontSize: 12)),
                                    onPressed: () =>
                                        _startOutboundConfirmation(b),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  // --- Tab 3: Call History & Reasons ---
  Widget _buildCallHistoryTab() {
    if (_loadingData) {
      return const Center(
          child: CircularProgressIndicator(color: Aura.amber));
    }
    if (_callLogs.isEmpty) {
      return const Center(
        child: Text('No screened calls recorded yet.',
            style: TextStyle(color: Aura.textDim)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _callLogs.length,
      itemBuilder: (context, index) {
        final log = _callLogs[index];
        final direction = log['direction'] as String? ?? 'inbound';
        final isOutbound = direction == 'outbound';
        final reason = log['call_reason'] as String? ?? 'General Inquiry';
        final summary = log['summary'] as String? ?? '';
        final transcript = log['transcript'] as List<dynamic>? ?? [];

        return Card(
          color: Aura.surface,
          margin: const EdgeInsets.only(bottom: 14),
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
                  children: [
                    Icon(
                      isOutbound ? Icons.call_made : Icons.call_received,
                      size: 18,
                      color: isOutbound ? Aura.blue : Colors.greenAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        log['caller_name'] ?? 'Unknown Caller',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ),
                    Text(
                      _formatTimeAgo(log['created_at']),
                      style:
                          const TextStyle(fontSize: 12, color: Aura.textDim),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Call Reason Badge Section
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Aura.hearth.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: Aura.amber.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.help_outline,
                          size: 16, color: Aura.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(
                                fontSize: 13, color: Colors.white),
                            children: [
                              const TextSpan(
                                text: 'Reason for Call: ',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Aura.amberSoft),
                              ),
                              TextSpan(text: reason),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    summary,
                    style:
                        const TextStyle(fontSize: 13.5, color: Aura.text),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if ((log['caller_phone'] ?? '').isNotEmpty) ...[
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.greenAccent,
                          side: const BorderSide(color: Colors.greenAccent),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.phone, size: 14),
                        label: const Text('Call Back'),
                        onPressed: () => _makePhoneCall(log['caller_phone']),
                      ),
                      const SizedBox(width: 8),
                    ],
                    TextButton.icon(
                      icon: const Icon(Icons.forum_outlined, size: 16),
                      label: const Text('View Transcript'),
                      style: TextButton.styleFrom(
                          foregroundColor: Aura.amberSoft),
                      onPressed: () => _showTranscriptModal(
                          log['caller_name'] ?? 'Caller', transcript),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- Incoming Call Ringing View (Screen & Answer) ---
  Widget _buildIncomingCallView() {
    return Container(
      color: Aura.bg,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          // Pulsing Avatar with Glowing Ring
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Aura.surfaceHigh,
              border: Border.all(color: Aura.amber, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Aura.amber.withValues(alpha: 0.5),
                  blurRadius: 30,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: const Icon(Icons.phone_in_talk, size: 50, color: Aura.amber),
          ),
          const SizedBox(height: 24),

          // Incoming Call Label
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.green.shade900.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.6)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.ring_volume, size: 16, color: Colors.greenAccent),
                SizedBox(width: 8),
                Text(
                  'INCOMING CALL…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Colors.greenAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Text(
            _ringingCallerName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _ringingCallerPhone,
            style: const TextStyle(fontSize: 16, color: Aura.textDim),
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Aura.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aura.outline.withValues(alpha: 0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.voicemail, color: Aura.amber, size: 24),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Aarohi Live Voicemail will answer, ask for their reason, and transcribe their words live on screen so you can pick up anytime.',
                    style: TextStyle(fontSize: 12.5, color: Aura.text, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),

          // Big "Answer with Live Voicemail" Button (Apple Live Voicemail Style)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Aura.amber,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              elevation: 8,
              shadowColor: Aura.amber.withValues(alpha: 0.6),
            ),
            icon: const Icon(Icons.voicemail, size: 24),
            label: const Text(
              'Answer with Live Voicemail',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            onPressed: _answerCallWithAarohi,
          ),
          const SizedBox(height: 16),

          // Two bottom buttons: Decline & Answer on Phone
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.call_end, size: 18),
                  label: const Text('Decline'),
                  onPressed: _declineRingingCall,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.call, size: 18),
                  label: const Text('Phone App'),
                  onPressed: () {
                    setState(() => _isRinging = false);
                    _makePhoneCall(_ringingCallerPhone);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // --- Active Live Call Screen ---
  Widget _buildLiveCallView() {
    return Container(
      color: Aura.bg,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          // ALWAYS VISIBLE TOP HANG UP BAR
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.shade900.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: Colors.greenAccent),
                    SizedBox(width: 6),
                    Text('CALL IN PROGRESS', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                icon: const Icon(Icons.call_end, size: 18),
                label: const Text('HANG UP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                onPressed: _endCall,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Caller Avatar with Glowing Aura
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Aura.surfaceHigh,
              border: Border.all(color: Aura.amber, width: 2),
              boxShadow: Aura.glow(opacity: 0.4),
            ),
            child: Icon(
              _callDirection == 'inbound'
                  ? Icons.record_voice_over
                  : Icons.phone_forwarded,
              size: 40,
              color: Aura.amber,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _callerName,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(_callerPhone,
              style: const TextStyle(fontSize: 14, color: Aura.textDim)),
          const SizedBox(height: 8),

          // Real-time Status Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Aura.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Aura.amber.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isSpeaking
                        ? Colors.greenAccent
                        : _isListening
                            ? Aura.amber
                            : Aura.blue,
                  ),
                ),
                const SizedBox(width: 8),
                Text(_aiStatus,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Aura.amberSoft)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Detected Live Reason Banner
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Aura.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Aura.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Identified Reason: $_liveReason',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Live Transcript Feed
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Aura.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Aura.outline.withValues(alpha: 0.3)),
              ),
              child: (_activeTranscript.isEmpty && _liveStreamingWords.isEmpty)
                  ? const Center(
                      child: Text('Live Voicemail active… Waiting for caller speech.',
                          style: TextStyle(color: Aura.textDim)),
                    )
                  : ListView.builder(
                      itemCount: _activeTranscript.length + (_liveStreamingWords.isNotEmpty ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _activeTranscript.length && _liveStreamingWords.isNotEmpty) {
                          // Real-time live streaming words bubble (Apple Live Voicemail)
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade900.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.7)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.greenAccent.withValues(alpha: 0.2),
                                      blurRadius: 10,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.mic, size: 13, color: Colors.greenAccent),
                                        SizedBox(width: 5),
                                        Text('Caller (Speaking Live…)',
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      '$_liveStreamingWords ▋',
                                      style: const TextStyle(fontSize: 14.5, color: Colors.white, fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }

                        final turn = _activeTranscript[i];
                        final isAarohi = turn['role'] == 'assistant';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Align(
                            alignment: isAarohi
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isAarohi
                                    ? Aura.hearth
                                    : Aura.surfaceHigh,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isAarohi
                                      ? Aura.amber.withValues(alpha: 0.4)
                                      : Colors.white24,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isAarohi ? 'Aarohi (AI)' : 'Caller',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isAarohi
                                            ? Aura.amberSoft
                                            : Aura.blue),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(turn['content'] ?? '',
                                      style: const TextStyle(
                                          fontSize: 14, color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          // Voice Controls during call
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _isListening ? Colors.green.shade700 : Aura.surfaceHigh,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  side: BorderSide(
                      color: _isListening ? Colors.greenAccent : Aura.outline),
                ),
                icon: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 20,
                  color: _isListening ? Colors.greenAccent : Colors.white70,
                ),
                label: Text(
                  _isListening ? 'Aarohi Listening…' : 'Tap to Speak',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                onPressed: () {
                  if (_isListening) {
                    _stt.stop();
                    setState(() => _isListening = false);
                  } else {
                    _startListeningToCaller();
                  }
                },
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aura.amberSoft,
                  side: const BorderSide(color: Aura.amber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.volume_up, size: 18),
                label:
                    const Text('Hear Aarohi Again', style: TextStyle(fontSize: 13)),
                onPressed: () {
                  final lastAarohiTurn = _activeTranscript.lastWhere(
                    (t) => t['role'] == 'assistant',
                    orElse: () => {'content': ''},
                  );
                  final c = lastAarohiTurn['content'] ?? '';
                  if (c.isNotEmpty) {
                    _tts.speak(c);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Quick Voice / Text response input for manual test
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualInputController,
                  decoration: InputDecoration(
                    hintText: 'Simulate caller speaking…',
                    hintStyle: const TextStyle(color: Aura.textDim),
                    filled: true,
                    fillColor: Aura.surface,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (val) {
                    if (val.trim().isNotEmpty) {
                      _manualInputController.clear();
                      _handleCallerSpoke(val.trim());
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Aura.amber),
                icon: const Icon(Icons.send, color: Colors.black),
                onPressed: () {
                  final txt = _manualInputController.text.trim();
                  if (txt.isNotEmpty) {
                    _manualInputController.clear();
                    _handleCallerSpoke(txt);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Action Buttons: Apple Live Voicemail "Pick Up Call" or "End & Save"
          Row(
            children: [
              if (!_callPickedUp) ...[
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 6,
                    ),
                    icon: const Icon(Icons.call, size: 22),
                    label: const Text(
                      'Pick Up Call',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _pickUpCall,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 6,
                    ),
                    icon: const Icon(Icons.call_end, size: 20),
                    label: const Text('HANG UP',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                    onPressed: _endCall,
                  ),
                ),
              ] else ...[
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.greenAccent,
                      side: const BorderSide(color: Colors.greenAccent),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.phone_forwarded, size: 18),
                    label: const Text('Phone App'),
                    onPressed: () => _makePhoneCall(_callerPhone),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 6,
                    ),
                    icon: const Icon(Icons.call_end, size: 20),
                    label: const Text('HANG UP / END CALL',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                    onPressed: _endCall,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _showTranscriptModal(String name, List<dynamic> transcript) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.record_voice_over, color: Aura.amber),
                const SizedBox(width: 8),
                Text('Call Transcript: $name',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Aura.amberSoft)),
                const Spacer(),
                IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close)),
              ],
            ),
            const Divider(color: Aura.outline),
            Expanded(
              child: ListView.builder(
                itemCount: transcript.length,
                itemBuilder: (context, i) {
                  final turn = transcript[i] as Map<String, dynamic>;
                  final isAarohi = turn['role'] == 'assistant';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isAarohi ? Aura.hearth : Aura.surfaceLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isAarohi
                            ? Aura.amber.withValues(alpha: 0.3)
                            : Colors.white10,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAarohi ? 'Aarohi' : name,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color:
                                  isAarohi ? Aura.amberSoft : Aura.blue),
                        ),
                        const SizedBox(height: 4),
                        Text(turn['content'] ?? '',
                            style: const TextStyle(
                                fontSize: 14, color: Colors.white)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return '${dt.day}/${dt.month}/${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatTimeAgo(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
