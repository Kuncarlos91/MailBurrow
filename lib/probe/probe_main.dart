/// Entry point for the Open Archiver phone probe. PROBE ONLY.
///
/// Run in profile mode on a USB-connected phone:
/// `flutter run --profile -t lib/probe/probe_main.dart`
/// The profile build installs as `com.kuncarlos91.mailburrow.probe`, next
/// to (never over) MailBurrow. Results hold numbers and case names only.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'probe_runner.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MailBurrow Probe',
    theme: ThemeData(colorSchemeSeed: Colors.brown),
    home: const ProbeScreen(),
  );
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});
  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  String status = 'Ready. Keep the screen on and the phone unplugged from '
      'power-saving modes while it runs.';
  String? output;
  bool running = false;

  Future<void> run() async {
    setState(() {
      running = true;
      output = null;
    });
    final watch = Stopwatch()..start();
    final result = await runProbe(
      onStatus: (value) {
        if (mounted) setState(() => status = value);
      },
    );
    result['totalSeconds'] = watch.elapsed.inSeconds;
    result['mode'] = kProfileMode
        ? 'profile'
        : kReleaseMode
        ? 'release'
        : 'debug (timings not valid)';
    final text = const JsonEncoder.withIndent('  ').convert(result);
    // One line per section so `flutter run` shows it without truncation.
    for (final section in result.entries) {
      debugPrint('OAPROBE ${jsonEncode({section.key: section.value})}');
    }
    if (mounted) {
      setState(() {
        running = false;
        status = 'Done in ${watch.elapsed.inSeconds} s.';
        output = text;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MailBurrow Probe')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Measures synthetic, fictional messages only. No server, key or '
            'real mail is used, and nothing is saved.',
          ),
          const SizedBox(height: 12),
          if (!kProfileMode && !kReleaseMode)
            const Text(
              'Debug build: timings are not valid. Use --profile.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(status),
          if (running) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: running ? null : run,
            child: const Text('Run probe'),
          ),
          if (output != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: output!)),
              child: const Text('Copy results'),
            ),
            const SizedBox(height: 12),
            SelectableText(
              output!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ],
      ),
    ),
  );
}
