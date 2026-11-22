import 'dart:convert';

import '../state/connection_store.dart';

/// The stored app lock preference: whether it is on and how long MailBurrow
/// may stay unlocked after the user leaves it.
///
/// Only this preference is stored. Biometric data and device credentials
/// never reach the app; the operating system checks them.
class AppLockSettings {
  const AppLockSettings({required this.enabled, required this.relockAfter});

  static const off = AppLockSettings(
    enabled: false,
    relockAfter: defaultRelock,
  );
  static const defaultRelock = Duration(minutes: 1);

  /// The relock times offered in Settings, in order.
  static const relockChoices = [
    Duration.zero,
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  static const _version = 1;

  final bool enabled;
  final Duration relockAfter;

  AppLockSettings copyWith({bool? enabled, Duration? relockAfter}) =>
      AppLockSettings(
        enabled: enabled ?? this.enabled,
        relockAfter: relockAfter ?? this.relockAfter,
      );

  String encode() => jsonEncode({
    'version': _version,
    'enabled': enabled,
    'relockSeconds': relockAfter.inSeconds,
  });

  /// Decodes a stored value. Anything unexpected throws [FormatException],
  /// so a damaged value is never mistaken for "off".
  static AppLockSettings decode(String text) {
    final Object? value;
    try {
      value = jsonDecode(text);
    } on FormatException {
      throw const FormatException('App lock setting is not valid JSON');
    }
    if (value is! Map ||
        value['version'] != _version ||
        value['enabled'] is! bool ||
        value['relockSeconds'] is! int) {
      throw const FormatException('App lock setting has an unknown format');
    }
    final relock = Duration(seconds: value['relockSeconds'] as int);
    if (!relockChoices.contains(relock)) {
      throw const FormatException('App lock relock time is not supported');
    }
    return AppLockSettings(
      enabled: value['enabled'] as bool,
      relockAfter: relock,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppLockSettings &&
      other.enabled == enabled &&
      other.relockAfter == relockAfter;

  @override
  int get hashCode => Object.hash(enabled, relockAfter);
}

/// Reads and writes [AppLockSettings] in the app's secure storage, under an
/// entry name that never overlaps the saved-connection entries.
class AppLockStore {
  const AppLockStore({this.entries = const SecureEntries()});

  static const entry = 'app_lock';

  final SecureEntries entries;

  /// The stored setting, or null when none was ever saved (a new install, or
  /// one that never turned app lock on). Read failures and damaged values
  /// throw instead of returning null.
  Future<AppLockSettings?> read() async {
    final text = await entries.read(key: entry);
    return text == null ? null : AppLockSettings.decode(text);
  }

  Future<void> write(AppLockSettings settings) =>
      entries.write(key: entry, value: settings.encode());
}
