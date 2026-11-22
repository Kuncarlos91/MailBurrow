import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// The outcome of one operating-system authentication prompt.
enum AppLockAuthResult {
  success,

  /// The user or the system dismissed the prompt, for example by leaving
  /// the app. Never retried automatically.
  canceled,

  /// The device has no screen lock, so it cannot authenticate the user.
  noScreenLock,

  /// Too many attempts; the operating system decides when to allow more.
  lockedOut,

  /// Any other failure. The details are not shown or logged.
  failed,
}

/// Device services app lock needs. Tests substitute a fake.
abstract class AppLockPlatform {
  /// Whether the device can authenticate the user at all: biometrics or a
  /// device PIN, pattern or password. Not a biometrics-only check.
  Future<bool> canAuthenticate();

  /// Shows the system prompt. Biometrics with the device screen lock as the
  /// fallback (decision AL02).
  Future<AppLockAuthResult> authenticate(String reason);

  /// Milliseconds on a monotonic clock that keeps counting while the device
  /// sleeps, or null when unavailable (callers then fail closed).
  Future<int?> elapsedMillis();

  /// Turns the app-switcher privacy protection on or off (decision AL04).
  Future<void> setPrivacyProtection(bool enabled);
}

/// The real platform: `local_auth` plus MailBurrow's `mailburrow/app_lock`
/// channel.
class DeviceAppLockPlatform implements AppLockPlatform {
  DeviceAppLockPlatform({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  static const _channel = MethodChannel('mailburrow/app_lock');
  final LocalAuthentication _auth;

  @override
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.isDeviceSupported();
    } on Object {
      return false;
    }
  }

  @override
  Future<AppLockAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // Never retry by itself after the app is backgrounded; the lock
        // stays and the user unlocks again.
        persistAcrossBackgrounding: false,
      );
      return ok ? AppLockAuthResult.success : AppLockAuthResult.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.userRequestedFallback =>
          AppLockAuthResult.canceled,
        LocalAuthExceptionCode.noCredentialsSet =>
          AppLockAuthResult.noScreenLock,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => AppLockAuthResult.lockedOut,
        _ => AppLockAuthResult.failed,
      };
    } on Object {
      return AppLockAuthResult.failed;
    }
  }

  @override
  Future<int?> elapsedMillis() async {
    try {
      return await _channel.invokeMethod<int>('elapsedRealtime');
    } on Object {
      return null;
    }
  }

  @override
  Future<void> setPrivacyProtection(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setPrivacyProtection', {
        'enabled': enabled,
      });
    } on Object {
      // The Flutter-level cover still applies.
    }
  }
}
