import 'package:flutter/material.dart';
import '../services/monthly_goal_service.dart';
import '../services/period_tracking_service.dart';
import '../services/routine_service.dart';
import '../theme.dart';

class RemindersGoalsScreen extends StatefulWidget {
  const RemindersGoalsScreen({super.key});

  @override
  State<RemindersGoalsScreen> createState() => _RemindersGoalsScreenState();
}

class _RemindersGoalsScreenState extends State<RemindersGoalsScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late TabController _tabController;
  final _goalService = MonthlyGoalService.instance;
  final _periodService = PeriodTrackingService.instance;
  final _routineService = RoutineService.instance;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onServiceChanged);
    _goalService.addListener(_onServiceChanged);
    _periodService.addListener(_onServiceChanged);
    _initServices();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initServices() async {
    await Future.wait([
      _goalService.init(),
      _periodService.init(),
      _routineService.init(),
    ]);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onServiceChanged);
    _goalService.removeListener(_onServiceChanged);
    _periodService.removeListener(_onServiceChanged);
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildCurrentTab() {
    switch (_tabController.index) {
      case 0:
        return _buildMonthlyGoalsTab();
      case 1:
        return _buildDailyTasksTab();
      case 2:
        return _buildPeriodCycleTab();
      default:
        return _buildMonthlyGoalsTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Aura.surface,
      appBar: AppBar(
        backgroundColor: Aura.surface,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tasks & Wellness',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Aura.amberSoft,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
            ),
            Text(
              MonthlyGoalService.currentMonthDisplayName(),
              style: const TextStyle(color: Aura.textDim, fontSize: 12),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Aura.amber,
          labelColor: Aura.amber,
          unselectedLabelColor: Colors.white60,
          onTap: (i) => setState(() {}),
          tabs: const [
            Tab(icon: Icon(Icons.flag_rounded), text: 'Monthly Goals'),
            Tab(icon: Icon(Icons.alarm_on_rounded), text: 'Daily Tasks'),
            Tab(icon: Icon(Icons.favorite_rounded), text: 'Period & Cycle'),
          ],
        ),
      ),
      body: _buildCurrentTab(),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Aura.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_task),
        label: const Text('Add Task / Goal', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () => _showUniversalAddSheet(isDailyDefault: _tabController.index == 1),
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 1: MONTHLY GOALS & ACHIEVEMENT TARGETS
  // -------------------------------------------------------------
  Widget _buildMonthlyGoalsTab() {
    final tasks = _goalService.currentMonthTasks;
    final rate = _goalService.currentMonthAchievementRate;
    final pct = (rate * 100).toInt();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: [
        // Monthly Achievement Summary Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Aura.amber.withValues(alpha: 0.25),
                Aura.surfaceHigh,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Aura.amber.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Monthly Target Progress',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$pct% of Monthly Goals Completed',
                        style: const TextStyle(color: Aura.amberSoft, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 50,
                        height: 50,
                        child: CircularProgressIndicator(
                          value: rate,
                          backgroundColor: Colors.white12,
                          color: Aura.amber,
                          strokeWidth: 5,
                        ),
                      ),
                      Text('$pct%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: rate,
                  minHeight: 8,
                  backgroundColor: Colors.white12,
                  color: Aura.amber,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                pct >= 80
                    ? '🎉 Phenomenal work! You are crushing your monthly goals.'
                    : (pct >= 50
                        ? '🔥 Over halfway there! Keep the daily consistency.'
                        : '💪 Every day counts. Check off your milestones!'),
                style: const TextStyle(color: Aura.textDim, fontSize: 11),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Header & Add Button for Monthly Goals
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Monthly Goals & Targets',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Aura.amber,
                foregroundColor: Colors.black,
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Monthly Goal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              onPressed: () => _showUniversalAddSheet(isDailyDefault: false),
            ),
          ],
        ),
        const SizedBox(height: 10),

        if (tasks.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Aura.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const Icon(Icons.flag_outlined, color: Aura.amber, size: 36),
                const SizedBox(height: 8),
                const Text('No monthly goals added yet', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('Set monthly habits or targets to track your progress!', style: TextStyle(color: Aura.textDim, fontSize: 12)),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => _showUniversalAddSheet(isDailyDefault: false),
                  child: const Text('Add First Monthly Goal'),
                ),
              ],
            ),
          )
        else
          ...tasks.map(_buildGoalItem),
      ],
    );
  }

  Widget _buildGoalItem(MonthlyTask task) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aura.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: task.isCompleted ? Colors.greenAccent.withValues(alpha: 0.4) : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          Checkbox(
            value: task.isCompleted,
            activeColor: Colors.greenAccent,
            checkColor: Colors.black,
            onChanged: (_) async {
              await _goalService.toggleTaskCompleted(task.id);
              setState(() {});
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: TextStyle(
                    color: task.isCompleted ? Colors.white54 : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (task.notes.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(task.notes, style: const TextStyle(color: Aura.textDim, fontSize: 11)),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Aura.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        task.category,
                        style: const TextStyle(color: Aura.amber, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (task.targetCount > 1)
                      Text(
                        'Progress: ${task.currentCount}/${task.targetCount}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Clear DONE button
          if (!task.isCompleted)
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade900.withValues(alpha: 0.4),
                foregroundColor: Colors.greenAccent,
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              ),
              onPressed: () async {
                await _goalService.toggleTaskCompleted(task.id);
                setState(() {});
              },
              child: const Text('DONE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('DONE ✓', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
          if (task.targetCount > 1 && !task.isCompleted)
            IconButton(
              tooltip: '+1 Progress',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              icon: const Icon(Icons.add_circle_outline, color: Aura.amber, size: 22),
              onPressed: () async {
                await _goalService.incrementProgress(task.id);
                setState(() {});
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            onPressed: () async {
              await _goalService.deleteTask(task.id);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 2: DAILY TASKS & ALARMS (Closed-app speech)
  // -------------------------------------------------------------
  Widget _buildDailyTasksTab() {
    final routines = _routineService.routines;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: [
        // Loud Closed-App Alarm Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green.shade900.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
          ),
          child: const Row(
            children: [
              Icon(Icons.alarm_on, color: Colors.greenAccent, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Daily tasks wake your phone & speak aloud even when Aarohi is closed.',
                  style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Prominent Add Daily Task Button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Aura.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.alarm_add, size: 20),
            label: const Text('Add Daily Task / Routine Reminder', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => _showUniversalAddSheet(isDailyDefault: true),
          ),
        ),
        const SizedBox(height: 14),

        ...routines.map((r) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Aura.surfaceHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: r.isEnabled ? Aura.amber.withValues(alpha: 0.35) : Colors.white10,
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
                          Text(r.description, style: const TextStyle(color: Aura.textDim, fontSize: 11)),
                        ],
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: r.hour, minute: r.minute),
                      );
                      if (picked != null) {
                        await _routineService.updateRoutineTime(r.id, picked.hour, picked.minute);
                        setState(() {});
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
                  Switch(
                    value: r.isEnabled,
                    activeThumbColor: Aura.amber,
                    onChanged: (v) async {
                      await _routineService.toggleRoutine(r.id, v);
                      setState(() {});
                    },
                  ),
                  if (r.id > 2006)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      onPressed: () async {
                        await _routineService.deleteRoutine(r.id);
                        setState(() {});
                      },
                    ),
                ],
              ),
            )),
      ],
    );
  }

  // -------------------------------------------------------------
  // TAB 3: 🌸 PERIOD & CYCLE TRACKING (REFLECTS INSTANTLY)
  // -------------------------------------------------------------
  Widget _buildPeriodCycleTab() {
    final enabled = _periodService.isEnabled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: [
        // Main Toggle Banner Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: enabled ? const Color(0xFF2C1322) : Aura.surfaceHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled ? Colors.pinkAccent.withValues(alpha: 0.6) : Colors.white12,
              width: enabled ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.favorite, color: Colors.pinkAccent, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Period & Cycle Tracker',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Dedicated female health tracking',
                          style: TextStyle(color: Aura.textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    activeThumbColor: Colors.pinkAccent,
                    onChanged: (val) async {
                      await _periodService.setEnabled(val);
                    },
                  ),
                ],
              ),

              if (!enabled) ...[
                const SizedBox(height: 14),
                const Text(
                  'Track your menstrual cycle, forecast next period dates, identify energy phases (Menstrual, Follicular, Ovulation, Luteal), and record daily wellness symptoms.',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.pinkAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.favorite_border),
                    label: const Text('ACTIVATE PERIOD TRACKER', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      await _periodService.setEnabled(true);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),

        if (enabled) ...[
          const SizedBox(height: 16),

          // Countdown Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4A1835), Color(0xFF2C1322)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.pinkAccent.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '🌸 Next Period in ~${_periodService.daysUntilNextPeriod} Days',
                        style: const TextStyle(
                          color: Colors.pinkAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.pinkAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Day ${_periodService.currentCycleDay} of ${_periodService.cycleLength}',
                        style: const TextStyle(
                          color: Colors.pinkAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _periodService.currentPhaseName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  _periodService.currentPhaseDescription,
                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Log and Settings Action Row
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.pinkAccent.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.calendar_month, size: 18),
                  label: const Text('Log Period Date', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _pickPeriodDate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.pinkAccent,
                    side: const BorderSide(color: Colors.pinkAccent),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text('${_periodService.cycleLength}d Cycle Settings', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: _showCycleSettingsDialog,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Symptoms Logging
          const Text(
            "Today's Symptoms & Mood",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap symptoms to log how you feel today:',
            style: TextStyle(color: Aura.textDim, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              'Cramps', 'Headache', 'Energetic', 'Calm', 'Fatigue', 'Bloated', 'Glowing Skin', 'Mood Swings', 'Backache'
            ].map((s) {
              final isSelected = _periodService.todaySymptoms.contains(s);
              return FilterChip(
                label: Text(
                  s,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.white : Colors.white70,
                  ),
                ),
                selected: isSelected,
                selectedColor: Colors.pinkAccent.shade700,
                backgroundColor: Aura.surfaceHigh,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                onSelected: (_) async {
                  await _periodService.toggleSymptom(s);
                },
              );
            }).toList(),
          ),

          const SizedBox(height: 24),

          // Subtle Disable Option
          Center(
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Aura.textDim),
              icon: const Icon(Icons.visibility_off, size: 16),
              label: const Text('Hide Period Tracker', style: TextStyle(fontSize: 12)),
              onPressed: () async {
                await _periodService.setEnabled(false);
              },
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickPeriodDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _periodService.lastPeriodDate,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      await _periodService.setLastPeriodDate(picked);
    }
  }

  void _showCycleSettingsDialog() {
    int cycle = _periodService.cycleLength;
    int duration = _periodService.periodDuration;

    showDialog(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setDialogState) => AlertDialog(
          backgroundColor: Aura.surface,
          title: const Text('Cycle Settings', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Cycle Length (Days):', style: TextStyle(color: Colors.white70)),
                  DropdownButton<int>(
                    value: cycle,
                    dropdownColor: Aura.surfaceHigh,
                    items: List.generate(20, (i) => i + 21).map((d) => DropdownMenuItem(value: d, child: Text('$d days', style: const TextStyle(color: Colors.white)))).toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => cycle = v);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Period Flow (Days):', style: TextStyle(color: Colors.white70)),
                  DropdownButton<int>(
                    value: duration,
                    dropdownColor: Aura.surfaceHigh,
                    items: [3, 4, 5, 6, 7, 8].map((d) => DropdownMenuItem(value: d, child: Text('$d days', style: const TextStyle(color: Colors.white)))).toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => duration = v);
                    },
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
              style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent, foregroundColor: Colors.white),
              onPressed: () async {
                await _periodService.setCycleParams(cycleLength: cycle, periodDuration: duration);
                if (dCtx.mounted) Navigator.pop(dCtx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // UNIVERSAL ADD SHEET (DAILY TASK OR MONTHLY GOAL)
  // -------------------------------------------------------------
  void _showUniversalAddSheet({bool isDailyDefault = true}) {
    bool isDaily = isDailyDefault;
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final voiceCtrl = TextEditingController(text: 'Baby, [task]! You said to remind you.');
    TimeOfDay pickedTime = const TimeOfDay(hour: 8, minute: 0);
    int targetCount = 20;
    String category = 'Habits';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (bCtx) => StatefulBuilder(
        builder: (bCtx, setModalState) {
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(bCtx).size.height * 0.88,
            ),
            padding: EdgeInsets.only(
              top: 20,
              left: 20,
              right: 20,
              bottom: MediaQuery.of(bCtx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isDaily ? 'Add Daily Task & Reminder' : 'Add Monthly Goal & Target',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(bCtx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Segmented Switch: Daily Task vs Monthly Goal
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Aura.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => setModalState(() => isDaily = true),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: isDaily ? Aura.amber : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '☀️ Daily Task',
                                style: TextStyle(
                                  color: isDaily ? Colors.black : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => setModalState(() => isDaily = false),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: !isDaily ? Aura.amber : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '🎯 Monthly Goal',
                                style: TextStyle(
                                  color: !isDaily ? Colors.black : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title Field
                  TextField(
                    controller: titleCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: isDaily ? 'Task / Reminder Name' : 'Monthly Goal Title',
                      hintText: isDaily ? 'e.g. Drink 2.5L Water, Take Medicine' : 'e.g. Complete 20 Workouts, Save \$500',
                    ),
                    onChanged: (val) {
                      if (isDaily && val.isNotEmpty) {
                        voiceCtrl.text = 'Baby, $val! You said to remind you.';
                      }
                    },
                  ),
                  const SizedBox(height: 14),

                  // Category Selector
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Category:', style: TextStyle(color: Colors.white70)),
                      DropdownButton<String>(
                        value: category,
                        dropdownColor: Aura.surfaceHigh,
                        items: ['Habits', 'Health', 'Fitness', 'Finance', 'Career', 'Learning', 'Personal']
                            .map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(color: Colors.white))))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setModalState(() => category = v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // DAILY TASK SPECIFIC SETTINGS
                  if (isDaily) ...[
                    // Time Picker Tile
                    ListTile(
                      tileColor: Aura.surfaceHigh,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      title: const Text('Alarm Time', style: TextStyle(color: Colors.white)),
                      subtitle: Text(pickedTime.format(context), style: const TextStyle(color: Aura.amber, fontWeight: FontWeight.bold)),
                      trailing: const Icon(Icons.access_time, color: Aura.amber),
                      onTap: () async {
                        final t = await showTimePicker(context: context, initialTime: pickedTime);
                        if (t != null) setModalState(() => pickedTime = t);
                      },
                    ),
                    const SizedBox(height: 12),
                    // Custom Voice Message
                    TextField(
                      controller: voiceCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Aarohi Voice Reminder (Speaks Aloud)',
                        hintText: 'e.g. Baby, drink water! You said to remind you.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '🔔 Aarohi will wake your phone and speak this aloud even if the app is closed.',
                      style: TextStyle(color: Aura.textDim, fontSize: 11),
                    ),
                  ] else ...[
                    // MONTHLY GOAL SPECIFIC SETTINGS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Target Frequency:', style: TextStyle(color: Colors.white70)),
                        DropdownButton<int>(
                          value: targetCount,
                          dropdownColor: Aura.surfaceHigh,
                          items: [1, 2, 3, 5, 10, 15, 20, 25, 30]
                              .map((n) => DropdownMenuItem(value: n, child: Text('$n times this month', style: const TextStyle(color: Colors.white))))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setModalState(() => targetCount = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Notes / Milestones (Optional)',
                        hintText: 'e.g. Read 15 pages a day',
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Save Button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Aura.amber,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.check_circle),
                      label: Text(
                        isDaily ? 'Save Daily Task & Set Alarm' : 'Save Monthly Goal',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      onPressed: () async {
                        final title = titleCtrl.text.trim();
                        if (title.isEmpty) return;

                        if (isDaily) {
                          await _routineService.addRoutine(
                            title: title,
                            description: descCtrl.text.trim(),
                            hour: pickedTime.hour,
                            minute: pickedTime.minute,
                            isDaily: true,
                            spokenReminder: voiceCtrl.text.trim(),
                          );
                        } else {
                          await _goalService.addTask(
                            title: title,
                            category: category,
                            targetCount: targetCount,
                            notes: descCtrl.text.trim(),
                          );
                        }

                        if (bCtx.mounted) Navigator.pop(bCtx);
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
