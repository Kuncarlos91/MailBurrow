import 'dart:convert';
import 'dart:math';

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

/// One saved archive in the connection index, without its key.
typedef ConnectionProfile = ({
  String id,
  String label,
  ArchiveServerType serverType,
  String server,
  String? accountId,
});

/// Saved archive connections in platform secure storage.
///
/// Format version 3 (current, provisional until the multi-archive prototype
/// is reviewed) keeps an **index** under `connections`:
/// `{"version": 3, "active": "<id>" | null, "profiles": [{"id", "label",
/// "serverType", "server", "accountId"}]}`, which holds no keys, and **one
/// key entry per profile** under `connection.key.<id>`. Writes are staged so
/// that a failed write never breaks another profile or the working key: a
/// new or changed key is written under a fresh ID before the index points to
/// it, and an old key entry is deleted only after the index stops pointing to
/// it. Key entries the index does not reference are removed when it is read.
///
/// Older builds kept one record under `connection`. Version 2 is
/// `{"version": 2, "serverType", "server", "key", "accountId": "7" | null}`;
/// version 1 (0.3.0-rc.9 and earlier) had no version or server type and a
/// numeric `accountId`, and is read as Mail-Archiver, the only type those
/// builds supported. A readable legacy record migrates to one profile; it is
/// deleted only after the new entries are written. An unreadable one is left
/// untouched. The saved key is never used to detect a server type.
///
/// Until the archive picker exists, [read], [write] and [delete] act on the
/// active profile only, so the app behaves as with one saved connection.
class ConnectionStore {
  const ConnectionStore({this.entries = const SecureEntries()});

  /// The secure-storage entries; tests substitute failing ones.
  final SecureEntries entries;

  SecureEntries get _storage => entries;
  static const _legacyEntry = 'connection';
  static const _indexEntry = 'connections';
  static const _keyPrefix = 'connection.key.';
  static const legacyVersion = 2;
  static const currentVersion = 3;
  static const maxProfiles = 20;
  static const maxLabelLength = 60;

  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');

  /// A new random profile ID: 128 bits as lowercase hex.
  static String newProfileId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// The default label for a server address: its host.
  static String defaultLabel(String server) {
    final host = Uri.tryParse(server)?.host ?? '';
    final label = host.isEmpty ? server : host;
    return label.length > maxLabelLength
        ? label.substring(0, maxLabelLength)
        : label;
  }

  /// The active saved connection, or null when none is active. Migrates a
  /// readable legacy record first. Throws [FormatException] when the active
  /// profile or a legacy record cannot be read; the stored values are kept.
  Future<SavedConnection?> read() async {
    var index = await _readIndex();
    if (index == null) {
      final legacy = await _storage.read(key: _legacyEntry);
      if (legacy == null) return null;
      final saved = decode(legacy);
      try {
        await _migrate(saved);
      } catch (_) {
        // Keep the legacy record; the next start retries the migration.
        return saved;
      }
      index = await _readIndex();
      if (index == null) return saved;
    } else {
      await _removeLegacy();
    }
    await _removeOrphanKeys(index);
    final active = index.active;
    if (active == null) return null;
    final profile = index.profiles.where((item) => item.id == active).firstOrNull;
    if (profile == null) {
      throw const FormatException('Saved connection is unreadable.');
    }
    final key = await _storage.read(key: '$_keyPrefix${profile.id}');
    if (key == null || key.isEmpty) {
      throw const FormatException('Saved connection key is missing.');
    }
    return (
      serverType: profile.serverType,
      server: profile.server,
      key: key,
      accountId: profile.accountId,
    );
  }

