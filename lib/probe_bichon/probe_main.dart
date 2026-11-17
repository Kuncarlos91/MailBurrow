/// Entry point for the Bichon phone probe. PROBE ONLY.
///
/// Run in profile mode on a USB-connected phone:
/// `flutter run --profile -t lib/probe_bichon/probe_main.dart`
/// The profile build installs as `com.kuncarlos91.mailburrow.probe`, next to
/// (never over) MailBurrow. The access token is typed on the phone, kept in
/// memory only and cleared when the screen closes. Results hold numbers and
/// fixed case names only.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archive_api.dart';
import 'runner.dart';

void main() => runApp(const BichonProbeApp());

class BichonProbeApp extends StatelessWidget {
  const BichonProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MailBurrow Probe',
    theme: ThemeData(colorSchemeSeed: Colors.brown),
    home: const BichonProbeScreen(),
  );
}

class BichonProbeScreen extends StatefulWidget {
  const BichonProbeScreen({super.key});
  @override
  State<BichonProbeScreen> createState() => _BichonProbeScreenState();
}

class _BichonProbeScreenState extends State<BichonProbeScreen> {
  final server = TextEditingController();
  final token = TextEditingController();
  String status =
      'Enter the lab address and the reader access token. Keep the screen '
      'on and the phone out of power-saving mode while it runs.';
  String? output;
  bool running = false;

  @override
  void dispose() {
    token.clear();
    token.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> run({bool diagnosis = false}) async {
    final Uri address;
    try {
      address = validateServer(server.text);
    } on FormatException catch (error) {
      setState(() => status = error.message);
      return;
    }
    if (token.text.trim().isEmpty) {
      setState(() => status = 'Enter the access token.');
      return;
    }
    setState(() {
      running = true;
      output = null;
    });
    final watch = Stopwatch()..start();
    final probe = diagnosis ? runRetentionDiagnosis : runBichonProbe;
    final result = await probe(
      server: address,
      token: token.text.trim(),
      onStatus: (value) {
        if (mounted) setState(() => status = value);
      },
    );
    token.clear();
    result['totalSeconds'] = watch.elapsed.inSeconds;
    result['mode'] = kProfileMode
        ? 'profile'
        : kReleaseMode
        ? 'release'
        : 'debug (timings not valid)';
    final text = const JsonEncoder.withIndent('  ').convert(result);
    // One line per section so `flutter run` shows it without truncation.
    for (final section in result.entries) {
      debugPrint('BICHON-PROBE ${jsonEncode({section.key: section.value})}');
    }
    if (!mounted) return;
    setState(() {
      running = false;
      output = text;
      status = result.containsKey('error')
          ? 'Stopped: ${result['error']}'
          : 'Done. Copy the results and paste them in the chat.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MailBurrow Bichon probe')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: server,
            enabled: !running,
            decoration: const InputDecoration(labelText: 'Lab HTTPS address'),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          TextField(
            controller: token,
            enabled: !running,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Reader access token'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: running ? null : run,
            child: const Text('Run probe'),
          ),
          const SizedBox(height: 8),
          // Diagnosis only: start it from a fresh app launch, not after a run.
          OutlinedButton(
            onPressed: running ? null : () => run(diagnosis: true),
            child: const Text('Run retention diagnosis (fresh start)'),
          ),
          const SizedBox(height: 16),
          Text(status),
          if (output != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: output!)),
              child: const Text('Copy results'),
            ),
            const SizedBox(height: 8),
            SelectableText(output!, style: const TextStyle(fontSize: 12)),
          ],
        ],
      ),
    ),
  );
}
