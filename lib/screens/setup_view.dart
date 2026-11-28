import 'package:flutter/material.dart';

import '../archive_api.dart' show validateServer;
import '../archive_picker.dart';
import '../archive_server_type.dart';
import '../build_information.dart';
import '../certificate_import.dart';
import '../certificate_picker.dart';
import '../public_information.dart';
import '../state/archive_session.dart';
import 'certificate_import_page.dart';

/// Connection form: server address, API key or access token, and saved-connection retry.
class SetupView extends StatelessWidget {
  const SetupView({
    super.key,
    required this.session,
    this.certificatePicker = pickCertificateFile,
  });
  final ArchiveSession session;
  final CertificateFilePicker certificatePicker;

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    // Use the same source as the selector so adding a backend cannot leave
    // this introduction advertising an incomplete list.
    final labels = ArchiveServerType.values.map((type) => type.label).toList();
    final serverNames = labels.length == 1
        ? labels.single
        : '${labels.take(labels.length - 1).join(', ')} or ${labels.last}';
    final type = session.setupServerType;
    final openArchiver = type == ArchiveServerType.openArchiver;
    final bichon = type == ArchiveServerType.bichon;
    final changing = session.reconfiguring;
    // Saved archives are listed when setup is the landing screen. With one
    // saved archive, "Retry saved connection" already covers it.
    final landing = session.api == null;
    final showArchives =
        landing &&
        session.archives.isNotEmpty &&
        (session.archives.length > 1 || !session.hasSavedConnection);
    // Built in full rather than lazily: the form is short, and every field
    // and button exists for accessibility services and tests wherever the
    // user has scrolled.
    return SingleChildScrollView(
      // Opening the change form starts at its heading.
      key: ValueKey(changing?.id),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (changing == null)
            Text(
              'A home for your\nemail history.',
              style: Theme.of(context).textTheme.headlineLarge,
            )
          else ...[
            Text(
              'Change ${changing.label}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the ${type.credential} again; the saved one is never sent to a changed address. To use another server type, add it as a new archive.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
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
              onSelectionChanged: busy || changing != null
                  ? null
                  : (selection) => session.chooseServerType(selection.single),
            ),
          ),
          if (bichon) ...[
            const SizedBox(height: 8),
            Text(
              'Tested with Bichon 2.4.2 Community. Use a Bichon user that can only view the accounts you want here. Never enter your mailbox password.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
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
              helperText:
                  'You can omit https://; HTTPS is added automatically.',
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
              labelText: type.credentialLabel,
              helperText: switch (type) {
                ArchiveServerType.openArchiver =>
                  'Create an API key in your Open Archiver for a user whose role can only read the sources you want here.',
                ArchiveServerType.bichon =>
                  'In Bichon, give a Member user Viewer access to only the accounts you want, then create an access token for that user.',
                ArchiveServerType.mailArchiver =>
                  'Create an API key on your own Mail-Archiver server.',
              },
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          if (session.pendingCertificate case final der?) ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Your own certificate will be trusted'),
              subtitle: Text(_certificateName(der)),
              trailing: TextButton(
                onPressed: busy ? null : session.clearPendingCertificate,
                child: const Text('Remove'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text('Advanced', style: Theme.of(context).textTheme.titleSmall),
          ListTile(
            key: const ValueKey('setup-own-certificate'),
            contentPadding: EdgeInsets.zero,
            enabled: !busy,
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Use your own certificate'),
            subtitle: const Text(
              "Optional. For a home certificate authority or a self-signed server. Most setups don't need this.",
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _useOwnCertificate(context),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : () => session.connect(),
            child: Text(
              changing == null ? 'Connect to archive' : 'Save and connect',
            ),
          ),
          if (session.certificateNotVerified &&
              session.error != null &&
              session.api == null) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const ValueKey('certificate-help'),
              onPressed: busy ? null : () => _useOwnCertificate(context),
              child: const Text('Use your own certificate'),
            ),
            const SizedBox(height: 4),
            Text(
              'Tailscale Serve or a reverse proxy with a public certificate, such as Let\'s Encrypt, works without this step.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (session.reconnectArchive case final refused?
              when changing == null)
            FilledButton.tonal(
              onPressed: busy
                  ? null
                  : () => session.openReconfigure(refused.id),
              child: Text(
                refused.serverType == ArchiveServerType.bichon
                    ? 'Enter a new access token for ${refused.label}'
                    : 'Enter a new key for ${refused.label}',
              ),
            ),
          if (session.hasSavedConnection && changing == null)
            TextButton(
              onPressed: busy ? null : session.retrySaved,
              child: const Text('Retry saved connection'),
            ),
          if (!session.demo && changing == null) ...[
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
          Text(
            'Read archived mail from your own $serverNames server over HTTPS. MailBurrow never guesses the server type. It does not provide server hosting or accounts.',
            key: const ValueKey('setup-introduction'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Configure your own server and private-network access. If your server uses Tailscale, connect its app first. Connection details are saved securely on this device.',
          ),
          const PublicInformationLinks(),
          const ListTile(
            title: Text('MailBurrow'),
            subtitle: Text(buildInformation),
          ),
          if (session.api != null || changing != null)
            TextButton(
              onPressed: busy ? null : session.cancelSetup,
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }

  String _certificateName(List<int> der) =>
      switch (readCertificateFile(der, checkValidity: false)) {
        CertificateAccepted(:final details) => details.subject,
        CertificateRejected() => 'Checked certificate',
      };

  /// Runs the two-step certificate flow for the address entered now; a
  /// trusted certificate is kept for this destination and Connect runs.
  Future<void> _useOwnCertificate(BuildContext context) async {
    if (!certificateActionsAllowed(context) || session.busy || session.demo) {
      return;
    }
    final generation = session.certificateFlowGeneration;
    final type = session.setupServerType;
    final messenger = ScaffoldMessenger.of(context);
    final Uri uri;
    try {
      uri = validateServer(session.server.text);
    } on FormatException {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter the HTTPS server address first.')),
      );
      return;
    }
    final der = await showCertificateImport(
      context,
      destination: uri.toString(),
      trustLabel: 'Trust and connect',
      picker: certificatePicker,
    );
    if (der == null ||
        !context.mounted ||
        !certificateActionsAllowed(context)) {
      return;
    }
    if (generation != session.certificateFlowGeneration ||
        type != session.setupServerType ||
        !session.setup ||
        session.demo) {
      return;
    }
    try {
      if (validateServer(session.server.text) != uri) return;
    } on FormatException {
      return;
    }
    if (!session.setPendingCertificate(der)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "The certificate wasn't kept. Check the address and try again.",
          ),
        ),
      );
      return;
    }
    await session.connect();
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove all saved archives?'),
        content: const Text(
          'This removes every saved archive with its API key or access token from this device. Mail on your servers is not changed. You will need to enter them again.',
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
