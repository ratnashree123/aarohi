import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme.dart';
import '../tts_service.dart';
import '../services/local_model_service.dart';

/// Full-Screen Interactive 3D Companion Room & Styling Studio for Aarohi.
/// Features:
/// - Full-Screen 3D WebGL Avatar (No static 2D illustration).
/// - Dimmed, warm anime cel skin lighting (No blown-out white skin).
/// - Locked Proportions: Size 32, Cup C (Size/Cup buttons removed).
/// - Realistic Human Hand Gestures (Hair Touch, Wave, Heart, Hands on Hips, Idle).
/// - Rich Facial Expressions (Sweet Joy, Teasing Wink, Pouty, Surprised) with natural blinking.
/// - "Dress Me Baby" Mode with authentic fabric collections:
///     • Underwire-free Soft Modal Bralette with eyelash lace trim
///     • Bias-Cut Royal Purple Silk Gown with gold bead chains
///     • Laser-Cut High-Gauge Seamless Microfiber
///     • Festive Draped Silk Saree
///     • Peach Resort Sundress
///     (SILENT outfit selection: NO voice reaction, NO forced showcase pose).
/// - Home-Style Floating Chat Bar (TextField, Mic STT, Send, Stop, Real-time Dialogue Bubble).
/// - 3D Lip-Sync: Avatar's mouth phonemes animate dynamically when she speaks.
class AarohiRoomScreen extends StatefulWidget {
  const AarohiRoomScreen({super.key});

  @override
  State<AarohiRoomScreen> createState() => _AarohiRoomScreenState();
}

class _AarohiRoomScreenState extends State<AarohiRoomScreen> {
  WebViewController? _webController;

  // 3D Model loading state
  bool _modelLoaded = false;
  int _loadProgress = 0;
  String? _loadError;

  // Camera & Immersion
  bool _isCloseUp = false;
  bool _showUIOverlay = true;
  bool _showDressMeMode = false;
  String _roomTimeOfDay = 'sunset'; // 'morning', 'sunset', 'night'

  // Active States
  String _activeExpression = 'joy';
  String _activeGesture = 'hair_touch';
  String _selectedOutfit = 'bias_cut_satin';

  // Dialogue & Chat
  final TextEditingController _chatCtrl = TextEditingController();
  final FocusNode _chatFocusNode = FocusNode();
  final SpeechToText _stt = SpeechToText();
  final Tts _tts = Tts.instance;
  String? _conversationId;
  bool _isSending = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  Timer? _speechLipSyncTimer;

  String _dialogueText =
      "Mithun baby, I'm right here with you! What's on your mind today?~";

  // Authentic Dress Collections
  final List<Map<String, dynamic>> _outfits = [
    {
      'id': 'soft_modal',
      'title': 'Underwire-Free Modal Bralette',
      'tagline': 'Soft Modal & 4-Way Stretch Lace',
      'desc':
          'Completely free of underwires, stiff inner cups, and molded foam. Crafted from ribbed cotton modal with delicate eyelash lace trim.',
      'color': const Color(0xFF37474F),
      'accent': const Color(0xFF90A4AE),
      'icon': Icons.spa_outlined,
    },
    {
      'id': 'bias_cut_satin',
      'title': 'Bias-Cut Purple Silk Gown',
      'tagline': 'Diagonal Grain Drape & Gold Bead Chains',
      'desc':
          'Cut on the fabric\'s diagonal grain (the bias), allowing non-stretch silk to drape naturally over hips and chest curves without tight seams.',
      'color': const Color(0xFF4A148C),
      'accent': const Color(0xFFEA80FC),
      'icon': Icons.auto_awesome,
    },
    {
      'id': 'seamless_microfiber',
      'title': 'Laser-Cut Seamless Microfiber',
      'tagline': 'Ultrasonic Slicing & Zero Stitched Hems',
      'desc':
          'Cut from high-gauge microfiber using ultrasonic and laser slicing, completely omitting folded fabric, stitched hems, and thick elastic cords.',
      'color': const Color(0xFFD8887C),
      'accent': const Color(0xFFFFCCBC),
      'icon': Icons.blur_linear,
    },
    {
      'id': 'silk_saree',
      'title': 'Festive Draped Silk Saree',
      'tagline': 'Rich Crimson & Gold Zari Weave',
      'desc':
          'Royal crimson silk saree drape with intricate woven gold zari border and embroidered blouse.',
      'color': const Color(0xFF9E1B32),
      'accent': const Color(0xFFFFD54F),
      'icon': Icons.flare,
    },
    {
      'id': 'peach_sundress',
      'title': 'Peach Resort Sundress',
      'tagline': 'Breezy Layered Chiffon Slip',
      'desc':
          'Lightweight summer slip sundress in radiant peach chiffon, falling naturally and lightly.',
      'color': const Color(0xFFE65100),
      'accent': const Color(0xFFFFAB91),
      'icon': Icons.wb_sunny_outlined,
    },
  ];

