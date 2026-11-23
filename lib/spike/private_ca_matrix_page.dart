// SPIKE ONLY (branch spike/private-ca-device, not for merge).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'private_ca_matrix.dart';

/// Settings entry for the spike build.
class PrivateCaMatrixTile extends StatelessWidget {
  const PrivateCaMatrixTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.science_outlined),
    title: const Text('Private CA TLS test (spike build)'),
    subtitle: const Text('Runs fictional certificate checks on this phone'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PrivateCaMatrixPage()),
    ),
  );
}

class PrivateCaMatrixPage extends StatefulWidget {
  const PrivateCaMatrixPage({super.key});

  @override
  State<PrivateCaMatrixPage> createState() => _PrivateCaMatrixPageState();
}

class _PrivateCaMatrixPageState extends State<PrivateCaMatrixPage> {
  final _rows = <MatrixRow>[];
  bool _running = false;
  bool _done = false;

  Future<void> _start() async {
    setState(() {
      _rows.clear();
      _running = true;
      _done = false;
    });
    try {
      await for (final row in runPrivateCaMatrix()) {
        if (!mounted) return;
        setState(() => _rows.add(row));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _rows.add(
            MatrixRow('!', 'matrix stopped', '${e.runtimeType}', null),
          ),
        );
      }
    }
    if (mounted) {
      setState(() {
        _running = false;
        _done = true;
      });
    }
  }

  String get _text => [
    'MailBurrow private CA TLS spike',
    ..._rows.map((r) => r.toString()),
  ].join('\n');

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Private CA TLS test')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Creates made-up certificates on this phone and checks how the TLS layer treats them, using a test server inside the app. '
          'Cases 20 to 22 contact www.example.com to check public certificates. No archive or key is used.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _running ? null : _start,
          child: Text(_running ? 'Running…' : (_done ? 'Run again' : 'Run')),
        ),
        if (_done) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _text));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Results copied')));
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy results'),
          ),
        ],
        const SizedBox(height: 16),
        for (final r in _rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${r.id}  ${r.name}\n    ${r.result}${r.requests == null ? '' : '  (requests: ${r.requests})'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        if (_running)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    ),
  );
}
