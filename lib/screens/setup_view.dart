import 'package:flutter/material.dart';

import '../archive_picker.dart';
import '../archive_server_type.dart';
import '../public_information.dart';
import '../state/archive_session.dart';

/// Connection form: server address, API key and saved-connection retry.
class SetupView extends StatelessWidget {
  const SetupView({super.key, required this.session});
  final ArchiveSession session;

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    final type = session.setupServerType;
    final openArchiver = type == ArchiveServerType.openArchiver;
    // Saved archives are listed when setup is the landing screen. With one
    // saved archive, "Retry saved connection" already covers it.
    final landing = session.api == null;
    final showArchives =
        landing &&
        session.archives.isNotEmpty &&
        (session.archives.length > 1 || !session.hasSavedConnection);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'A home for your\nemail history.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        if (landing && session.savedArchivesUnreadable) ...[
          const SizedBox(height: 12),
          Text(
            'Saved archives on this device cannot be read by this version of MailBurrow. Update the app, or remove them all and add your archives again.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _confirmReset(context),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Remove all saved archives…'),
          ),
        ],
        if (showArchives) ...[
          const SizedBox(height: 12),
          Text(
            'Saved archives',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final profile in session.archives)
            SavedArchiveTile(
              profile: profile,
              onTap: busy || !session.canSwitchArchive
                  ? null
                  : () => session.switchArchive(profile.id),
            ),
          const SizedBox(height: 8),
          Text(
            'Or add an archive',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
        const SizedBox(height: 12),
        // The choice replaces the introduction line, which moves to the
        // notes below, so the form keeps its height on small screens.
        Semantics(
          container: true,
          label: 'Server type',
          child: SegmentedButton<ArchiveServerType>(
            segments: [
              for (final value in ArchiveServerType.values)
                ButtonSegment(value: value, label: Text(value.label)),
            ],
            selected: {type},
            showSelectedIcon: false,
            onSelectionChanged: busy
                ? null
                : (selection) => session.chooseServerType(selection.single),
          ),
        ),
        if (openArchiver) ...[
          const SizedBox(height: 8),
          Text(
            'Tested with Open Archiver 0.6.2. Messages from sources that keep full original files cannot be opened in this app.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
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
          decoration: InputDecoration(
            labelText: 'API key',
            helperText: openArchiver
                ? 'Create an API key in your Open Archiver for a user whose role can only read the sources you want here.'
                : 'Create an API key on your own Mail-Archiver server.',
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : () => session.connect(),
          child: const Text('Connect to archive'),
        ),
        if (session.hasSavedConnection)
          TextButton(
            onPressed: busy ? null : session.retrySaved,
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
          'Read archived mail from your own Mail-Archiver or Open Archiver server over HTTPS. MailBurrow never guesses the server type. It does not provide server hosting or accounts.',
        ),
        const SizedBox(height: 8),
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

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove all saved archives?'),
        content: const Text(
          'This removes every saved archive and API key from this device. Mail on your servers is not changed. You will need to enter your API keys again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.resetSavedArchives();
  }
}