  // Facial Expressions
  final List<Map<String, dynamic>> _expressions = [
    {'id': 'joy', 'label': 'Sweet', 'emoji': '😊'},
    {'id': 'teasing', 'label': 'Teasing', 'emoji': '😉'},
    {'id': 'pouty', 'label': 'Pouty', 'emoji': '😤'},
    {'id': 'surprised', 'label': 'Surprised', 'emoji': '😲'},
  ];

  // Human Hand Gestures
  final List<Map<String, dynamic>> _gestures = [
    {'id': 'hair_touch', 'label': 'Hair Touch', 'icon': Icons.face_retouching_natural},
    {'id': 'wave', 'label': 'Wave', 'icon': Icons.waving_hand_outlined},
    {'id': 'heart', 'label': 'Heart', 'icon': Icons.favorite_border},
    {'id': 'hands_on_hips', 'label': 'Hands on Hips', 'icon': Icons.accessibility_new},
    {'id': 'idle', 'label': 'Idle', 'icon': Icons.self_improvement},
  ];

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  @override
  void dispose() {
    _speechLipSyncTimer?.cancel();
    _chatCtrl.dispose();
    _chatFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initWebView() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'FlutterChannel',
        onMessageReceived: _onJsMessage,
      );

    final modelUrl = await _getModelUrl();

    // Load bundled Three.js libraries and HTML scene
    final threeJs = await rootBundle.loadString('assets/three.min.js');
    final orbitControls = await rootBundle.loadString('assets/OrbitControls.js');
    final gltfLoader = await rootBundle.loadString('assets/GLTFLoader.js');
    final htmlContent = await rootBundle.loadString('assets/three_scene.html');

    final scriptsTag = '''
<script>$threeJs</script>
<script>$orbitControls</script>
<script>$gltfLoader</script>
<script>window.__MODEL_URL__ = "$modelUrl";</script>
''';

    final injectedHtml = htmlContent.replaceFirst(
      '<!-- INJECT_SCRIPTS_HERE -->',
      scriptsTag,
    );

