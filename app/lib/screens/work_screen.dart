import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

/// Strips emails and long digit runs (phones, card fragments) before any
/// cloud call — customer identifiers stay on-device.
String redact(String text) => text
    .replaceAll(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), '[email]')
    .replaceAll(RegExp(r'\+?\d[\d\s-]{7,}\d'), '[number]');

class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key});

  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> {
  CameraController? _cam;
  bool _busy = false;
  String _status = 'CAMERA STARTING…';

  // Current analysis, if any.
  String? _ocrText;
  String? _logId;
  String _summary = '';
  int? _macroNumber;
  String _reasoning = '';
  String _reply = '';
  String? _decision; // set after approve/edit/reject

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _cam = CameraController(back, ResolutionPreset.high,
          enableAudio: false);
      await _cam!.initialize();
      if (mounted) setState(() => _status = 'READY');
    } catch (e) {
      if (mounted) setState(() => _status = 'CAMERA UNAVAILABLE');
      debugPrint('camera error: $e');
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    super.dispose();
  }

  Future<void> _readIt() async {
    if (_cam == null || !_cam!.value.isInitialized || _busy) return;
    setState(() {
      _busy = true;
      _status = 'READING…';
      _decision = null;
      _ocrText = null;
    });
    try {
      final shot = await _cam!.takePicture();
      final recognizer = TextRecognizer();
      final result =
          await recognizer.processImage(InputImage.fromFilePath(shot.path));
      await recognizer.close();
      final text = redact(result.text.trim());
      if (text.length < 20) {
        setState(() => _status = "CAN'T READ THIS CLEARLY — ADJUST ANGLE/FONT");
        return;
      }
      setState(() {
        _ocrText = text;
        _status = 'THINKING…';
      });

      final res = await Supabase.instance.client.functions
          .invoke('work', body: {'ocr_text': text});
      final data = res.data as Map<String, dynamic>;
      if (data['offline'] == true) {
        setState(() => _status = 'AI SERVICE ERROR — PLEASE RETRY');
        return;
      }
      setState(() {
        _logId = data['log_id'] as String?;
        _summary = data['summary'] as String? ?? '';
        _macroNumber = data['macro_number'] as int?;
        _reasoning = data['reasoning'] as String? ?? '';
        _reply = data['reply'] as String? ?? '';
        _status = 'READY';
      });
    } catch (e) {
      debugPrint('read error: $e');
      setState(() => _status = 'READ FAILED — TRY AGAIN');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _decide(String decision, String finalReply) async {
    final db = Supabase.instance.client;
    if (_logId != null) {
      await db.from('llm_logs').update({
        'decision': decision,
        'final_output': decision == 'rejected' ? null : finalReply,
      }).eq('id', _logId!);
    }
    await db.from('tickets').insert({
      'ocr_text': _ocrText ?? '',
      'decision': decision,
      'final_reply': decision == 'rejected' ? null : finalReply,
    });
    setState(() {
      _decision = decision;
      _reply = finalReply;
    });
  }

  Future<void> _edit() async {
    final ctrl = TextEditingController(text: _reply);
    final edited = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        title: const Text('Edit reply'),
        content: TextField(controller: ctrl, maxLines: 10, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (edited != null && edited.trim().isNotEmpty) {
      await _decide('edited', edited.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _ocrText != null && _reply.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Work Station',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Aura.amberSoft, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 10,
                    color: _status == 'READY' ? Aura.amber : Aura.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status,
                      style: const TextStyle(
                          color: Aura.textDim,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Calibration view — what she can see.
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _cam != null && _cam!.value.isInitialized
                    ? CameraPreview(_cam!)
                    : Container(
                        color: Aura.surfaceLow,
                        alignment: Alignment.center,
                        child: Text(_status,
                            style: const TextStyle(
                                color: Aura.textDim,
                                letterSpacing: 2,
                                fontSize: 12)),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _readIt,
              icon: const Icon(Icons.remove_red_eye_outlined),
              label: Text(_busy ? 'WORKING…' : 'READ IT'),
            ),
            const SizedBox(height: 12),
            if (hasResult)
              Expanded(
                child: ListView(
                  children: [
                    if (_summary.isNotEmpty) ...[
                      const Text('SITUATION',
                          style: TextStyle(
                              color: Aura.textDim,
                              letterSpacing: 3,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(_summary,
                          style: const TextStyle(height: 1.5)),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      _macroNumber != null
                          ? 'MACRO #$_macroNumber FITS'
                          : 'NO MACRO FITS — DRAFT BELOW',
                      style: const TextStyle(
                          color: Aura.amberSoft,
                          letterSpacing: 2,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                    ),
                    if (_reasoning.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_reasoning,
                            style: const TextStyle(
                                color: Aura.textDim, fontSize: 13)),
                      ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Aura.surfaceLow,
                        borderRadius: BorderRadius.circular(12),
                        border: const Border(
                            left: BorderSide(color: Aura.amber, width: 2)),
                      ),
                      child: SelectableText(_reply,
                          style: const TextStyle(height: 1.5)),
                    ),
                    const SizedBox(height: 12),
                    if (_decision == null)
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _decide('accepted', _reply),
                              child: const Text('APPROVE'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _edit,
                              child: const Text('EDIT'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _decide('rejected', ''),
                              child: const Text('REJECT'),
                            ),
                          ),
                        ],
                      )
                    else
                      Text('LOGGED: ${_decision!.toUpperCase()}',
                          style: const TextStyle(
                              color: Aura.amberSoft,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w700)),
                    const SizedBox(height: 24),
                  ],
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ),
    );
  }
}
