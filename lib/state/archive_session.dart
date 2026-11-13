import 'dart:async';

import 'package:flutter/widgets.dart';

import '../archive_api.dart' show ArchiveApi, validateServer;
import '../archive_models.dart';
import '../archive_errors.dart';
import '../archive_backend.dart';
import '../demo/demo_archive.dart';
import '../archive_capabilities.dart';
import '../search_filters.dart';
import '../archive_server_type.dart';
import 'connection_store.dart';

/// Creates the backend for a validated server address and key.
typedef ArchiveApiFactory = ArchiveBackend Function(Uri server, String key);

/// Opens the built-in demo archive.
typedef DemoArchiveLoader = Future<ArchiveBackend> Function();

/// Connection, account and mailbox state behind the archive home screen.
///
/// Fields are read by the screens and changed only by this class. Work that
/// needs a [BuildContext] (snackbars, focus and scrolling) is requested
/// through the `on…` hooks, which the screen sets.
///
/// Request counters ([mailRequestId], [folderRequestId] and
/// [accountSwitchGeneration]) discard results that finish after a newer
/// request, a folder change, an account switch or a disconnect.
class ArchiveSession extends ChangeNotifier {
  ArchiveSession({
    ArchiveApiFactory? apiFactory,
    DemoArchiveLoader? demoLoader,
    ConnectionStore store = const ConnectionStore(),
  }) : _apiFactory = apiFactory ?? ArchiveApi.new,
       _demoLoader = demoLoader ?? DemoArchive.load,
       _store = store;

  final ArchiveApiFactory _apiFactory;
  final DemoArchiveLoader _demoLoader;
  final ConnectionStore _store;
  final server = TextEditingController();
  final keyInput = TextEditingController();
  final search = TextEditingController();

  /// Clears visible notices before a new request.
  VoidCallback? onClearNotices;

  /// Reports a failed mail request with a guarded retry.
  void Function(String message, VoidCallback retry)? onMailRequestFailed;

  /// Asks for the mail list to scroll to the top after the next frame.
  void Function(bool Function() stillCurrent)? onScrollToTop;

  /// Reports that an account selection could not be saved.
  void Function(String message)? onAccountSaveFailed;

  /// Called once a new account is committed, before its mail loads.
  void Function(bool Function() stillCurrent)? onAccountChanged;

  ArchiveBackend? api;

  /// The server type of the current or restored connection. Mail-Archiver is
  /// the only type so far; it is saved with the connection and never detected.
  ArchiveServerType serverType = ArchiveServerType.mailArchiver;
  ArchiveAccount? account;
  List<ArchiveFolder> folders = [];
  String? selectedFolder;
  SearchFilters filters = const SearchFilters();
  String? folderError;
  bool foldersBusy = false;
  List<MailSummary> messages = [];
  int tab = 0, page = 1, totalPages = 1;
  bool busy = true, setup = true;
  bool hasSavedConnection = false;