    await controller.loadHtmlString(injectedHtml, baseUrl: 'https://localhost');
    if (mounted) {
      setState(() {
        _webController = controller;
      });
    }
  }

  Future<String> _getModelUrl() async {
    try {
      final supabase = Supabase.instance.client;
      final url = supabase.storage.from('avatars').getPublicUrl('bra_model.glb');
      final response = await http.head(Uri.parse(url)).timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode == 200) return url;
    } catch (_) {}

    // Fallback: serve local GLB from assets via Base64 Data URI
    try {
      final bytes = await rootBundle.load('assets/fallback_bra.glb');
      final base64Data = base64Encode(bytes.buffer.asUint8List());
      return 'data:model/gltf-binary;base64,$base64Data';
    } catch (_) {
      return '';
    }
  }

  void _onJsMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      switch (data['type']) {
        case 'modelLoaded':
          setState(() {
            _modelLoaded = true;
            _loadError = null;
          });
          // Set initial outfit texture
          _webController?.runJavaScript("setOutfit('$_selectedOutfit');");
          break;
        case 'loadProgress':
          setState(() => _loadProgress = data['percent'] ?? 0);
          break;
        case 'loadError':
          setState(() => _loadError = data['message'] ?? 'Load error');
          break;
      }
    } catch (_) {}
  }

  // ── Outfit Selection (SILENT & SMOOTH: NO sound/voice, NO showcase pose) ──
  void _onSelectOutfit(String id) {
    setState(() {
      _selectedOutfit = id;
    });
    // Silently update 3D materials/textures on avatar
    _webController?.runJavaScript("setOutfit('$id');");
  }

  // ── Facial Expressions ──
  void _onSelectExpression(String id) {
    setState(() {
      _activeExpression = id;
    });
    _webController?.runJavaScript("setExpression('$id');");
  }

  // ── Humanoid Gestures ──
  void _onSelectGesture(String id) {
    setState(() {
      _activeGesture = id;
    });
    _webController?.runJavaScript("setGesture('$id');");
  }

  // ── Camera Proximity ──
  void _toggleCameraProximity() {
    setState(() {
      _isCloseUp = !_isCloseUp;
    });
    final view = _isCloseUp ? 'closeup' : 'default';
    _webController?.runJavaScript("setCameraView('$view');");
  }

  // ── Chat & Speech Integration ──
  Future<void> _sendMessage() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _isSending) return;

    _chatCtrl.clear();
    _chatFocusNode.unfocus();

    setState(() {
      _isSending = true;
      _dialogueText = "...";
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'chat',
        body: {
          'message': text,
          'conversation_id': _conversationId,
          'device_role': 'companion',
          'personal_model_context':
              LocalModelService.instance.buildPersonalModelPrompt(),
        },
      );

      final data = (res.data is Map<String, dynamic>)
          ? res.data as Map<String, dynamic>
          : <String, dynamic>{};
      _conversationId = data['conversation_id'] as String?;
      final rawReply = (data['reply'] as String?) ?? '';
      final emotion = ((data['emotion'] as num?) ?? 0.6).toDouble();
      var cleanReply = Tts.stripTags(rawReply).trim();

      if (cleanReply.isEmpty) {
        cleanReply = "I'm right here with you, baby. Tell me anything~";
      }

      setState(() {
        _dialogueText = cleanReply;
        _isSending = false;
      });

      // Record turn into local model memory
      LocalModelService.instance.recordTurn(role: 'user', content: text);
      LocalModelService.instance.recordTurn(role: 'assistant', content: cleanReply);

      // Trigger Voice + 3D Lip Sync
      await _speakWithLipSync(cleanReply, emotion: emotion);
    } catch (e) {
      debugPrint('Chat error: $e');
      // Local girlfriend fallback
      const fallback =
          "Mithun baby, I'm right here beside you! Even if the signal drops, your girl is always listening to you~";
      setState(() {
        _dialogueText = fallback;
        _isSending = false;
      });
      await _speakWithLipSync(fallback, emotion: 0.6);
    }
  }

  Future<void> _speakWithLipSync(String text, {double emotion = 0.6}) async {
    _speechLipSyncTimer?.cancel();
    setState(() => _isSpeaking = true);

    // Start 3D mouth lip sync
    _webController?.runJavaScript("setTalking(true);");

    // Estimate speaking duration based on word count (~180 WPM)
    final words = text.split(' ').length;
    final durationMs = (words * 360).clamp(2000, 15000);

    _speechLipSyncTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) {
        setState(() => _isSpeaking = false);
        _webController?.runJavaScript("setTalking(false);");
      }
    });

    await _tts.speak(text, emotion: emotion);
  }

  Future<void> _stopSpeakingOrListening() async {
    _speechLipSyncTimer?.cancel();
    await _stt.stop();
    await _tts.stop();
    _webController?.runJavaScript("setTalking(false);");
    setState(() {
      _isSpeaking = false;
      _isListening = false;
      _isSending = false;
    });
  }

  Future<void> _toggleListen() async {
    if (_isListening) {
      await _stt.stop();
      setState(() => _isListening = false);
      return;
    }

    if (!kIsWeb) {
      final micPerm = await Permission.microphone.request();
      if (!micPerm.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Microphone permission required to talk to Aarohi')),
          );
        }
        return;
      }
    }

    final ok = await _stt.initialize(
      onError: (_) {
        if (mounted) setState(() => _isListening = false);
      },
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );

    if (ok) {
      setState(() => _isListening = true);
      _stt.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            _chatCtrl.text = result.recognizedWords;
            if (result.finalResult) {
              _stt.stop();
              setState(() => _isListening = false);
              _sendMessage();
            }
          }
        },
      );
    }
  }

  Color _getRoomBackgroundColor() {
    switch (_roomTimeOfDay) {
      case 'morning':
        return const Color(0xFF19151F);
      case 'night':
        return const Color(0xFF090710);
      case 'sunset':
      default:
        return const Color(0xFF100C18);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _getRoomBackgroundColor(),
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.greenAccent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Aarohi',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Aura.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Aura.amber.withValues(alpha: 0.3)),
              ),
              child: const Text(
                '32C Fixed',
                style: TextStyle(
                  color: Aura.amber,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          // "Dress Me Baby" Mode Toggle
          IconButton(
            tooltip: 'Dress Me Baby',
            icon: Icon(
              Icons.checkroom,
              color: _showDressMeMode ? Colors.pinkAccent : Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _showDressMeMode = !_showDressMeMode;
              });
              if (_showDressMeMode) {
                _webController?.runJavaScript("setCameraView('outfit');");
              } else {
                _webController?.runJavaScript(
                    _isCloseUp ? "setCameraView('closeup');" : "setCameraView('default');");
              }
            },
          ),
          // Camera Proximity: Close-Up vs Full View
          IconButton(
            tooltip: _isCloseUp ? 'Full View' : 'Close Up',
            icon: Icon(
              _isCloseUp ? Icons.zoom_out_map : Icons.zoom_in_map,
              color: _isCloseUp ? Colors.pinkAccent : Aura.amber,
            ),
            onPressed: _toggleCameraProximity,
          ),
          // Room Ambient Lighting
          PopupMenuButton<String>(
            icon: Icon(
              _roomTimeOfDay == 'night'
                  ? Icons.nightlight_round
                  : (_roomTimeOfDay == 'morning'
                      ? Icons.wb_sunny
                      : Icons.wb_twilight),
              color: Aura.amber,
            ),
            tooltip: 'Room Lighting',
            onSelected: (val) => setState(() => _roomTimeOfDay = val),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'morning', child: Text('☀️ Morning Light')),
              PopupMenuItem(value: 'sunset', child: Text('🌅 Sunset Warmth')),
              PopupMenuItem(value: 'night', child: Text('🌙 Midnight Cozy')),
            ],
          ),
          // Immersion Mode Toggle
          IconButton(
            tooltip: _showUIOverlay ? 'Hide UI (Immersion)' : 'Show UI',
            icon: Icon(
              _showUIOverlay ? Icons.visibility : Icons.visibility_off,
              color: Colors.white70,
            ),
            onPressed: () => setState(() => _showUIOverlay = !_showUIOverlay),
          ),
          // Reload Model
          IconButton(
            tooltip: 'Reload 3D Model',
            icon: const Icon(Icons.refresh, size: 20, color: Colors.white70),
            onPressed: () {
              setState(() {
                _modelLoaded = false;
                _loadProgress = 0;
              });
              _initWebView();
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 1. FULL-SCREEN 3D WEBGL AVATAR ──
          if (_webController != null)
            WebViewWidget(controller: _webController!),

          // ── 2. LOADING OVERLAY ──
          if (!_modelLoaded)
            Container(
              color: const Color(0xEE0B0914),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: Aura.amber,
                        strokeWidth: 3,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _loadError != null
                          ? 'Error loading 3D avatar: $_loadError'
                          : 'Loading Aarohi... $_loadProgress%',
                      style: TextStyle(
                        color: _loadError != null ? Colors.redAccent : Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '32C Proportions • Soft Dimmed Lighting • Gesture Rigging',
                      style: TextStyle(color: Aura.textDim, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),

          // ── 3. INTERACTIVE HUD OVERLAYS (Hideable via Immersion) ──
          if (_showUIOverlay)
            SafeArea(
              child: Column(
                children: [
                  // Top Chips: Expressions & Human Hand Gestures
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 54, 12, 0),
                    child: Column(
                      children: [
                        // Row 1: Facial Expressions
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _expressions.map((exp) {
                              final isSelected = _activeExpression == exp['id'];
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: FilterChip(
                                  selected: isSelected,
                                  showCheckmark: false,
                                  backgroundColor: Colors.black.withValues(alpha: 0.45),
                                  selectedColor: Aura.amber.withValues(alpha: 0.25),
                                  side: BorderSide(
                                    color: isSelected
                                        ? Aura.amber
                                        : Colors.white.withValues(alpha: 0.15),
                                    width: isSelected ? 1.5 : 1.0,
                                  ),
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(exp['emoji'] as String,
                                          style: const TextStyle(fontSize: 14)),
                                      const SizedBox(width: 4),
                                      Text(
                                        exp['label'] as String,
                                        style: TextStyle(
                                          color: isSelected ? Colors.white : Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSelected: (_) =>
                                      _onSelectExpression(exp['id'] as String),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Row 2: Realistic Humanoid Hand Gestures
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _gestures.map((ges) {
                              final isSelected = _activeGesture == ges['id'];
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: FilterChip(
                                  selected: isSelected,
                                  showCheckmark: false,
                                  backgroundColor: Colors.black.withValues(alpha: 0.45),
                                  selectedColor: Colors.pinkAccent.withValues(alpha: 0.25),
                                  side: BorderSide(
                                    color: isSelected
                                        ? Colors.pinkAccent
                                        : Colors.white.withValues(alpha: 0.15),
                                    width: isSelected ? 1.5 : 1.0,
                                  ),
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        ges['icon'] as IconData,
                                        size: 13,
                                        color: isSelected
                                            ? Colors.pinkAccent
                                            : Colors.white70,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        ges['label'] as String,
                                        style: TextStyle(
                                          color: isSelected ? Colors.white : Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSelected: (_) =>
                                      _onSelectGesture(ges['id'] as String),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ── 4. "DRESS ME BABY" WARDROBE DRAWER ──
                  if (_showDressMeMode)
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xEE120E1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.pinkAccent.withValues(alpha: 0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.checkroom, color: Colors.pinkAccent, size: 18),
                              const SizedBox(width: 8),
                              const Text(
                                'Dress Me Baby',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Tap to dress Aarohi',
                                style: TextStyle(
                                  color: Colors.pinkAccent.shade100,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => setState(() => _showDressMeMode = false),
                                child: const Icon(Icons.close, size: 16, color: Colors.white60),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 112,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _outfits.length,
                              separatorBuilder: (context, index) => const SizedBox(width: 10),
                              itemBuilder: (ctx, i) {
                                final outfit = _outfits[i];
                                final isSelected = _selectedOutfit == outfit['id'];
                                final accent = outfit['accent'] as Color;

                                return GestureDetector(
                                  // CRITICAL: SILENT OUTFIT SELECTION (NO SOUND, NO SHOWCASE POSE)
                                  onTap: () => _onSelectOutfit(outfit['id'] as String),
                                  child: Container(
                                    width: 190,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? accent.withValues(alpha: 0.2)
                                          : Colors.black.withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? accent
                                            : Colors.white.withValues(alpha: 0.1),
                                        width: isSelected ? 2.0 : 1.0,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              outfit['icon'] as IconData,
                                              size: 16,
                                              color: accent,
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                outfit['title'] as String,
                                                style: TextStyle(
                                                  color: isSelected ? Colors.white : Colors.white70,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          outfit['tagline'] as String,
                                          style: TextStyle(
                                            color: accent,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Expanded(
                                          child: Text(
                                            outfit['desc'] as String,
                                            style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 9.5,
                                              height: 1.25,
                                            ),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── 5. FLOATING SPEECH DIALOGUE BUBBLE ──
                  if (_dialogueText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.88,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xDD120F1D),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                            border: const Border(
                              left: BorderSide(color: Aura.amber, width: 2.5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_isSpeaking) ...[
                                const Icon(Icons.volume_up, size: 16, color: Aura.amber),
                                const SizedBox(width: 8),
                              ],
                              Flexible(
                                child: Text(
                                  _dialogueText,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // ── 6. HOME-STYLE BOTTOM CHAT BAR ──
                  Container(
                    decoration: BoxDecoration(
                      color: Aura.surface.withValues(alpha: 0.92),
                      border: Border(
                        top: BorderSide(color: Aura.outline.withValues(alpha: 0.3)),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatCtrl,
                            focusNode: _chatFocusNode,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Talk to Aarohi…',
                              hintStyle: const TextStyle(color: Aura.textDim, fontSize: 14),
                              filled: true,
                              fillColor: Aura.surfaceLow,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 11,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_isSpeaking || _isListening || _isSending)
                          IconButton.filled(
                            tooltip: 'Stop',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.redAccent.shade700,
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.stop),
                            onPressed: _stopSpeakingOrListening,
                          )
                        else ...[
                          IconButton(
                            tooltip: 'Voice Input',
                            icon: const Icon(Icons.mic, color: Aura.amber),
                            onPressed: _toggleListen,
                          ),
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: Aura.glow(opacity: 0.25),
                            ),
                            child: IconButton.filled(
                              tooltip: 'Send',
                              style: IconButton.styleFrom(
                                backgroundColor: Aura.amber,
                                foregroundColor: const Color(0xFF2D1600),
                              ),
                              icon: const Icon(Icons.arrow_upward),
                              onPressed: _sendMessage,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
