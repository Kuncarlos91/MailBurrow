import 'package:flutter/material.dart';

/// Pinned, announced progress while an account switch commits and loads.
class AccountSwitchProgress extends StatelessWidget {
  const AccountSwitchProgress({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(),
          SizedBox(height: 6),
          Text('Switching account…'),
        ],
      ),
    ),
  );
}
