import 'package:flutter/material.dart';

import '../account_selector.dart';
import '../archive_models.dart';
import '../archive_backend.dart';
import '../demo/demo_banner.dart';
import '../pagination.dart';
import '../search_filters.dart';
import '../state/archive_session.dart';
import '../widgets/account_switch_progress.dart';
import 'mail_view.dart';
import 'settings_view.dart';
import 'setup_view.dart';

/// Main screen: setup until connected, then Mail, Search and Settings tabs.
///
/// State and requests live in [ArchiveSession]. This widget owns only UI
/// concerns: dialogs and sheets, snackbars, focus and scrolling.
class ArchiveHome extends StatefulWidget {
  const ArchiveHome({super.key, this.apiFactory, this.demoLoader});
  final ArchiveBackend Function(Uri, String)? apiFactory;
  final Future<ArchiveBackend> Function()? demoLoader;
  @override
  State<ArchiveHome> createState() => _ArchiveHomeState();
}

class _ArchiveHomeState extends State<ArchiveHome> {
  late final session = ArchiveSession(
    apiFactory: widget.apiFactory,
    demoLoader: widget.demoLoader,
  );
  final mailScroll = ScrollController();
  final searchFocus = FocusNode();
  final searchFieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    session
      ..onClearNotices = _clearNotices
      ..onMailRequestFailed = _showMailFailure
      ..onScrollToTop = _scrollToTopWhen
      ..onAccountSaveFailed = _showMessage
      ..onAccountChanged = _accountChanged;
    session.restore();
  }

  @override
  void dispose() {
    session.dispose();
    mailScroll.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _clearNotices() {
    if (mounted) ScaffoldMessenger.of(context).removeCurrentSnackBar();
  }

  void _showMailFailure(String message, VoidCallback retry) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: 'Retry', onPressed: retry),
        ),
      );
  }

  void _scrollToTopWhen(bool Function() stillCurrent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && stillCurrent() && mailScroll.hasClients) {
        mailScroll.jumpTo(0);
      }
    });
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _accountChanged(bool Function() stillCurrent) {
    searchFocus.unfocus();
    _scrollToTopWhen(stillCurrent);
  }

  Future<void> chooseAccount() async {
    final requestApi = session.api;
    final id = archiveIdOrNull(session.account?['id']);
    if (requestApi == null || id == null || !session.canSwitchAccount) return;
    final choice = await showAccountSelector(
      context,
      api: requestApi,
      currentAccountId: id,
    );
    if (!mounted ||
        session.setup ||
        !identical(session.api, requestApi) ||
        choice == null) {
      return;
    }
    await session.switchAccount(choice);
  }

  Future<void> chooseFolder() async {
    final choice = await showModalBottomSheet<ArchiveFolder>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: ListView(
            children: [
              ListTile(
                title: const Text(
                  'Folders',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.all_inbox_outlined),
                title: const Text('All archived mail'),
                selected: session.selectedFolder == null,
                onTap: () => Navigator.pop(
                  context,
                  const ArchiveFolder('All archived mail', '', 0, 0),
                ),
              ),
              if (session.folders.isEmpty)
                const ListTile(title: Text('No archived folders available.')),
              for (final folder in session.folders)
                ListTile(
                  contentPadding: EdgeInsets.only(
                    left: 16 + folder.depth.clamp(0, 8) * 16.0,
                    right: 20,
                  ),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folder.name),
                  subtitle: folder.depth > 0 ? Text(folder.path) : null,
                  trailing: Text('${folder.count}'),
                  selected: session.selectedFolder == folder.path,
                  onTap: () => Navigator.pop(context, folder),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await session.selectFolder(choice);
  }

  Future<void> choosePage() async {
    if (session.busy || session.totalPages <= 1) return;
    final selected = await showArchivePagePicker(
      context,
      currentPage: session.page,
      totalPages: session.totalPages,
    );
    if (!mounted ||
        session.busy ||
        selected == null ||
        selected < 1 ||
        selected > session.totalPages) {
      return;
    }
    if (selected == session.page) {
      if (mailScroll.hasClients) mailScroll.jumpTo(0);
      return;
    }
    await session.load(selected, scrollToTop: true);
  }

  Future<void> chooseFilters() async {
    final updated = await showModalBottomSheet<SearchFilters>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SearchFiltersSheet(filters: session.filters),
    );
    if (updated == null || !mounted) return;
    await session.applyFilters(updated);
  }

  void selectTab(int value) {
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    session.setTab(value);
    if (value == 0 && session.search.text.isNotEmpty) session.clearSearch();
    if (value != 1) {
      searchFocus.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || session.tab != 1 || session.setup) return;
      if (mailScroll.hasClients) mailScroll.jumpTo(0);
      final fieldContext = searchFieldKey.currentContext;
      if (fieldContext != null) {
        Scrollable.ensureVisible(fieldContext);
        searchFocus.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: session, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final s = session;
    if (s.restoring && s.setup) {
      return Scaffold(
        appBar: AppBar(title: const Text('MailBurrow')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Semantics(
                    liveRegion: true,
                    child: Text('Connecting to your archive…'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final mailView = MailView(
      session: s,
      scrollController: mailScroll,
      searchFocus: searchFocus,
      searchFieldKey: searchFieldKey,
      onChooseAccount: chooseAccount,
      onChooseFilters: chooseFilters,
      onChooseFolder: chooseFolder,
      onChoosePage: choosePage,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('MailBurrow'),
        actions: [
          if (!s.setup)
            IconButton(
              tooltip: 'Switch account',
              onPressed: s.canSwitchAccount ? chooseAccount : null,
              icon: const Icon(Icons.switch_account_outlined),
            ),
          if (!s.setup && s.tab != 2)
            IconButton(
              onPressed: s.busy ? null : () => s.load(s.page),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Shown on every screen while the demo is open, including setup
            // opened from Settings, so a demo screen is never unlabelled.
            if (s.demo)
              DemoBanner(onExit: s.accountSwitching ? null : s.exitDemo),
            Expanded(child: _content(context, s, mailView)),
          ],
        ),
      ),
      bottomNavigationBar: s.setup
          ? null
          : NavigationBar(
              selectedIndex: s.tab,
              onDestinationSelected: s.accountSwitching ? null : selectTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.inbox_outlined),
                  label: 'Mail',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }

  Widget _content(BuildContext context, ArchiveSession s, Widget mailView) =>
      !s.setup && s.tab != 2
            ? Column(
                children: [
                  if (s.accountLoading) const AccountSwitchProgress(),
                  Expanded(child: mailView),
                ],
              )
            : Column(
                children: [
                  if (s.accountLoading)
                    const AccountSwitchProgress()
                  else if (s.busy)
                    const LinearProgressIndicator(),
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
                  Expanded(
                    child: s.setup
                        ? SetupView(session: s)
                        : s.tab == 2
                        ? SettingsView(
                            session: s,
                            onChooseAccount: chooseAccount,
                          )
                        : mailView,
                  ),
                ],
              );
}
