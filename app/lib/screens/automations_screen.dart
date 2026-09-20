import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../services/automation_service.dart';
import '../theme.dart';

class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key});

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  final _service = AutomationService.instance;
  List<Contact> _contacts = [];

  @override
  void initState() {
    super.initState();
    _service.init().then((_) {
      if (mounted) setState(() {});
    });
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    if (kIsWeb) return; // Contacts not available on web
    try {
      if (await FlutterContacts.requestPermission()) {
        final c = await FlutterContacts.getContacts(withProperties: true);
        if (mounted) setState(() => _contacts = c);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final rules = _service.rules;

    return Scaffold(
      backgroundColor: Aura.surface,
      appBar: AppBar(
        backgroundColor: Aura.surface,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manual Automations', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            Text('Triggers & Actions customized for you', style: TextStyle(color: Aura.textDim, fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add Automation',
            icon: const Icon(Icons.add_circle, color: Aura.amber, size: 28),
            onPressed: () => _openAutomationEditor(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner explaining closed-app execution
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.amber.shade900.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aura.amber.withValues(alpha: 0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.bolt, color: Aura.amber, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Time-based automations use Android AlarmManager to run even if Aarohi is closed.',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: rules.isEmpty
                ? const Center(
                    child: Text('No automations configured.\nTap + to add one!',
                        textAlign: TextAlign.center, style: TextStyle(color: Aura.textDim)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    itemCount: rules.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      return _buildAutomationCard(r);
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Aura.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('New Automation', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () => _openAutomationEditor(),
      ),
    );
  }

  Widget _buildAutomationCard(AutomationRule r) {
    IconData actionIcon;
    Color iconColor;
    switch (r.actionType) {
      case AutomationActionType.sendSms:
        actionIcon = Icons.sms;
        iconColor = Colors.lightBlueAccent;
        break;
      case AutomationActionType.makeCall:
        actionIcon = Icons.phone_forwarded;
        iconColor = Colors.greenAccent;
        break;
      case AutomationActionType.speakTts:
        actionIcon = Icons.record_voice_over;
        iconColor = Aura.amber;
        break;
      case AutomationActionType.showNotification:
        actionIcon = Icons.notifications_active;
        iconColor = Colors.purpleAccent;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Aura.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: r.isEnabled ? Aura.amber.withValues(alpha: 0.35) : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(actionIcon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      style: TextStyle(
                        color: r.isEnabled ? Colors.white : Colors.white54,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'TRIGGER: ${r.triggerSummary}',
                      style: const TextStyle(color: Aura.amberSoft, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              Switch(
                value: r.isEnabled,
                activeThumbColor: Aura.amber,
                onChanged: (val) async {
                  await _service.toggleRule(r.id, val);
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Aura.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'ACTION: ${r.actionSummary}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                r.runCount > 0 ? 'Ran ${r.runCount} times' : 'Never triggered yet',
                style: const TextStyle(color: Aura.textDim, fontSize: 11),
              ),
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Aura.amber,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('TEST RUN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    onPressed: () async {
                      final res = await _service.executeRule(r);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('⚡ Automation: $res'),
                            backgroundColor: Aura.amber,
                            duration: const Duration(seconds: 3),
                          ),
                        );
                        setState(() {});
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
                    onPressed: () => _openAutomationEditor(rule: r),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                    onPressed: () async {
                      await _service.deleteRule(r.id);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openAutomationEditor({AutomationRule? rule}) {
    final isEditing = rule != null;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final msgCtrl = TextEditingController(text: rule?.actionMessage ?? '');
    final contactCtrl = TextEditingController(text: rule?.targetContact ?? '');
    final keywordCtrl = TextEditingController(text: rule?.keyword ?? '');

    AutomationTriggerType selectedTrigger = rule?.triggerType ?? AutomationTriggerType.timeOfDay;
    AutomationActionType selectedAction = rule?.actionType ?? AutomationActionType.speakTts;
    TimeOfDay selectedTime = TimeOfDay(hour: rule?.hour ?? 8, minute: rule?.minute ?? 0);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aura.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setEditorState) {
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.9,
            ),
            padding: EdgeInsets.only(
              top: 20,
              left: 20,
              right: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune, color: Aura.amber, size: 24),
                      const SizedBox(width: 8),
                      Text(
                        isEditing ? 'Edit Automation' : 'New Manual Automation',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 20),

                  // 1. Automation Name
                  const Text('1. Automation Name', style: TextStyle(color: Aura.amberSoft, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'e.g. Missed Call Auto-SMS, Morning Brief',
                      hintStyle: TextStyle(color: Aura.textDim),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 2. Select Trigger
                  const Text('2. When Should It Run? (Trigger)',
                      style: TextStyle(color: Aura.amberSoft, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('⏰ Time of Day'),
                        selected: selectedTrigger == AutomationTriggerType.timeOfDay,
                        selectedColor: Aura.amber,
                        onSelected: (s) => setEditorState(() => selectedTrigger = AutomationTriggerType.timeOfDay),
                      ),
                      ChoiceChip(
                        label: const Text('📞 Missed Call'),
                        selected: selectedTrigger == AutomationTriggerType.missedCall,
                        selectedColor: Aura.amber,
                        onSelected: (s) => setEditorState(() => selectedTrigger = AutomationTriggerType.missedCall),
                      ),
                      ChoiceChip(
                        label: const Text('💬 SMS Keyword'),
                        selected: selectedTrigger == AutomationTriggerType.smsKeyword,
                        selectedColor: Aura.amber,
                        onSelected: (s) => setEditorState(() => selectedTrigger = AutomationTriggerType.smsKeyword),
                      ),
                      ChoiceChip(
                        label: const Text('⚡ 1-Tap Run'),
                        selected: selectedTrigger == AutomationTriggerType.oneTapShortcut,
                        selectedColor: Aura.amber,
                        onSelected: (s) => setEditorState(() => selectedTrigger = AutomationTriggerType.oneTapShortcut),
                      ),
                    ],
                  ),

                  // Trigger configuration params
                  const SizedBox(height: 10),
                  if (selectedTrigger == AutomationTriggerType.timeOfDay) ...[
                    ListTile(
                      tileColor: Aura.surfaceHigh,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      title: const Text('Scheduled Time', style: TextStyle(color: Colors.white)),
                      subtitle: Text(selectedTime.format(context), style: const TextStyle(color: Aura.amber)),
                      trailing: const Icon(Icons.access_time, color: Aura.amber),
                      onTap: () async {
                        final t = await showTimePicker(context: context, initialTime: selectedTime);
                        if (t != null) setEditorState(() => selectedTime = t);
                      },
                    ),
                  ] else if (selectedTrigger == AutomationTriggerType.smsKeyword) ...[
                    TextField(
                      controller: keywordCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Trigger Keyword in SMS',
                        hintText: 'e.g. urgent, call, emergency',
                      ),
                    ),
                  ],

                  const SizedBox(height: 18),

                  // 3. Select Action
                  const Text('3. What Action Should Aarohi Take?',
                      style: TextStyle(color: Aura.amberSoft, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('📩 Send SMS'),
                        selected: selectedAction == AutomationActionType.sendSms,
                        selectedColor: Colors.lightBlueAccent,
                        onSelected: (s) => setEditorState(() => selectedAction = AutomationActionType.sendSms),
                      ),
                      ChoiceChip(
                        label: const Text('📞 Make Call'),
                        selected: selectedAction == AutomationActionType.makeCall,
                        selectedColor: Colors.greenAccent,
                        onSelected: (s) => setEditorState(() => selectedAction = AutomationActionType.makeCall),
                      ),
                      ChoiceChip(
                        label: const Text('🗣️ Speak Aloud'),
                        selected: selectedAction == AutomationActionType.speakTts,
                        selectedColor: Aura.amber,
                        onSelected: (s) => setEditorState(() => selectedAction = AutomationActionType.speakTts),
                      ),
                      ChoiceChip(
                        label: const Text('🔔 Alarm/Notification'),
                        selected: selectedAction == AutomationActionType.showNotification,
                        selectedColor: Colors.purpleAccent,
                        onSelected: (s) =>
                            setEditorState(() => selectedAction = AutomationActionType.showNotification),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Contact Picker (for SMS or Call actions)
                  if (selectedAction == AutomationActionType.sendSms ||
                      selectedAction == AutomationActionType.makeCall) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: contactCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Target Contact or Phone Number',
                              hintText: 'e.g. Rohit or +919876543210',
                            ),
                          ),
                        ),
                        if (_contacts.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.contacts, color: Aura.amber),
                            onPressed: () => _pickContactForEditor(contactCtrl, setEditorState),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Action Message / Speech Text
                  if (selectedAction != AutomationActionType.makeCall) ...[
                    TextField(
                      controller: msgCtrl,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: selectedAction == AutomationActionType.speakTts
                            ? 'What should Aarohi say?'
                            : (selectedAction == AutomationActionType.sendSms
                                ? 'SMS Message Body'
                                : 'Notification Text'),
                        hintText: 'Type your message...',
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
                        isEditing ? 'Save Changes' : 'Create Automation',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      onPressed: () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;

                        final ruleToSave = AutomationRule(
                          id: rule?.id ?? 'auto_${DateTime.now().millisecondsSinceEpoch}',
                          name: name,
                          triggerType: selectedTrigger,
                          actionType: selectedAction,
                          isEnabled: true,
                          hour: selectedTime.hour,
                          minute: selectedTime.minute,
                          keyword: keywordCtrl.text.trim(),
                          targetContact: contactCtrl.text.trim(),
                          actionMessage: msgCtrl.text.trim(),
                        );

                        if (isEditing) {
                          await _service.updateRule(ruleToSave);
                        } else {
                          await _service.addRule(ruleToSave);
                        }

                        if (ctx.mounted) Navigator.pop(ctx);
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

  void _pickContactForEditor(TextEditingController ctrl, StateSetter setEditorState) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Aura.surface,
      builder: (cCtx) => ListView.builder(
        itemCount: _contacts.length,
        itemBuilder: (ctx, i) {
          final c = _contacts[i];
          final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
          return ListTile(
            title: Text(c.displayName, style: const TextStyle(color: Colors.white)),
            subtitle: Text(phone, style: const TextStyle(color: Aura.textDim)),
            onTap: () {
              setEditorState(() {
                ctrl.text = c.displayName;
              });
              Navigator.pop(cCtx);
            },
          );
        },
      ),
    );
  }
}
