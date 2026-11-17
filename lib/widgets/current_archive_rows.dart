import 'package:flutter/material.dart';

import '../account_selector.dart';
import '../archive_picker.dart';
import '../state/archive_session.dart';

/// The current archive and email account, shown the same way at the top of
/// Mail, Search and Settings. Tapping a row opens its picker.
class CurrentArchiveRows extends StatelessWidget {
  const CurrentArchiveRows({
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
    final s = session;
    final archive = s.activeArchive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (archive != null)
          ListTile(
            key: const ValueKey('current-archive'),
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.dns_outlined),
            title: Text(
              archive.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(archiveDetails(archive)),
            trailing: const Icon(Icons.unfold_more),
            onTap: s.canSwitchArchive ? onChooseArchive : null,
          ),
        ListTile(
          key: const ValueKey('current-mail-account'),
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(accountAddress(s.account)),
          subtitle: const Text('Currently browsing'),
          trailing: const Icon(Icons.unfold_more),
          onTap: s.canSwitchAccount ? onChooseAccount : null,
        ),
      ],
    );
  }
}
