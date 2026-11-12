import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../archive_server_type.dart';

/// A saved archive connection.
///
/// [accountId] is text for every server type: Mail-Archiver's numeric IDs are
/// stored as their decimal string, and other servers use text IDs.
typedef SavedConnection = ({
  ArchiveServerType serverType,
  String server,
  String key,
  String? accountId,
});

/// Saved server type, server, API key and selected account, kept in platform
/// secure storage under the existing `connection` key.
///
/// Format version 2 (current) is
/// `{"version": 2, "serverType": "mail-archiver", "server": ..., "key": ...,
/// "accountId": "7" | null}`. Version 1, written by 0.3.0-rc.9 and earlier, had
/// no version or server type and a numeric `accountId`; it is read as a
/// Mail-Archiver connection, because Mail-Archiver was the only server type
/// those builds supported, and is rewritten as version 2 on the next save. The
/// saved key is never used to detect a server type.
class ConnectionStore {
  const ConnectionStore();

  static const _storage = FlutterSecureStorage();
  static const _entry = 'connection';
  static const currentVersion = 2;

  /// The saved connection, or null when none is saved. Throws [FormatException]
  /// when the saved value cannot be decoded, has an unknown version or server
  /// type, or is missing required fields.
  Future<SavedConnection?> read() async {
    final saved = await _storage.read(key: _entry);
    if (saved == null) return null;
    return decode(saved);
  }

  /// Decodes a stored value; see the class comment for the formats.
  static SavedConnection decode(String saved) {
    final data = jsonDecode(saved);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Saved connection is not an object.');
    }
    final server = data['server'];
    final key = data['key'];
    if (server is! String || key is! String) {
      throw const FormatException('Saved connection is missing fields.');
    }
    final version = data['version'];
    if (!data.containsKey('version') && !data.containsKey('serverType')) {
      // Only untagged records are legacy. A null version or a serverType
      // without a version must not bypass the current format validation.
      // Version 1: Mail-Archiver only, numeric account ID.
      final id = data['accountId'];
      return (
        serverType: ArchiveServerType.mailArchiver,
        server: server,
        key: key,
        accountId: id is int ? '$id' : null,
      );
    }
    if (version != currentVersion) {
      throw const FormatException('Saved connection version is unknown.');
    }
    final type = ArchiveServerType.fromId(data['serverType']);
    if (type == null) {
      throw const FormatException('Saved server type is unknown.');
    }
    final id = data['accountId'];
    if (id != null && id is! String) {
      throw const FormatException('Saved account is not text.');
    }
    return (
      serverType: type,
      server: server,
      key: key,
      accountId: id as String?,
    );
  }

  /// Encodes a connection in the current format.
  static String encode({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required Object? accountId,
  }) => jsonEncode({
    'version': currentVersion,
    'serverType': serverType.id,
    'server': server,
    'key': key,
    'accountId': accountId?.toString(),
  });

  /// Saves a connection in the current format. [accountId] may be a
  /// Mail-Archiver number or a text ID; it is stored as text.
  Future<void> write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required Object? accountId,
  }) => _storage.write(
    key: _entry,
    value: encode(
      serverType: serverType,
      server: server,
      key: key,
      accountId: accountId,
    ),
  );

  Future<void> delete() => _storage.delete(key: _entry);
}
