import 'package:flutter/material.dart';

import '../archive_picker.dart';
import 'certificate_settings_page.dart';
import '../state/archive_session.dart';
import '../state/connection_store.dart';

enum _ArchiveAction { rename, change, certificate, forget }

/// Settings → Archives: open, rename, change the address and key or token
/// of, or forget each saved archive, and add another. Opening uses the same
/// switch as the Mail page's archive row; "Change address" validates in
/// setup before saving. Nothing else here contacts a server.
class ArchivesPage extends StatelessWidget {
  const ArchivesPage({super.key, required this.session});
  final ArchiveSession session;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Archives')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final busy = session.busy && !session.mailLoading;
          final activeId = session.activeArchive?.id;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // A single-choice list: the selected radio and tinted row mark
              // the open archive; tapping another row opens it through the
              // same switch as the Mail page's archive row.
              RadioGroup<String>(
                groupValue: activeId,
                onChanged: (id) {
                  if (id == null ||
                      id == activeId ||
                      !session.canSwitchArchive) {
                    return;
                  }
                  Navigator.pop(context);
                  session.switchArchive(id);
                },
                child: Column(
                  children: [
                    for (final profile in session.archives)
                      Material(
                        color: profile.id == activeId
                            ? Theme.of(context).colorScheme.secondaryContainer
                                  .withValues(alpha: 0.4)
                            : Colors.transparent,
                        child: Row(
                          children: [
                            // RadioListTile merges semantics. Keep the menu
                            // outside it so it has its own accessible action.
                            Expanded(
                              child: RadioListTile<String>(
                                key: ValueKey('manage-archive-${profile.id}'),
                                value: profile.id,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                selected: profile.id == activeId,
                                enabled:
                                    profile.id == activeId ||
                                    session.canSwitchArchive,
                                title: Text(
                                  profile.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(archiveDetails(profile)),
                              ),
                            ),
                            PopupMenuButton<_ArchiveAction>(
                              tooltip: 'Actions for ${profile.label}',
                              enabled: !busy,
                              onSelected: (action) =>
                                  _act(context, profile, action),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: _ArchiveAction.rename,
                                  child: Text('Rename'),
                                ),
                                PopupMenuItem(
                                  value: _ArchiveAction.change,
                                  child: Text(
                                    'Change address or ${profile.serverType.credential == 'access token' ? 'token' : 'key'}',
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: _ArchiveAction.certificate,
                                  child: Text('Certificate'),
                                ),
                                const PopupMenuItem(
                                  value: _ArchiveAction.forget,
                                  child: Text('Forget on this device'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add archive'),
                enabled: !busy,
                onTap: () {
                  Navigator.pop(context);
                  session.openSetup();
                },
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Tap an archive to switch to it. Use ⋮ to rename, change, set its own certificate or forget it.\n\nArchives are saved only on this device. Forgetting one removes its address and API key or access token here; it does not change mail on the server or revoke the key or token.',
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Future<void> _act(
    BuildContext context,
    ConnectionProfile profile,
    _ArchiveAction action,
  ) async {
    switch (action) {
      case _ArchiveAction.rename:
        final label = await showDialog<String>(
          context: context,
          builder: (_) => _RenameDialog(profile: profile),
        );
        if (label == null || !context.mounted) return;
        if (!await session.renameArchive(profile.id, label) &&
            context.mounted) {
          _show(context, 'Could not rename the archive. Try again.');
        }
      case _ArchiveAction.change:
        Navigator.pop(context);
        session.openReconfigure(profile.id);
      case _ArchiveAction.certificate:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CertificateSettingsPage(session: session, profile: profile),
          ),
        );
      case _ArchiveAction.forget:
        final open = profile.id == session.activeArchive?.id;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Forget ${profile.label}?'),
            content: Text(
              '${open ? 'This archive is open and will be closed. ' : ''}Its address and ${profile.serverType.credential} are removed from this device. Mail on the server is not changed and the ${profile.serverType.credential} is not revoked.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Forget'),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        final removed = await session.forgetArchive(profile.id);
        if (!context.mounted) return;
        if (!removed) {
          _show(context, 'Could not forget the archive. Try again.');
        } else if (open) {
          Navigator.pop(context);
        }
    }
  }

  void _show(BuildContext context, String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.profile});
  final ConnectionProfile profile;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final name = TextEditingController(text: widget.profile.label);

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename archive'),
    content: TextField(
      controller: name,
      autofocus: true,
      maxLength: ConnectionStore.maxLabelLength,
      decoration: InputDecoration(
        labelText: 'Name',
        helperText:
            'Leave empty to use ${ConnectionStore.defaultLabel(widget.profile.server)}.',
        helperMaxLines: 2,
      ),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, name.text),
        child: const Text('Save'),
      ),
    ],
  );
}
