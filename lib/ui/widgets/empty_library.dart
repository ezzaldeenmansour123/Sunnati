import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Shared honest empty state: shown whenever the library (or a section of
/// it) has no data yet. Never a fake list, never a disabled-looking button.
/// [detail] explains what is missing and which phase will provide it.
class EmptyLibraryCard extends StatelessWidget {
  const EmptyLibraryCard({
    super.key,
    required this.title,
    required this.detail,
    this.icon = Icons.menu_book_outlined,
  });

  final String title;
  final String detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: SunnatiColors.gold),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colors.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              style: const TextStyle(color: SunnatiColors.inkMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
