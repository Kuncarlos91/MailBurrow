import 'package:flutter/material.dart';

import 'state/connection_store.dart';

/// The picker's result for "Add archive". Profile IDs are never empty.
const addArchiveChoice = '';

/// The server type and host of a saved archive, so archives with similar
/// labels can be told apart.
String archiveDetails(ConnectionProfile profile) {
  final host = Uri.tryParse(profile.server)?.host ?? '';
  return '${profile.serverType.label} · ${host.isEmpty ? profile.server : host}';
}

/// Lists the saved archives. Returns the chosen profile ID,
/// [addArchiveChoice], or null when dismissed.
Future<String?> showArchivePicker(
  BuildContext context, {
  required List<ConnectionProfile> archives,
  required String? activeId,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Archives',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final profile in archives)
            SavedArchiveTile(
              profile: profile,
              selected: profile.id == activeId,
              onTap: () => Navigator.pop(context, profile.id),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add archive'),
            onTap: () => Navigator.pop(context, addArchiveChoice),
          ),
        ],
      ),
    ),
  ),
);

/// One saved archive: its label, server type and host.
class SavedArchiveTile extends StatelessWidget {
  const SavedArchiveTile({
    super.key,
    required this.profile,
    required this.onTap,
    this.selected = false,
  });
  final ConnectionProfile profile;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('saved-archive-${profile.id}'),
    leading: const Icon(Icons.dns_outlined),
    title: Text(profile.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(archiveDetails(profile)),
    trailing: selected
        ? const Icon(Icons.check, semanticLabel: 'Open now')
        : null,
    selected: selected,
    onTap: onTap,
  );
}
