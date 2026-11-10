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
        // Wrap moves Exit onto its own line when large text leaves no room
        // beside the label, instead of squeezing the label.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.science_outlined, color: colors.onTertiaryContainer),
                const SizedBox(width: 12),
                Flexible(
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
              ],
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
