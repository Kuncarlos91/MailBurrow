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
import '../open_archiver_api.dart';
import 'connection_store.dart';

/// Creates the backend for a validated server address and key, for every
/// server type. Tests use it to supply one fake backend.
typedef ArchiveApiFactory = ArchiveBackend Function(Uri server, String key);

/// Creates the backend of [type] for a validated server address and key.
typedef ArchiveBackendFactory =
    ArchiveBackend Function(ArchiveServerType type, Uri server, String key);

/// The real backend for each server type. There is no fallback: a type is
/// only ever connected with its own client.
ArchiveBackend createArchiveBackend(
  ArchiveServerType type,
  Uri server,
  String key,
) => switch (type) {
  ArchiveServerType.mailArchiver => ArchiveApi(server, key),
  ArchiveServerType.openArchiver => OpenArchiverApi(server, key),
};

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
    ArchiveBackendFactory? backendFactory,
    DemoArchiveLoader? demoLoader,
    ConnectionStore store = const ConnectionStore(),
  }) : _backendFactory =
           backendFactory ??
           (apiFactory == null
               ? createArchiveBackend
               : (_, server, key) => apiFactory(server, key)),
       _demoLoader = demoLoader ?? DemoArchive.load,
       _store = store;

  final ArchiveBackendFactory _backendFactory;
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

  /// The server type of the current or restored connection. It is saved with
  /// the connection and never detected.
  ArchiveServerType serverType = ArchiveServerType.mailArchiver;

  /// The type chosen in the setup form. It applies only when connecting from
  /// setup and becomes [serverType] once that connection succeeds, so a
  /// choice that is cancelled never changes the active connection.
  ArchiveServerType setupServerType = ArchiveServerType.mailArchiver;

  void chooseServerType(ArchiveServerType value) {
    if (busy || reconfiguring != null || value == setupServerType) return;
    setupServerType = value;
    keyInput.clear();
    error = null;
    _notify();
  }
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

  /// The readable saved archives, without keys, in saved order.
  List<ConnectionProfile> archives = const [];

  /// The saved profile of the open connection, or null for none or the demo.
  String? activeArchiveId;

  /// True when saved archives exist but this build cannot read them. Only
  /// then does setup offer the all-archives reset.
  bool savedArchivesUnreadable = false;

  /// The archive being opened from the picker or setup, for its progress
  /// screen; null otherwise.
  ConnectionProfile? switchingArchive;

  // The archive "Retry saved connection" opens after a failed switch; null
  // means the active saved connection.
  String? _retryArchiveId;

  /// The saved archive whose address or key setup is changing, or null when
  /// setup adds an archive. Its server type cannot change: a different type
  /// is a new archive.
  ConnectionProfile? reconfiguring;

  /// The saved archive whose key the server refused when it was last
  /// opened, offered "Enter a new key" in setup; null otherwise.
  String? reconnectArchiveId;

  // The failure of the last connection attempt, and the saved active
  // profile ID from the store (also while nothing is open).
  Object? _lastConnectFailure;
  String? _savedActiveId;

  /// The archive [reconnectArchiveId] names, if it is still saved.
  ConnectionProfile? get reconnectArchive => api != null
      ? null
      : archives.where((item) => item.id == reconnectArchiveId).firstOrNull;

  bool get _keyRefused {
    final failure = _lastConnectFailure;
    return failure is ArchiveFailure &&
        (failure.status == 401 || failure.status == 403);
  }

  /// The open archive's saved profile, if any.
  ConnectionProfile? get activeArchive => demo || api == null
      ? null
      : archives.where((item) => item.id == activeArchiveId).firstOrNull;

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

  /// True when another saved archive can be opened now.
  bool get canSwitchArchive =>
      !demo &&
      switchingArchive == null &&
      !accountSwitching &&
      (!busy || mailLoading);

  /// Reloads [archives] from the store. Failures keep the current list.
  Future<void> _refreshArchives() async {
    try {
      final saved = await _store.overview();
      if (_disposed) return;
      archives = saved.profiles;
      savedArchivesUnreadable = saved.unreadable;
      _savedActiveId = saved.active;
      if (api != null && !demo) activeArchiveId = saved.active;
    } catch (_) {
      // Storage is unavailable; the picker keeps what it last showed.
    }
    _notify();
  }

  Future<void> restore() async {
    reconfiguring = null;
    reconnectArchiveId = null;
    _lastConnectFailure = null;
    keyInput.clear();
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
        setupServerType = saved.serverType;
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
        await _refreshArchives();
        if (api == null && _keyRefused) reconnectArchiveId = _savedActiveId;
        if (savedArchivesUnreadable && api == null) {
          error =
              'Saved archives on this device cannot be read by this version of MailBurrow.';
        }
        restoring = false;
        busy = mailLoading;
        _notify();
      }
    }
  }

  /// Retries the saved connection that failed last: the archive a failed
  /// switch tried to open, otherwise the active saved connection.
  Future<void> retrySaved() async {
    final id = _retryArchiveId;
    if (id != null && archives.any((item) => item.id == id)) {
      await switchArchive(id);
    } else {
      _retryArchiveId = null;
      await restore();
    }
  }

  /// Opens the saved archive [id] with its saved key and account.
  ///
  /// The open archive's content is cleared and its requests cancelled before
  /// the destination is contacted, so its mail is never shown under the new
  /// label. The destination becomes active only once it answers; if it fails,
  /// setup shows a destination-specific error with Retry and the saved
  /// archives, and the previous archive stays saved and active for restart.
  Future<void> switchArchive(String id) async {
    if (!canSwitchArchive) return;
    final profile = archives.where((item) => item.id == id).firstOrNull;
    if (profile == null) return;
    if (!setup && api != null && id == activeArchiveId) return;
    reconfiguring = null;
    api?.close();
    _invalidateRequests();
    _clearBrowsing();
    activeQuery = '';
    activeMailPage = 1;
    searchElapsed = Duration.zero;
    reloadPending = false;
    api = null;
    activeArchiveId = null;
    account = null;
    accountNotice = null;
    accountLoading = false;
    accountSwitchGeneration++;
    mailRequestFailed = false;
    messages = [];
    keyInput.clear();
    switchingArchive = profile;
    _retryArchiveId = id;
    reconnectArchiveId = null;
    _lastConnectFailure = null;
    busy = true;
    error = null;
    _notify();
    String? failure;
    try {
      final saved = await _store.connection(id);
      if (_disposed) return;
      serverType = saved.serverType;
      setupServerType = saved.serverType;
      server.text = saved.server;
      await _connect(saved.key, saved.accountId, id);
      failure = api == null ? error : null;
    } on FormatException {
      failure = 'Its saved details cannot be read. Add it again.';
    } catch (_) {
      failure = 'Could not read its saved details from this device.';
    } finally {
      if (!_disposed) {
        switchingArchive = null;
        if (api == null) {
          setup = true;
          hasSavedConnection = true;
          if (_keyRefused) reconnectArchiveId = id;
          server.clear();
          error =
              'Could not open ${profile.label} (${profile.serverType.label}). ${failure ?? ''}'
                  .trim();
        }
        busy = mailLoading;
        _notify();
      }
    }
  }

  /// The explicit all-archives reset, offered only when the saved archives
  /// cannot be read: removes every saved archive and key from this device.
  /// No server is contacted and no server mail is changed.
  Future<void> resetSavedArchives() async {
    if (!savedArchivesUnreadable || busy || api != null) return;
    busy = true;
    error = null;
    _notify();
    try {
      await _store.reset();
      if (_disposed) return;
      hasSavedConnection = false;
      _retryArchiveId = null;
      activeArchiveId = null;
    } catch (_) {
      if (!_disposed) error = 'Could not remove the saved archives. Try again.';
    } finally {
      if (!_disposed) {
        await _refreshArchives();
        busy = false;
        _notify();
      }
    }
  }

  /// Connects with the key and server type entered in setup, or with
  /// [savedKey] and the saved [serverType] when restoring.
  /// [preferredAccountId] is the saved account as text; it is matched against
  /// each account's ID in its text form.
  ///
  /// While [reconfiguring], the entered address and key replace that saved
  /// archive's once they are validated; the saved key is never sent.
  Future<void> connect([String? savedKey, String? preferredAccountId]) {
    final target = savedKey == null ? reconfiguring : null;
    return target == null
        ? _connect(savedKey, preferredAccountId, null)
        : _connect(null, target.accountId, target.id);
  }

  /// [profileId] names the saved archive being opened by [switchArchive].
  Future<void> _connect(
    String? savedKey,
    String? preferredAccountId,
    String? profileId,
  ) async {
    _lastConnectFailure = null;
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
      final type = savedKey == null ? setupServerType : serverType;
      if (savedKey == null &&
          profileId != null &&
          archives.any(
            (item) =>
                item.id != profileId &&
                item.serverType == type &&
                item.server == uri.toString(),
          )) {
        error =
            'Another saved archive already uses this server type and address.';
        _notify();
        return;
      }
      final created = candidate = _backendFactory(type, uri, key);
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
      String savedId;
      try {
        savedId = savedKey == null && profileId == null
            ? await _store.add(
                serverType: type,
                server: uri.toString(),
                key: key,
                accountId: selected.id,
              )
            : await _store.write(
                serverType: type,
                server: uri.toString(),
                key: key,
                accountId: selected.id,
                profileId: profileId,
              );
      } on TooManySavedArchives {
        if (!_disposed) {
          error =
              'Connected to the server, but this device already has the most saved archives MailBurrow allows (${ConnectionStore.maxProfiles}). Forget one first.';
          _notify();
        }
        return;
      } on SavedArchiveMissing {
        if (!_disposed) {
          error =
              'Connected to the server, but this archive is no longer saved on this device.';
          _notify();
        }
        return;
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
      serverType = type;
      setupServerType = type;
      demo = false;
      account = selected;
      accountNotice = accountUnavailable
          ? 'Previously selected account is no longer available. Showing an accessible account.'
          : null;
      messages = items;
      totalPages = pages;
      setup = false;
      hasSavedConnection = true;
      activeArchiveId = savedId;
      _retryArchiveId = null;
      reconfiguring = null;
      reconnectArchiveId = null;
      keyInput.clear();
      _notify();
      await _refreshArchives();
      await loadFolders();
    } catch (failure) {
      _lastConnectFailure = failure;
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
    if (reconfiguring != null) server.text = api?.server.toString() ?? '';
    reconfiguring = null;
    keyInput.clear();
    setup = true;
    error = null;
    _notify();
  }

  /// Opens setup to change the saved archive [id]'s address or key. The
  /// address starts as saved, the key must be entered again, and the server
  /// type is fixed.
  void openReconfigure(String id) {
    if (busy || demo) return;
    final profile = archives.where((item) => item.id == id).firstOrNull;
    if (profile == null) return;
    reconfiguring = profile;
    setupServerType = profile.serverType;
    server.text = profile.server;
    keyInput.clear();
    setup = true;
    error = null;
    _notify();
  }

  /// Renames the saved archive [id]. Returns false if it could not be saved.
  Future<bool> renameArchive(String id, String label) async {
    try {
      await _store.rename(id, label);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed) await _refreshArchives();
    }
  }

  /// Forgets the saved archive [id] from this device. Forgetting the open
  /// archive closes it and returns to setup without opening another.
  /// Returns false if it could not be removed.
  Future<bool> forgetArchive(String id) async {
    if (busy && !mailLoading) return false;
    if (!demo && api != null && id == activeArchiveId) {
      await forgetConnection();
      return api == null;
    }
    try {
      await _store.forget(id);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed) await _refreshArchives();
    }
  }

  void cancelSetup() {
    if (api == null) {
      // Leaving a key change started from setup itself: stay on setup.
      if (reconfiguring == null) return;
      reconfiguring = null;
      server.clear();
      keyInput.clear();
      error = null;
      _notify();
      return;
    }
    if (reconfiguring != null) server.text = api?.server.toString() ?? '';
    reconfiguring = null;
    keyInput.clear();
    setup = false;
    setupServerType = serverType;
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
      setupServerType = ArchiveServerType.mailArchiver;
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
      activeArchiveId = null;
      _retryArchiveId = null;
      reconfiguring = null;
      error = null;
      _notify();
      await _refreshArchives();
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
