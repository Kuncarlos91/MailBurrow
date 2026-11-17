import 'package:flutter/material.dart';

import '../archive_information.dart';
import '../build_information.dart';
import '../public_information.dart';
import '../state/archive_session.dart';
import '../third_party_licenses.dart';
import '../widgets/current_archive_rows.dart';
import 'archives_page.dart';

/// Settings tab: current account, connection settings, archive details,
/// public information and disconnect.
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.session,
    required this.onChooseAccount,
    this.onChooseArchive,
  });
  final ArchiveSession session;
  final VoidCallback onChooseAccount;
  final VoidCallback? onChooseArchive;

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    final api = session.api;
    final account = session.account;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Your archive. Your server.',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        // Same rows as Mail and Search, so the current archive and account
        // look and switch the same way on every tab.
        CurrentArchiveRows(
          session: session,
          onChooseAccount: onChooseAccount,
          onChooseArchive: onChooseArchive,
        ),
        const Divider(),
        if (session.demo)
          ListTile(
            title: const Text('Connection settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : session.openSetup,
          )
        else
          ListTile(
            title: const Text('Archives'),
            subtitle: const Text(
              'Open, rename, change or forget archives saved on this device, or add one',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ArchivesPage(session: session),
                    ),
                  ),
          ),
        if (session.demo)
          const ListTile(
            leading: Icon(Icons.science_outlined),
            title: Text('Demo mode'),
            subtitle: Text(
              'Fictional sample mail built into the app. The demo connects to no server, sends nothing over the network and saves no connection or credentials. Saving an attachment or opening a link you confirm works as it does with a real archive.',
            ),
          )
        else
          ListTile(
            title: const Text('Server and private network'),
            subtitle: Text(
              'You manage your ${session.serverType.label} server, HTTPS address, ${session.serverType.credential}s and Tailscale setup. This app does not host or configure those services.',
            ),
          ),
        const ListTile(
          title: Text('Appearance'),
          subtitle: Text('Follows system light / dark theme'),
        ),
        if (api != null && account != null)
          ArchiveInformation(
            key: ObjectKey(account),
            api: api,
            account: account,
            onAccountSelected: session.canSwitchAccount
                ? session.switchAccount
                : null,
            onRefreshed: session.retryFailedMailAfterRecovery,
            credential: session.serverType.credential,
          ),
        const PublicInformationLinks(),
        const ThirdPartyLicensesTile(),
        const ListTile(
          title: Text('MailBurrow'),
          subtitle: Text(buildInformation),
        ),
        if (session.demo)
          TextButton(
            onPressed: session.accountSwitching ? null : session.exitDemo,
            child: const Text('Exit demo'),
          )
        else
          TextButton(
            onPressed: busy ? null : session.forgetConnection,
            child: const Text('Disconnect and forget connection'),
          ),
      ],
    );
  }
}
