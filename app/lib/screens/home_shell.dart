import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'chat_screen.dart';
import 'dialer_app_screen.dart';
import 'reminders_goals_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.deviceRole});
  final String deviceRole;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final List<Widget?> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      ChatScreen(deviceRole: widget.deviceRole),
      null,
      null,
      null,
    ];
  }

  void _onTabSelected(int newIndex) {
    if (_screens[newIndex] == null) {
      switch (newIndex) {
        case 1:
          _screens[1] = const DialerAppScreen();
          break;
        case 2:
          _screens[2] = const RemindersGoalsScreen();
          break;
        case 3:
          _screens[3] = const SettingsScreen();
          break;
      }
    }
    setState(() => _index = newIndex);
  }

  Future<bool> _showExitConfirmationDialog() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aura.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Aura.amber, width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Aura.amber),
            SizedBox(width: 10),
            Text('Exit Aarohi?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Are you sure you want to exit? Your daily routines, closed-app voice alarms, and background features will continue to protect you.',
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('STAY', style: TextStyle(color: Aura.textDim, fontWeight: FontWeight.bold)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('EXIT APP', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        // If user is on another tab (Calls, Reminders, Settings), back returns to Chat first!
        if (_index != 0) {
          setState(() => _index = 0);
          return;
        }

        // On web, there's no "exit app" — just ignore back
        if (kIsWeb) return;

        // When at the root Chat tab, ask permission before exiting!
        final shouldExit = await _showExitConfirmationDialog();
        if (shouldExit) {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: IndexedStack(
          index: _index,
          children: _screens.map((s) => s ?? const SizedBox.shrink()).toList(),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onTabSelected,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline),
                    selectedIcon: Icon(Icons.chat_bubble),
                    label: 'Chat',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.phone_in_talk_outlined),
                    selectedIcon: Icon(Icons.phone_in_talk),
                    label: 'Calls',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.task_alt_outlined),
                    selectedIcon: Icon(Icons.task_alt),
                    label: 'Reminders',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: 'Aarohi',
                  ),
                ],
              ),
      ),
    );
  }
}