  /// True while the built-in demo archive is open. The demo is never saved:
  /// entering, browsing and exiting it never read, write or delete the saved
  /// connection, so a real connection saved earlier is kept.
  bool demo = false;
  bool reloadPending = false;
  bool mailLoading = false;
  int mailRequestId = 0;
  int folderRequestId = 0;
  Timer? searchTimer;
  Duration searchElapsed = Duration.zero;
  String activeQuery = '';
  int activeMailPage = 1;
  String? searchFeedback;
  bool restoring = true;
  String? error;
  bool mailRequestFailed = false;
  bool accountSwitching = false;
  String? accountNotice;
  bool accountLoading = false;
  int accountSwitchGeneration = 0;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    mailRequestId++;
    searchTimer?.cancel();
    api?.close();
    server.dispose();
    keyInput.dispose();
    search.dispose();
    super.dispose();
  }

  /// Makes in-flight mail and folder requests stale and stops their progress.
  void _invalidateRequests() {
    mailRequestId++;
    folderRequestId++;
    searchTimer?.cancel();
    searchTimer = null;
    mailLoading = false;
    foldersBusy = false;
  }

  /// Returns folder, filter, search and paging state to a fresh Mail tab.
  void _clearBrowsing() {
    folders = [];
    folderError = null;
    selectedFolder = null;
    filters = const SearchFilters();
    search.clear();
    searchFeedback = null;
    page = 1;
    totalPages = 1;
    tab = 0;
  }

  bool get canSwitchAccount => !accountSwitching && (!busy || mailLoading);

  Future<void> restore() async {
    restoring = true;
    busy = true;
    error = null;
    _notify();
    try {
      final saved = await _store.read();
      if (_disposed) return;
      if (saved != null) {
        hasSavedConnection = true;
        serverType = saved.serverType;
        server.text = saved.server;
        await connect(saved.key, saved.accountId);
        return;
      }
    } catch (_) {
      if (!_disposed) {
        error = 'Saved connection unavailable. Enter your settings again.';
        _notify();
      }
    } finally {
      if (!_disposed) {
        restoring = false;
        busy = mailLoading;
        _notify();
      }
    }
  }

  /// Connects with the key entered in setup, or with [savedKey] when restoring.
  /// [preferredAccountId] is the saved account as text; it is matched against
  /// each account's ID in its text form.
  Future<void> connect([String? savedKey, String? preferredAccountId]) async {
    mailRequestFailed = false;
    accountSwitchGeneration++;
    accountLoading = false;
    busy = true;
    error = null;
    _notify();
    // A candidate client is owned here until it becomes [api]; every other
    // outcome closes it so failed attempts leave no pooled connections.
    ArchiveBackend? candidate;
    var adopted = false;
    try {
      Uri uri;
      try {
        uri = validateServer(server.text);
      } on FormatException {
        if (!_disposed) {
          error =
              'Enter a valid HTTPS server address without credentials, a query, or a fragment.';
          _notify();
        }
        return;
      }
      final key = savedKey ?? keyInput.text.trim();
      if (key.isEmpty) {
        error = 'Enter your API key.';
        _notify();
        return;
      }
      server.text = uri.toString();
      final created = candidate = _apiFactory(uri, key);
      final accounts = await created.accounts();
      if (accounts.isEmpty) throw const ArchiveFailure(404);
      final preferred = accounts
          .where((item) => item.id == preferredAccountId)
          .firstOrNull;
      final selected = preferred ?? accounts.first;
      final accountUnavailable =
          preferredAccountId != null && preferred == null;
      final result = await created.emails(selected.id, '', 1);
      final items = result.items;
      final pages = result.totalPages.clamp(1, 1000000);
      try {
        await _store.write(
          serverType: serverType,
          server: uri.toString(),
          key: key,
          accountId: selected.id,
        );
      } catch (_) {
        if (!_disposed) {
          error =
              'Connected to the server, but could not save the connection securely. Retry or check device storage.';
          _notify();
        }
        return;
      }
      if (_disposed) return;
      if (!identical(api, created)) api?.close();
      _invalidateRequests();
      _clearBrowsing();
      api = created;
      adopted = true;
      demo = false;
      account = selected;
      accountNotice = accountUnavailable
          ? 'Previously selected account is no longer available. Showing an accessible account.'
          : null;
      messages = items;
      totalPages = pages;
      setup = false;
      hasSavedConnection = true;
      keyInput.clear();
      _notify();
      await loadFolders();
    } catch (failure) {
      if (!_disposed) {
        error = readableError(failure);
        _notify();
      }
    } finally {
      if (!adopted) candidate?.close();
      if (!_disposed) {
        if (!mailLoading) {
          busy = false;
          _notify();
        }
        if (reloadPending) {
          reloadPending = false;
          await load(1);
        }
      }
    }
  }

  Future<void> switchAccount(ArchiveAccount choice) async {
    final requestApi = api;
    final choiceId = choice.id;
    if (requestApi == null ||
        setup ||
        !canSwitchAccount ||
        choiceId == account?.id) {
      return;
    }
    // Invalidate old requests before awaiting storage; they must not reset busy
    // or populate mail/folders while the choice is being committed.
    final generation = ++accountSwitchGeneration;
    _invalidateRequests();
    requestApi.cancelEmailRequests();
    onClearNotices?.call();
    accountSwitching = true;
    accountLoading = true;
    busy = true;
    reloadPending = false;
    mailRequestFailed = false;
    _notify();
    try {
      // The demo is never saved, so its account choice is not stored either.
      if (!demo) {
        await _store.write(
          serverType: serverType,
          server: requestApi.server.toString(),
          key: requestApi.key,
          accountId: choiceId,
        );
      }
    } catch (_) {
      if (!_disposed && identical(api, requestApi)) {
        busy = false;
        accountSwitching = false;
        accountLoading = false;
        error =
            'Could not save the account selection securely. Your current account is unchanged.';
        _notify();
        onAccountSaveFailed?.call(error!);
      }
      return;
    }
    if (_disposed || !identical(api, requestApi)) return;
    onAccountChanged?.call(
      () => !_disposed && account?.id == choiceId,
    );
    _clearBrowsing();
    account = choice;
    accountNotice = null;
    messages = [];
    activeQuery = '';
    activeMailPage = 1;
    searchElapsed = Duration.zero;
    error = null;
    busy = false;
    accountSwitching = false;
    _notify();
    await Future.wait([load(1), loadFolders()]);
    if (!_disposed &&
        generation == accountSwitchGeneration &&
        identical(api, requestApi)) {
      accountLoading = false;
      _notify();
    }
  }

  Future<void> load(int requestedPage, {bool scrollToTop = false}) async {
    if (api == null) return;
    if (busy && !mailLoading) {
      reloadPending = true;
      return;
    }
    final requestApi = api!;
    final query = search.text.trim();
    if (mailLoading &&
        activeQuery == query &&
        activeMailPage == requestedPage) {
      return;
    }
    final requestId = ++mailRequestId;
    bool current() => !_disposed && requestId == mailRequestId;
    onClearNotices?.call();
    searchTimer?.cancel();
    requestApi.cancelEmailRequests();
    final watch = Stopwatch()..start();
    busy = true;
    mailLoading = true;
    mailRequestFailed = false;
    activeQuery = query;
    activeMailPage = requestedPage;
    searchElapsed = Duration.zero;
    searchFeedback = null;
    error = null;
    _notify();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (current()) {
        searchElapsed = watch.elapsed;
        _notify();
      }
    });
    searchTimer = timer;
    try {
      final result = await requestApi.emails(
        account!.id,
        query,
        requestedPage,
        folder: requestApi.capabilities.folders ? selectedFolder : null,
        filters: requestApi.capabilities.supported(filters),
      );
      if (current()) {
        messages = result.items;
        page = result.page;
        totalPages = result.totalPages.clamp(1, 1000000);
        searchElapsed = watch.elapsed;
        final total = result.totalItems;
        final count = total == null
            ? '${messages.length} messages on this page'
            : (result.totalIsEstimate ?? capabilities.estimatedTotals)
            ? 'about $total matches'
            : '$total matches';
        searchFeedback =
            '${query.isEmpty ? 'Messages loaded' : 'Search complete'} · $count · ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
        _notify();
        if (scrollToTop) onScrollToTop?.call(current);
      }
    } catch (failure) {
      if (current()) {
        error = readableError(failure);
        mailRequestFailed = true;
        searchFeedback =
            'Request failed after ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s. Try again.';
        _notify();
        if (!setup && tab != 2) {
          onMailRequestFailed?.call(error!, () {
            if (current() && !setup) unawaited(load(requestedPage));
          });
        }
      }
    } finally {
      timer.cancel();
      watch.stop();
      if (current()) {
        busy = false;
        mailLoading = false;
        searchTimer = null;
        _notify();
      }
    }
  }

  // A recovered section is not proof the failed mail request now works.
  // Revalidate that request instead of merely dismissing its error.
  void retryFailedMailAfterRecovery() {
    if (!_disposed && !setup && !busy && mailRequestFailed && api != null) {
      unawaited(load(page));
    }
  }

  /// What the connected backend supports; [ArchiveCapabilities.full] while
  /// disconnected, so setup and empty states keep their current controls.
  ArchiveCapabilities get capabilities =>
      api?.capabilities ?? ArchiveCapabilities.full;

  Future<void> loadFolders() async {
    final requestApi = api;
    final accountId = account?.id;
    if (requestApi == null || accountId == null || foldersBusy) return;
    if (!requestApi.capabilities.folders) {
      // Nothing to browse: never ask a server for folders it does not have.
      folders = [];
      folderError = null;
      selectedFolder = null;
      return;
    }
    final requestId = ++folderRequestId;
    bool current() =>
        !_disposed &&
        requestId == folderRequestId &&
        identical(api, requestApi);
    foldersBusy = true;
    folderError = null;
    _notify();
    try {
      final result = await requestApi.folders(accountId);
      if (current()) {
        folders = result;
        _notify();
        retryFailedMailAfterRecovery();
      }
    } catch (_) {
      if (current()) {
        folderError = 'Could not load folders. Tap Retry.';
        _notify();
      }
    } finally {
      if (current()) {
        foldersBusy = false;
        _notify();
      }
    }
  }

  Future<void> selectFolder(ArchiveFolder choice) async {
    if (busy || !capabilities.folders) return;
    selectedFolder = choice.path.isEmpty ? null : choice.path;
    page = 1;
    totalPages = 1;
    messages = [];
    _notify();
    await load(1);
  }

  Future<void> applyFilters(SearchFilters updated) async {
    if (busy) return;
    filters = capabilities.supported(updated);
    page = 1;
    totalPages = 1;
    messages = [];
    _notify();
    await load(1);
  }

  void clearSearch() {
    search.clear();
    messages = [];
    page = 1;
    totalPages = 1;
    _notify();
    unawaited(load(1));
  }

  /// Rebuilds listeners after the search text changes.
  void searchChanged() => _notify();

  void setTab(int value) {
    tab = value;
    _notify();
  }

  void openSetup() {
    setup = true;
    error = null;
    _notify();
  }

  void cancelSetup() {
    setup = false;
    error = null;
    _notify();
  }

  Future<void> forgetConnection() async {
    if (demo) {
      exitDemo();
      return;
    }
    try {
      await _store.delete();
      if (_disposed) return;
      serverType = ArchiveServerType.mailArchiver;
      api?.close();
      _invalidateRequests();
      _clearBrowsing();
      activeQuery = '';
      reloadPending = false;
      api = null;
      account = null;
      accountNotice = null;
      accountLoading = false;
      accountSwitchGeneration++;
      messages = [];
      server.clear();
      keyInput.clear();
      setup = true;
      hasSavedConnection = false;
      error = null;
      _notify();
    } catch (_) {
      if (!_disposed) {
        error = 'Could not remove the saved connection.';
        _notify();
      }
    }
  }

  /// Opens the built-in demo archive of fictional mail.
  ///
  /// Unlike [connect], nothing is validated, sent over the network or saved:
  /// the saved connection and the setup fields are left as they are.
  Future<void> startDemo() async {
    if (demo && !setup) return;
    mailRequestFailed = false;
    accountSwitchGeneration++;
    accountLoading = false;
    busy = true;
    error = null;
    _notify();
    ArchiveBackend? candidate;
    var adopted = false;
    try {
      final created = candidate = await _demoLoader();
      final accounts = await created.accounts();
      if (accounts.isEmpty) throw const ArchiveFailure(404);
      final selected = accounts.first;
      final result = await created.emails(selected.id, '', 1);
      if (_disposed) return;
      if (!identical(api, created)) api?.close();
      _invalidateRequests();
      _clearBrowsing();
      activeQuery = '';
      api = created;
      adopted = true;
      demo = true;
      account = selected;
      accountNotice = null;
      messages = result.items;
      totalPages = result.totalPages.clamp(1, 1000000);
      setup = false;
      _notify();
      await loadFolders();
    } catch (_) {
      if (!_disposed) {
        error = 'Could not open the demo. Try again.';
        _notify();
      }
    } finally {
      if (!adopted) candidate?.close();
      if (!_disposed && !mailLoading) {
        busy = false;
        _notify();
      }
    }
  }

  /// Leaves the demo and returns to setup.
  ///
  /// Stops demo requests and attachment copies in progress; their late
  /// results are ignored. The saved connection is not touched, so
  /// "Retry saved connection" still works afterwards.
  void exitDemo() {
    if (!demo) return;
    api?.close();
    _invalidateRequests();
    _clearBrowsing();
    activeQuery = '';
    activeMailPage = 1;
    searchElapsed = Duration.zero;
    reloadPending = false;
    api = null;
    demo = false;
    account = null;
    accountNotice = null;
    accountLoading = false;
    accountSwitching = false;
    accountSwitchGeneration++;
    mailRequestFailed = false;
    messages = [];
    setup = true;
    busy = false;
    error = null;
    _notify();
  }
}
