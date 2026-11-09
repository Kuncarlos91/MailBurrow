import 'package:flutter/material.dart';

import '../account_selector.dart';
import '../message_date.dart';
import '../state/archive_session.dart';
import 'message_reader.dart';

/// Mail and Search tabs: account, filters, folder, search field, message
/// list and paging.
class MailView extends StatelessWidget {
  const MailView({
    super.key,
    required this.session,
    required this.scrollController,
    required this.searchFocus,
    required this.searchFieldKey,
    required this.onChooseAccount,
    required this.onChooseFilters,
    required this.onChooseFolder,
    required this.onChoosePage,
  });
  final ArchiveSession session;
  final ScrollController scrollController;
  final FocusNode searchFocus;
  final GlobalKey searchFieldKey;
  final VoidCallback onChooseAccount;
  final VoidCallback onChooseFilters;
  final VoidCallback onChooseFolder;
  final VoidCallback onChoosePage;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final busy = s.busy;
    final page = s.page;
    final totalPages = s.totalPages;
    return CustomScrollView(
      controller: scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              ListTile(
                key: const ValueKey('current-mail-account'),
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(accountAddress(s.account ?? {})),
                subtitle: const Text('Currently browsing'),
                trailing: const Icon(Icons.unfold_more),
                onTap: s.canSwitchAccount ? onChooseAccount : null,
              ),
              if (s.accountNotice != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(s.accountNotice!),
                ),
              if (busy) const LinearProgressIndicator(),
              if (s.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    s.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ActionChip(
                    avatar: const Icon(Icons.tune, size: 18),
                    label: Text(
                      s.filters.active ? 'Filters • Active' : 'Filters',
                    ),
                    onPressed: busy ? null : onChooseFilters,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: busy || s.foldersBusy ? null : onChooseFolder,
                        icon: const Icon(Icons.folder_outlined),
                        label: Text(
                          '${s.selectedFolder ?? 'All archived mail'} ▾',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: busy || s.foldersBusy ? null : s.loadFolders,
                      tooltip: 'Reload folders',
                      icon: const Icon(Icons.sync),
                    ),
                  ],
                ),
              ),
              if (s.foldersBusy) const LinearProgressIndicator(),
              if (s.folderError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(child: Text(s.folderError!)),
                      TextButton(
                        onPressed: s.loadFolders,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: s.tab == 1
                    ? _searchField(context)
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          s.selectedFolder ?? 'All archived mail',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
              ),
            ],
          ),
        ),
        if (s.messages.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                busy
                    ? 'Loading messages…'
                    : s.error != null
                    ? 'Messages could not be loaded. Use Refresh to retry.'
                    : 'No messages match this folder and search.',
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _messageTile(context, index),
              childCount: s.messages.length,
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: busy || page <= 1
                      ? null
                      : () => s.load(page - 1, scrollToTop: true),
                  child: const Text('Newer'),
                ),
                Tooltip(
                  message: 'Go to page',
                  child: TextButton.icon(
                    onPressed: busy || totalPages <= 1 ? null : onChoosePage,
                    icon: const Icon(Icons.arrow_drop_down),
                    iconAlignment: IconAlignment.end,
                    label: Text(
                      '$page / $totalPages',
                      textAlign: TextAlign.center,
                      semanticsLabel: 'Page $page of $totalPages',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: busy || page >= totalPages
                      ? null
                      : () => s.load(page + 1, scrollToTop: true),
                  child: const Text('Older'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchField(BuildContext context) {
    final s = session;
    return TextField(
      key: searchFieldKey,
      enabled: !s.accountSwitching,
      controller: s.search,
      focusNode: searchFocus,
      textInputAction: TextInputAction.search,
      onChanged: (_) => s.searchChanged(),
      decoration: InputDecoration(
        hintText: s.selectedFolder == null
            ? 'Search archived mail'
            : 'Search this folder',
        helperText: s.mailLoading
            ? '${s.activeQuery.isEmpty ? 'Loading messages' : 'Searching'}… ${s.searchElapsed.inSeconds} s'
            : s.searchFeedback,
        helperMaxLines: 4,
        prefixIcon: s.mailLoading
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : const Icon(Icons.search),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.search.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear search',
                onPressed: s.clearSearch,
                icon: const Icon(Icons.close),
              ),
            IconButton(
              tooltip: 'Run search',
              onPressed:
                  (s.busy && !s.mailLoading) ||
                      (s.mailLoading &&
                          s.activeQuery == s.search.text.trim() &&
                          s.activeMailPage == 1)
                  ? null
                  : () => s.load(1),
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ),
      onSubmitted: (_) => s.load(1),
    );
  }

  Widget _messageTile(BuildContext context, int index) {
    final mail = session.messages[index] as Map<String, dynamic>;
    final sender = mail['from'] as String? ?? 'Unknown';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: CircleAvatar(
        child: Text(sender.isEmpty ? '?' : sender.substring(0, 1).toUpperCase()),
      ),
      title: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mail['subject'] as String? ?? '(No subject)', maxLines: 2),
          const SizedBox(height: 4),
          MessageDate(value: mail['sentDate']),
        ],
      ),
      trailing: mail['hasAttachments'] == true
          ? const Icon(Icons.attach_file, size: 18)
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MessageReader(api: session.api!, id: mail['id'] as int),
        ),
      ),
    );
  }
}
