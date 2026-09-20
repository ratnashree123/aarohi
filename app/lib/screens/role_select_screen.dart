import 'package:flutter/material.dart';

import '../theme.dart';

/// First-launch device role: this phone is her "life body" or "work body".
class RoleSelectScreen extends StatelessWidget {
  const RoleSelectScreen({super.key, required this.onSelected});
  final void Function(String role) onSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'What is this device?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'One brain, two bodies.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Aura.textDim),
            ),
            const SizedBox(height: 40),
            _RoleCard(
              icon: Icons.favorite_outline,
              title: 'Companion',
              subtitle: 'Main phone — alarm, gym, water, life',
              onTap: () => onSelected('companion'),
            ),
            const SizedBox(height: 16),
            _RoleCard(
              icon: Icons.desktop_windows_outlined,
              title: 'Work Station',
              subtitle: 'Desk phone — watches the laptop screen',
              onTap: () => onSelected('work_station'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Aura.surfaceLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Aura.outline),
        ),
        child: Row(
          children: [
            Icon(icon, color: Aura.amberSoft, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Aura.textDim)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
