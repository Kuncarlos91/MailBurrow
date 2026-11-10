import 'package:flutter/material.dart';

/// Label shown on every screen while the built-in demo is open, so a
/// screenshot or screen recording cannot be mistaken for a real archive.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.onExit});

  /// Leaves the demo; null disables the button while work is in progress.
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.science_outlined, color: colors.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Demo · sample mail',
                  style: TextStyle(
                    color: colors.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: onExit,
              style: TextButton.styleFrom(
                foregroundColor: colors.onTertiaryContainer,
              ),
              child: const Text('Exit'),
            ),
          ],
        ),
      ),
    );
  }
}
