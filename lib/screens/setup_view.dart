import 'package:flutter/material.dart';

import '../public_information.dart';
import '../state/archive_session.dart';

/// Connection form: server address, API key and saved-connection retry.
class SetupView extends StatelessWidget {
  const SetupView({super.key, required this.session});
  final ArchiveSession session;

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'A home for your\nemail history.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'Read archived mail from your own Mail-Archiver server over HTTPS. This app does not provide server hosting or accounts.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: session.server,
          enabled: !busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'HTTPS server address',
            hintText: 'archive.example.ts.net',
            helperText: 'You can omit https://; HTTPS is added automatically.',
            helperMaxLines: 3,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: session.keyInput,
          enabled: !busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'API key',
            helperText: 'Create an API key on your own Mail-Archiver server.',
            helperMaxLines: 3,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : () => session.connect(),
          child: const Text('Connect to archive'),
        ),
        if (session.hasSavedConnection)
          TextButton(
            onPressed: busy ? null : session.restore,
            child: const Text('Retry saved connection'),
          ),
        if (!session.demo) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy ? null : session.startDemo,
            icon: const Icon(Icons.science_outlined),
            label: const Text('Try the demo'),
          ),
          const SizedBox(height: 4),
          Text(
            'Sample mail built into the app. No server needed.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Configure your own server and private-network access. If your server uses Tailscale, connect its app first. Connection details are saved securely on this device.',
        ),
        const PublicInformationLinks(),
        if (session.api != null)
          TextButton(
            onPressed: busy ? null : session.cancelSetup,
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}
