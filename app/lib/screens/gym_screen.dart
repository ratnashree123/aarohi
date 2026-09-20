import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import '../tts_service.dart';

/// Parses a spoken set like "bench 60 8" / "bench press 60 kg 8 reps".
/// Words before the first number = exercise, first number = kg, second = reps.
({String exercise, double weight, int reps})? parseSet(String text) {
  final m = RegExp(
    r'^(.*?)\s+(\d+(?:\.\d+)?)\s*(?:kg|kilos?)?\s*[,x]?\s*(\d+)\s*(?:reps?)?\s*$',
    caseSensitive: false,
  ).firstMatch(text.trim());
  if (m == null) return null;
  final exercise = m.group(1)!.trim().toLowerCase();
  if (exercise.isEmpty) return null;
  return (
    exercise: exercise,
    weight: double.parse(m.group(2)!),
    reps: int.parse(m.group(3)!),
  );
}

class GymScreen extends StatefulWidget {
  const GymScreen({super.key});

  @override
  State<GymScreen> createState() => _GymScreenState();
}

class _GymScreenState extends State<GymScreen> {
  final _tts = Tts.instance;
  final _stt = SpeechToText();

  String _workoutName = '';
  List<String> _exercises = [];
  List<Map<String, dynamic>> _todaySets = [];

  bool _listening = false;
  String _heard = '';

  static const _restSeconds = 90; // ponytail: fixed 90s rest; make configurable if splits need it
  Timer? _timer;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final db = Supabase.instance.client;
    final workouts = await db.from('workouts').select().order('split_day');
    if (workouts.isNotEmpty) {
      // Deterministic rotation: weekday picks the split, no state to manage.
      final w = workouts[DateTime.now().weekday % workouts.length];
      _workoutName = w['name'] as String;
      _exercises = List<String>.from(w['exercises'] as List);
    }
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    _todaySets = List<Map<String, dynamic>>.from(
      await db
          .from('workout_logs')
          .select()
          .gte('logged_at', start.toIso8601String())
          .order('logged_at', ascending: false),
    );
    if (mounted) setState(() {});
  }

  // ---- rest timer ----

  void _toggleTimer() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      setState(() => _remaining = 0);
      return;
    }
    setState(() => _remaining = _restSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        _timer = null;
        setState(() => _remaining = 0);
        _tts.speak('Rest is over. Next set.');
      } else {
        setState(() => _remaining--);
      }
    });
  }

  // ---- voice set logging ----

  Future<void> _toggleListen() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _stt.initialize(
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (mounted) setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!ok) return;
    await _tts.stop();
    setState(() {
      _listening = true;
      _heard = '';
    });
    await _stt.listen(onResult: (r) {
      setState(() => _heard = r.recognizedWords);
      if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
        _logSet(r.recognizedWords);
      }
    });
  }

  Future<void> _logSet(String spoken) async {
    final parsed = parseSet(spoken);
    if (parsed == null) {
      _tts.speak("I didn't catch that. Say it like: bench, 60, 8 reps.");
      return;
    }
    final db = Supabase.instance.client;

    // Last time he did this exercise (before today) — for her reaction.
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final prev = await db
        .from('workout_logs')
        .select('weight_kg,reps')
        .ilike('exercise', parsed.exercise)
        .lt('logged_at', start.toIso8601String())
        .order('logged_at', ascending: false)
        .limit(1)
        .maybeSingle();

    await db.from('workout_logs').insert({
      'exercise': parsed.exercise,
      'weight_kg': parsed.weight,
      'reps': parsed.reps,
    });

    String react = 'Logged. ${parsed.exercise}, '
        '${parsed.weight % 1 == 0 ? parsed.weight.toInt() : parsed.weight} kg, '
        '${parsed.reps} reps.';
    if (prev != null) {
      final prevW = (prev['weight_kg'] as num?)?.toDouble() ?? 0;
      final prevR = prev['reps'] as int? ?? 0;
      if (parsed.weight > prevW) {
        react += ' That is ${_fmt(parsed.weight - prevW)} kg up from last time. Strong.';
      } else if (parsed.weight == prevW && parsed.reps > prevR) {
        react += ' ${parsed.reps - prevR} more reps than last time.';
      } else if (parsed.weight < prevW) {
        react += ' Lighter than last time — easy day is fine.';
      }
    }
    _tts.speak(react);
    setState(() => _heard = '');
    _load();
  }

  String _fmt(double v) => v % 1 == 0 ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final mm = (_remaining ~/ 60).toString();
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Gym Mode',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Aura.amberSoft, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_workoutName.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Aura.hearth,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_workoutName.toUpperCase(),
                        style: const TextStyle(
                            color: Aura.amberSoft,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_exercises.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _exercises
                    .map((e) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            border: Border.all(color: Aura.outline),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(e,
                              style: const TextStyle(
                                  color: Aura.text, fontSize: 12)),
                        ))
                    .toList(),
              ),
            const Spacer(),
            Center(
              child: GestureDetector(
                onTap: _toggleTimer,
                child: Container(
                  width: 200,
                  height: 200,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: _timer != null ? Aura.amber : Aura.text,
                        width: 2),
                    boxShadow:
                        _timer != null ? Aura.glow(opacity: 0.25) : null,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_timer != null ? '$mm:$ss' : '—:——',
                          style: const TextStyle(
                              fontSize: 52, fontWeight: FontWeight.w700)),
                      Text(_timer != null ? 'RESTING — TAP TO CANCEL' : 'TAP TO REST',
                          style: const TextStyle(
                              color: Aura.textDim,
                              letterSpacing: 3,
                              fontSize: 10)),
                    ],
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (_todaySets.isNotEmpty) ...[
              const Text('TODAY',
                  style: TextStyle(
                      color: Aura.textDim,
                      letterSpacing: 3,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(
                height: 96,
                child: ListView(
                  children: _todaySets
                      .map((s) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '${s['exercise']} — ${_fmt((s['weight_kg'] as num).toDouble())} kg × ${s['reps']}',
                              style: const TextStyle(color: Aura.text),
                            ),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            GestureDetector(
              onTap: _toggleListen,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Aura.amber),
                  color: _listening ? Aura.hearth : null,
                  boxShadow: Aura.glow(opacity: _listening ? 0.35 : 0.15),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_listening ? Icons.mic : Icons.mic_none,
                        color: Aura.amberSoft),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _listening
                            ? (_heard.isEmpty ? 'LISTENING…' : _heard)
                            : 'LOG A SET — "BENCH 60, 8 REPS"',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
