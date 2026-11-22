import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_lock_platform.dart';
import 'app_lock_settings.dart';

/// Where app lock stands. Only [off] and an uncovered [unlocked] show
/// archive content.
enum AppLockPhase {
  /// The setting has not been read yet. Content stays covered.
  loading,

  /// The setting could not be read or is damaged. Content stays covered and
  /// is never treated as "off".
  error,

  /// App lock is off.
  off,

  /// App lock is on and the user must unlock.
  locked,

  /// The operating-system prompt is showing.
  authenticating,

  /// App lock is on and the user has unlocked.
  unlocked,
}

/// Owns app lock state, timing and the stored setting.
///
/// Rules (see the Playbook's app lock entry):
/// - Startup stays covered until the setting is read; failures stay covered.
/// - Only the success of the current prompt can unlock. Disposal, a newer
///   prompt or a settings change makes older results stale.
/// - Time away is measured on a monotonic clock that includes device sleep.
///   An unknown time counts as expired.
/// - A prompt is never retried automatically after cancel or failure.
/// - Turning app lock off or changing its timing needs a fresh unlock, and
///   the setting changes only after it is saved.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({
    AppLockStore store = const AppLockStore(),
    AppLockPlatform? platform,
    AppLifecycleState? Function()? lifecycleState,
  }) : _store = store,
       _platform = platform ?? DeviceAppLockPlatform(),
       _lifecycleState =
           lifecycleState ?? (() => WidgetsBinding.instance.lifecycleState);

  final AppLockStore _store;
  final AppLockPlatform _platform;
  final AppLifecycleState? Function() _lifecycleState;

  AppLockPhase _phase = AppLockPhase.loading;
  AppLockSettings? _settings;
  bool _revealed = false;
  bool _covered = false;
  bool _busy = false;
  bool _disposed = false;
  bool _observing = false;
  String? _message;

  // Incremented whenever an in-flight result must be ignored.
  int _generation = 0;
  // A prompt (unlock or settings) is showing; lifecycle changes it causes
  // are settled when it ends.
  bool _promptInFlight = false;
  // When the user left while unlocked, on the monotonic clock. Null value
  // inside means the time is unknown, which counts as expired.
  Future<int?>? _leftAt;
  // The user left while locked: prompt once on return.
  bool _promptOnResume = false;

  AppLockPhase get phase => _phase;

  /// The stored setting once read; null while loading or after an error.
  AppLockSettings? get settings => _settings;

  bool get enabled => _settings?.enabled == true;

  /// A settings change is in progress.
  bool get busy => _busy;

  /// An operating-system prompt is showing.
  bool get prompting => _promptInFlight;

  /// A short message for the lock screen, or null. Never contains archive
  /// data or error details.
  String? get message => _message;

  /// The app's content may be built. False until the first unlock (or until
  /// the setting is known to be off), so nothing is restored or requested
  /// behind a startup lock.
  bool get mayBuildContent => _revealed;

  /// Archive content may be shown and used right now.
  bool get contentVisible =>
      _phase == AppLockPhase.off ||
      (_phase == AppLockPhase.unlocked && !_covered);

  bool get _resumed {
    final state = _lifecycleState();
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Reads the setting and starts watching the app lifecycle.
  Future<void> start() async {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    await _load();
  }

  /// Retries reading a setting that could not be read.
  Future<void> retry() async {
    if (_phase == AppLockPhase.error) await _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _phase = AppLockPhase.loading;
    _message = null;
    _notify();
    AppLockSettings? stored;
    try {
      stored = await _store.read();
    } on Object {
      if (_stale(generation)) return;
      _settings = null;
      _phase = AppLockPhase.error;
      _message =
          'App lock settings could not be read, so MailBurrow stays locked.';
      _notify();
      return;
    }
    if (_stale(generation)) return;
    final settings = stored ?? AppLockSettings.off;
    _settings = settings;
    if (!settings.enabled) {
      _phase = AppLockPhase.off;
      _revealed = true;
      _notify();
      await _platform.setPrivacyProtection(false);
      return;
    }
    _phase = AppLockPhase.locked;
    _notify();
    await _platform.setPrivacyProtection(true);
    if (_stale(generation)) return;
    _promptOnResume = true;
    if (_resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrompt());
    }
  }

  void _autoPrompt() {
    if (_disposed || !_promptOnResume || !_resumed) return;
    if (_phase != AppLockPhase.locked) return;
    _promptOnResume = false;
    unlock();
  }

  /// Shows the system prompt to unlock. Ignored while a prompt is showing.
  Future<void> unlock() async {
    if (_phase != AppLockPhase.locked || _promptInFlight) return;
    _promptOnResume = false;
    final generation = ++_generation;
    _phase = AppLockPhase.authenticating;
    _message = null;
    _notify();
    final result = await _prompt('Unlock MailBurrow');
    if (_stale(generation) || _phase != AppLockPhase.authenticating) return;
    if (result == AppLockAuthResult.success) {
      _phase = AppLockPhase.unlocked;
      _revealed = true;
      _leftAt = null;
      _covered = !_resumed;
    } else {
      _phase = AppLockPhase.locked;
      _message = _messageFor(result);
    }
    _notify();
    _settleAfterPrompt();
  }

  /// Recovers from an unreadable setting: after a fresh unlock, saves app
  /// lock as on with the default timing and unlocks. Never turns it off.
  Future<void> unlockAndRepair() async {
    if (_phase != AppLockPhase.error || _promptInFlight || _busy) return;
    final generation = ++_generation;
    _message = null;
    _notify();
    final result = await _prompt('Unlock MailBurrow');
    if (_stale(generation) || _phase != AppLockPhase.error) return;
    if (result != AppLockAuthResult.success) {
      _message =
          _messageFor(result) ??
          'App lock settings could not be read, so MailBurrow stays locked.';
      _notify();
      return;
    }
    const repaired = AppLockSettings(
      enabled: true,
      relockAfter: AppLockSettings.defaultRelock,
    );
    _leftAt = null;
    _busy = true;
    _notify();
    try {
      await _store.write(repaired);
    } on Object {
      if (_stale(generation)) return;
      _message = 'App lock settings could not be saved. Try again.';
      _notify();
      return;
    } finally {
      _busy = false;
      _notify();
    }
    if (_stale(generation)) return;
    _settings = repaired;
    _phase = AppLockPhase.unlocked;
    _revealed = true;
    _covered = !_resumed || _leftAt != null;
    if (!_resumed) {
      _phase = AppLockPhase.locked;
      _promptOnResume = true;
    }
    _notify();
    await _platform.setPrivacyProtection(true);
    _settleAfterPrompt(succeeded: false);
  }

  /// Turns app lock on after a successful prompt. Returns a message for the
  /// user, or null when it was turned on or the prompt was cancelled.
  Future<String?> enable({
    Duration relockAfter = AppLockSettings.defaultRelock,
  }) => _changeSettings(
    allowedFrom: AppLockPhase.off,
    reason: 'Turn on app lock',
    next: AppLockSettings(enabled: true, relockAfter: relockAfter),
    checkDevice: true,
    saveFailed: 'App lock could not be saved, so it is still off.',
  );

  /// Turns app lock off after a fresh prompt.
  Future<String?> disable() => _changeSettings(
    allowedFrom: AppLockPhase.unlocked,
    reason: 'Turn off app lock',
    next: AppLockSettings.off.copyWith(relockAfter: _settings?.relockAfter),
    saveFailed: 'App lock could not be turned off, so it is still on.',
  );

  /// Changes the relock time after a fresh prompt.
  Future<String?> setRelockAfter(Duration relockAfter) {
    if (!AppLockSettings.relockChoices.contains(relockAfter) ||
        relockAfter == _settings?.relockAfter) {
      return Future.value();
    }
    return _changeSettings(
      allowedFrom: AppLockPhase.unlocked,
      reason: 'Change app lock timing',
      next: _settings!.copyWith(relockAfter: relockAfter),
      saveFailed: 'The new timing could not be saved, so it was not changed.',
    );
  }

  Future<String?> _changeSettings({
    required AppLockPhase allowedFrom,
    required String reason,
    required AppLockSettings next,
    required String saveFailed,
    bool checkDevice = false,
  }) async {
    if (_busy || _promptInFlight || _phase != allowedFrom) return null;
    if (allowedFrom == AppLockPhase.unlocked && !contentVisible) return null;
    _busy = true;
    _notify();
    final generation = ++_generation;
    try {
      if (checkDevice && !await _platform.canAuthenticate()) {
        return _noScreenLockMessage;
      }
      if (_stale(generation)) return null;
      final result = await _prompt(reason);
      if (_stale(generation) || _phase != allowedFrom) return null;
      if (result != AppLockAuthResult.success) return _messageFor(result);
      // The successful foreground prompt settles its own lifecycle events,
      // but any leave during the following storage write is a new leave.
      _leftAt = null;
      try {
        await _store.write(next);
      } on Object {
        return saveFailed;
      }
      if (_stale(generation)) return null;
      _settings = next;
      _phase = next.enabled ? AppLockPhase.unlocked : AppLockPhase.off;
      if (!next.enabled) {
        _covered = false;
      } else if (!_resumed) {
        _phase = AppLockPhase.locked;
        _covered = true;
        _promptOnResume = true;
      } else if (_leftAt != null) {
        _covered = true;
      }
      await _platform.setPrivacyProtection(next.enabled);
      return null;
    } finally {
      _busy = false;
      if (!_disposed) {
        _notify();
        _settleAfterPrompt(succeeded: false);
      }
    }
  }

  Future<AppLockAuthResult> _prompt(String reason) async {
    _promptInFlight = true;
    _notify();
    try {
      final result = await _platform.authenticate(reason);
      // A result delivered while genuinely away cannot authorize a future
      // return. Prompt-induced inactivity may settle before the callback;
      // only accept success when the app is foreground again.
      return result == AppLockAuthResult.success && !_resumed
          ? AppLockAuthResult.canceled
          : result;
    } finally {
      _promptInFlight = false;
      _notify();
    }
  }

  // Called after any prompt ends. A successful prompt proves the user is
  // present, so time away during it is not counted. Otherwise a leave during
  // the prompt is judged now, if the app is already back.
  void _settleAfterPrompt({bool? succeeded}) {
    if (_disposed) return;
    final ok = succeeded ?? _phase == AppLockPhase.unlocked;
    if (ok && _phase == AppLockPhase.unlocked) _leftAt = null;
    if (_resumed) _onResumed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        if (enabled && _phase == AppLockPhase.unlocked && !_covered) {
          _covered = true;
          _notify();
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!enabled && !_busy) return;
        if (_phase == AppLockPhase.unlocked || (_busy && !_promptInFlight)) {
          _covered = true;
          _leftAt ??= _platform.elapsedMillis();
          _notify();
        } else if (_phase == AppLockPhase.locked && !_promptInFlight) {
          _promptOnResume = true;
        }
      case AppLifecycleState.resumed:
        _onResumed();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _onResumed() async {
    if (_disposed || _promptInFlight) return;
    switch (_phase) {
      case AppLockPhase.locked:
        _autoPrompt();
      case AppLockPhase.unlocked:
        final left = _leftAt;
        if (left == null) {
          if (_covered) {
            _covered = false;
            _notify();
          }
          return;
        }
        final generation = _generation;
        final leftAt = await left;
        final now = await _platform.elapsedMillis();
        if (_stale(generation) || _phase != AppLockPhase.unlocked) return;
        if (!identical(_leftAt, left)) return;
        if (!_resumed) return; // Left again; judged on the next return.
        _leftAt = null;
        final relock = _settings?.relockAfter ?? Duration.zero;
        final expired =
            leftAt == null ||
            now == null ||
            now < leftAt ||
            now - leftAt >= relock.inMilliseconds;
        if (expired) {
          _phase = AppLockPhase.locked;
          _covered = false;
          _promptOnResume = true;
          _notify();
          _autoPrompt();
        } else {
          _covered = false;
          _notify();
        }
      case AppLockPhase.loading:
      case AppLockPhase.error:
      case AppLockPhase.off:
      case AppLockPhase.authenticating:
        break;
    }
  }

  /// While content is hidden, Back does nothing instead of acting on the
  /// hidden screens.
  bool get _blocksBack => _phase != AppLockPhase.off && !contentVisible;

  @override
  Future<bool> didPopRoute() async => _blocksBack;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => _blocksBack;

  @override
  void handleCommitBackGesture() {}

  @override
  void handleCancelBackGesture() {}

  static const _noScreenLockMessage =
      'Set up a screen lock (PIN, pattern, password, fingerprint or face) in '
      'your device settings first.';

  String? _messageFor(AppLockAuthResult result) => switch (result) {
    AppLockAuthResult.success || AppLockAuthResult.canceled => null,
    AppLockAuthResult.noScreenLock =>
      'This device has no screen lock. Set one up in your device settings, '
          'then unlock MailBurrow.',
    AppLockAuthResult.lockedOut =>
      'Too many attempts. Wait, then try again or use your device PIN, '
          'pattern or password.',
    AppLockAuthResult.failed => 'MailBurrow could not be unlocked. Try again.',
  };

  bool _stale(int generation) => _disposed || generation != _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
