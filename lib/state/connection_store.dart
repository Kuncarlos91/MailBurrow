import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A saved archive connection.
typedef SavedConnection = ({String server, String key, int? accountId});

/// Saved server, API key and selected account, kept in platform secure
/// storage under the existing `connection` key.
class ConnectionStore {
  const ConnectionStore();

  static const _storage = FlutterSecureStorage();
  static const _entry = 'connection';

  /// The saved connection, or null when none is saved. Throws when the saved
  /// value cannot be read or decoded.
  Future<SavedConnection?> read() async {
    final saved = await _storage.read(key: _entry);
    if (saved == null) return null;
    final data = jsonDecode(saved) as Map<String, dynamic>;
    return (
      server: data['server'] as String,
      key: data['key'] as String,
      accountId: data['accountId'] is int ? data['accountId'] as int : null,
    );
  }

  Future<void> write({
    required String server,
    required String key,
    required Object? accountId,
  }) => _storage.write(
    key: _entry,
    value: jsonEncode({'server': server, 'key': key, 'accountId': accountId}),
  );

  Future<void> delete() => _storage.delete(key: _entry);
}
