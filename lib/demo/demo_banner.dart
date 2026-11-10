import 'package:flutter/material.dart';

/// Label shown on every screen while the built-in demo is open, so a
/// screenshot or screen recording cannot be mistaken for a real archive.
///
/// Like other persistent bars, its text scaling is capped at 2x so that at
/// the largest accessibility sizes it stays one compact row instead of
/// taking over the screen; the label may wrap to a second line.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.onExit});

  /// Leaves the demo; null disables the button while work is in progress.
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 2,
      child: Material(
        color: colors.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              Icon(Icons.science_outlined, color: colors.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Demo · sample mail',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Exit'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