  /// Saves the active connection. Changing only the selected account rewrites
  /// the index; a changed server type, address or key is staged under a fresh
  /// profile ID, so the previous one stays intact if any write fails.
  Future<void> write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
  }) async {
    // An unreadable index is replaced, as an unreadable legacy record was.
    final index = await _readIndexOrNull() ?? ConnectionIndex.empty;
    final profiles = [...index.profiles];
    final at = profiles.indexWhere((item) => item.id == index.active);
    final current = at < 0 ? null : profiles[at];
    if (current != null &&
        current.serverType == serverType &&
        current.server == server &&
        await _storage.read(key: '$_keyPrefix${current.id}') == key) {
      profiles[at] = (
        id: current.id,
        label: current.label,
        serverType: serverType,
        server: server,
        accountId: accountId,
      );
      await _writeIndex(current.id, profiles, index.unreadable);
      return;
    }
    if (current == null && profiles.length >= maxProfiles) {
      throw StateError('Too many saved archives.');
    }
    final profile = (
      id: newProfileId(),
      label: current?.label ?? defaultLabel(server),
      serverType: serverType,
      server: server,
      accountId: accountId,
    );
    await _storage.write(key: '$_keyPrefix${profile.id}', value: key);
    if (at < 0) {
      profiles.add(profile);
    } else {
      profiles[at] = profile;
    }
    try {
      await _writeIndex(profile.id, profiles, index.unreadable);
    } catch (_) {
      await _deleteQuietly('$_keyPrefix${profile.id}');
      rethrow;
    }
    if (current != null) await _deleteQuietly('$_keyPrefix${current.id}');
    await _removeLegacy();
  }

  /// Forgets the active connection: its profile, its key and any legacy
  /// record. Other profiles are kept.
  Future<void> delete() async {
    if (await _storage.read(key: _indexEntry) != null) {
      final index = await _readIndexOrNull();
      if (index == null) {
        // Nothing in an unreadable index can be told apart, so forgetting
        // clears it and every key entry, as forgetting one record did.
        await _storage.delete(key: _indexEntry);
        await _removeOrphanKeys(ConnectionIndex.empty);
      } else {
        final active = index.active;
        final profiles = [
          for (final item in index.profiles)
            if (item.id != active) item,
        ];
        await _writeIndex(null, profiles, index.unreadable);
        if (active != null) await _deleteQuietly('$_keyPrefix$active');
      }
    }
    await _storage.delete(key: _legacyEntry);
  }

  /// Every saved profile, without keys, for the archive picker.
  Future<List<ConnectionProfile>> profiles() async =>
      (await _readIndex())?.profiles ?? const [];

  Future<void> _migrate(SavedConnection saved) async {
    final profile = (
      id: newProfileId(),
      label: defaultLabel(saved.server),
      serverType: saved.serverType,
      server: saved.server,
      accountId: saved.accountId,
    );
    await _storage.write(key: '$_keyPrefix${profile.id}', value: saved.key);
    try {
      await _writeIndex(profile.id, [profile], const []);
    } catch (_) {
      await _deleteQuietly('$_keyPrefix${profile.id}');
      rethrow;
    }
    await _removeLegacy();
  }

  Future<void> _removeLegacy() => _storage.delete(key: _legacyEntry);

  Future<void> _removeOrphanKeys(ConnectionIndex index) async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } catch (_) {
      return;
    }
    // IDs of unreadable profiles count too, so their keys survive for a
    // build that can read them.
    final known = {for (final id in index.referencedIds) '$_keyPrefix$id'};
    for (final name in all.keys) {
      if (name.startsWith(_keyPrefix) && !known.contains(name)) {
        await _deleteQuietly(name);
      }
    }
  }

  Future<void> _deleteQuietly(String name) async {
    try {
      await _storage.delete(key: name);
    } catch (_) {
      // An orphaned key entry is removed on the next read.
    }
  }

  Future<ConnectionIndex?> _readIndexOrNull() async {
    try {
      return await _readIndex();
    } on FormatException {
      return null;
    }
  }

  Future<ConnectionIndex?> _readIndex() async {
    final text = await _storage.read(key: _indexEntry);
    return text == null ? null : decodeIndex(text);
  }

  Future<void> _writeIndex(
    String? active,
    List<ConnectionProfile> profiles,
    List<Object?> unreadable,
  ) => _storage.write(
    key: _indexEntry,
    value: encodeIndex(active, profiles, unreadable: unreadable),
  );

  /// Decodes the v3 index. Profiles that fail validation, or repeat an ID,
  /// are kept aside unchanged in [ConnectionIndex.unreadable] and written
  /// back as they were; an unknown version or shape throws
  /// [FormatException].
  static ConnectionIndex decodeIndex(String text) {
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic> || data['version'] != currentVersion) {
      throw const FormatException('Saved archives version is unknown.');
    }
    final list = data['profiles'];
    final active = data['active'];
    if (list is! List<dynamic> || (active != null && active is! String)) {
      throw const FormatException('Saved archives are unreadable.');
    }
    final profiles = <ConnectionProfile>[];
    final unreadable = <Object?>[];
    final referenced = <String>{};
    for (final item in list) {
      final profile = _decodeProfile(item);
      final rawId = item is Map<String, dynamic> ? item['id'] : null;
      if (rawId is String && _idPattern.hasMatch(rawId)) referenced.add(rawId);
      if (profile == null || profiles.any((p) => p.id == profile.id)) {
        unreadable.add(item);
      } else {
        profiles.add(profile);
      }
    }
    return ConnectionIndex(
      active: active as String?,
      profiles: profiles,
      unreadable: unreadable,
      referencedIds: referenced,
    );
  }

  static ConnectionProfile? _decodeProfile(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = value['id'];
    final label = value['label'];
    final type = ArchiveServerType.fromId(value['serverType']);
    final server = value['server'];
    final account = value['accountId'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        label is! String ||
        label.length > maxLabelLength ||
        type == null ||
        server is! String ||
        server.isEmpty ||
        (account != null && account is! String)) {
      return null;
    }
    return (
      id: id,
      label: label,
      serverType: type,
      server: server,
      accountId: account as String?,
    );
  }

  /// Encodes the v3 index.
  static String encodeIndex(
    String? active,
    List<ConnectionProfile> profiles, {
    List<Object?> unreadable = const [],
  }) => jsonEncode({
    'version': currentVersion,
    'active': active,
    'profiles': [
      for (final item in profiles)
        {
          'id': item.id,
          'label': item.label,
          'serverType': item.serverType.id,
          'server': item.server,
          'accountId': item.accountId,
        },
      ...unreadable,
    ],
  });

  /// Decodes a legacy single-connection record (version 1 or 2).
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
    if (version != legacyVersion) {
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

  /// Encodes a connection as a legacy version 2 record. Used to describe a
  /// connection in tests and diagnostics; the app no longer writes it.
  static String encode({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
  }) => jsonEncode({
    'version': legacyVersion,
    'serverType': serverType.id,
    'server': server,
    'key': key,
    'accountId': accountId,
  });
}

/// Secure-storage access used by [ConnectionStore].
class SecureEntries {
  const SecureEntries();
  static const _storage = FlutterSecureStorage();
  Future<String?> read({required String key}) => _storage.read(key: key);
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);
  Future<void> delete({required String key}) => _storage.delete(key: key);
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// The decoded v3 index.
class ConnectionIndex {
  const ConnectionIndex({
    required this.active,
    required this.profiles,
    this.unreadable = const [],
    this.referencedIds = const {},
  });

  static const empty = ConnectionIndex(active: null, profiles: []);

  /// The active profile ID, or null when none is active.
  final String? active;
  final List<ConnectionProfile> profiles;

  /// Entries this build cannot read, kept as stored.
  final List<Object?> unreadable;

  /// Every well-formed profile ID in the index, readable or not.
  final Set<String> referencedIds;
}
