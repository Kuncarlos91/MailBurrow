import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../certificate_import.dart' show certificateImportByteLimit;
import '../archive_server_type.dart';

/// A saved archive connection.
///
/// [accountId] is text for every server type: Mail-Archiver's numeric IDs are
/// stored as their decimal string, and other servers use text IDs.
/// [certificate] is the archive's own certificate (DER), trusted for this
/// archive in addition to the public roots, or null for default trust.
typedef SavedConnection = ({
  ArchiveServerType serverType,
  String server,
  String key,
  String? accountId,
  List<int>? certificate,
});

/// One saved archive in the connection index, without its key.
/// [ownCertificate] is true when it trusts a certificate of its own.
typedef ConnectionProfile = ({
  String id,
  String label,
  ArchiveServerType serverType,
  String server,
  String? accountId,
  bool ownCertificate,
});

/// A saved archive claims its own certificate, but this build can't use the
/// saved record: it is missing, damaged, bound to another address, or from a
/// newer version. The archive must not connect with default trust instead;
/// the record is left as it is.
class SavedCertificateUnavailable extends FormatException {
  const SavedCertificateUnavailable(super.message);
}

/// How saving a connection changes its own certificate.
class CertificateChange {
  /// Keep the current certificate when the server type and address stay the
  /// same; a changed type or address never inherits it.
  const CertificateChange.keep() : der = null, remove = false;

  /// Trust [der] (one certificate, already checked on import).
  CertificateChange.set(List<int> bytes)
    : der = _snapshot(bytes),
      remove = false;

  static List<int> _snapshot(List<int> bytes) {
    if (bytes.isEmpty ||
        bytes.length > certificateImportByteLimit ||
        bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('Certificate bytes are out of range.');
    }
    return List<int>.unmodifiable(bytes);
  }

  /// Go back to default trust.
  const CertificateChange.remove() : der = null, remove = true;

  final List<int>? der;
  final bool remove;
  bool get keep => der == null && !remove;
}

/// Saving would exceed [ConnectionStore.maxProfiles].
class TooManySavedArchives extends StateError {
  TooManySavedArchives() : super('Too many saved archives.');
}

/// The saved archive to update is no longer in the index.
class SavedArchiveMissing extends StateError {
  SavedArchiveMissing() : super('Saved archive is no longer available.');
}

/// The saved archives as the picker shows them.
typedef SavedArchives = ({
  String? active,
  List<ConnectionProfile> profiles,
  bool unreadable,
});

/// Saved archive connections in platform secure storage.
///
/// Format version 3 (current, provisional until the multi-archive prototype
/// is reviewed) keeps an **index** under `connections`, holding the version,
/// the active profile ID (or null) and, per profile, its `id`, `label`,
/// `serverType`, `server` and `accountId`. The index holds no keys. There is
/// **one key entry per profile**, named `connection.key.` plus its ID. Writes
/// are staged so that a failed write never breaks another profile or the working key: a
/// new or changed key is written under a fresh ID before the index points to
/// it, and an old key entry is deleted only after the index stops pointing to
/// it. Key entries the index does not reference are removed when it is read.
///
/// An archive with its own certificate is marked `"ownCertificate": true` in
/// the index (the key is omitted otherwise) and has one more entry,
/// `connection.trust.` plus its ID: `{"version": 1, "serverType", "server",
/// "der": base64, "sha256": hex}`. The record names the destination it was
/// trusted for and is used only when both still match; its fingerprint is
/// checked on every read. It is staged with the key: a changed certificate
/// gets a fresh profile ID like a changed key. Custom-trust indexes use
/// version 4, which older builds refuse before connecting; ordinary profiles remain version 3. Removing all custom
/// trust permits a version-3 index again.
///
/// Older builds kept one record under `connection`. Version 2 is
/// `{"version": 2, "serverType", "server", "key", "accountId": "7" | null}`;
/// version 1 (0.3.0-rc.9 and earlier) had no version or server type and a
/// numeric `accountId`, and is read as Mail-Archiver, the only type those
/// builds supported. A readable legacy record migrates to one profile; it is
/// deleted only after the new entries are written. An unreadable one is left
/// untouched. The saved key is never used to detect a server type.
///
/// [read] and [delete] act on the active profile. [write] updates the active
/// profile, or the one named by its `profileId`, and makes it active. [add]
/// saves a connection entered in setup. [overview] lists the saved archives
/// for the picker, and [reset] is the explicit all-archives reset offered
/// only when the index cannot be read.
class ConnectionStore {
  const ConnectionStore({this.entries = const SecureEntries()});

  /// The secure-storage entries; tests substitute failing ones.
  final SecureEntries entries;

  SecureEntries get _storage => entries;

  // All instances use the same native store. Serialize complete transactions
  // within this isolate, including reads that perform migration or cleanup.
  static Future<void>? _pending;
  static Future<T> _serialized<T>(Future<T> Function() operation) async {
    final previous = _pending;
    final done = Completer<void>();
    _pending = done.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      if (identical(_pending, done.future)) _pending = null;
      done.complete();
    }
  }

  static const _legacyEntry = 'connection';
  static const _indexEntry = 'connections';
  static const _keyPrefix = 'connection.key.';
  static const _trustPrefix = 'connection.trust.';
  static const trustVersion = 1;
  static const legacyVersion = 2;
  static const currentVersion = 3;
  static const certificateIndexVersion = 4;
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
  Future<SavedConnection?> read() => _serialized(_read);

  Future<SavedConnection?> _read() async {
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
    final profile = index.profiles
        .where((item) => item.id == active)
        .firstOrNull;
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
      certificate: await _certificateFor(profile),
    );
  }

  /// Saves a connection and makes it active: the active profile, or the
  /// readable profile [profileId] when given. Changing only the selected
  /// account rewrites the index; a changed server type, address or key is
  /// staged under a fresh profile ID, so the previous one stays intact if any
  /// write fails. Returns the profile's ID after the write. Throws
  /// [SavedArchiveMissing] when [profileId] is no longer saved.
  /// [certificate] changes the archive's own certificate; a changed one is
  /// staged like a changed key.
  Future<String> write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
    String? profileId,
    CertificateChange certificate = const CertificateChange.keep(),
  }) => _serialized(
    () => _write(
      serverType: serverType,
      server: server,
      key: key,
      accountId: accountId,
      profileId: profileId,
      certificate: certificate,
    ),
  );

  /// Trusts [der] for the readable profile [id], or goes back to default
  /// trust when [der] is null. The certificate is staged under a fresh
  /// profile ID, so the previous record keeps working if any write fails.
  /// Returns the profile's new ID. Throws [SavedArchiveMissing] when [id] is
  /// not saved.
  Future<String> setCertificate(String id, List<int>? der) {
    final change = der == null
        ? const CertificateChange.remove()
        : CertificateChange.set(der);
    return _serialized(() async {
      final index = await _readIndex();
      final profile = index?.profiles
          .where((item) => item.id == id)
          .firstOrNull;
      if (profile == null) throw SavedArchiveMissing();
      final key = await _storage.read(key: '$_keyPrefix${profile.id}');
      if (key == null || key.isEmpty) {
        throw const FormatException('Saved connection key is missing.');
      }
      return _write(
        serverType: profile.serverType,
        server: profile.server,
        key: key,
        accountId: profile.accountId,
        profileId: id,
        certificate: change,
        keepActive: true,
      );
    });
  }

  /// Saves a connection entered in setup and makes it active. A readable
  /// profile with the same server type and address is updated in place
  /// (staged, keeping its label); otherwise a new profile is added, and
  /// other profiles are never changed. Returns the active profile's ID.
  /// Throws [TooManySavedArchives] when [ConnectionStore.maxProfiles] would
  /// be exceeded.
  Future<String> add({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
    CertificateChange certificate = const CertificateChange.keep(),
  }) => _serialized(() async {
    var existing = await _readIndex();
    if (existing == null) {
      final legacy = await _storage.read(key: _legacyEntry);
      if (legacy != null) {
        // Adding another archive must not discard a legacy archive when its
        // startup migration failed or has not run yet.
        await _migrate(decode(legacy));
        existing = await _readIndex();
      }
    }
    final index = existing ?? ConnectionIndex.empty;
    final match = index.profiles
        .where((item) => item.serverType == serverType && item.server == server)
        .firstOrNull;
    if (match != null) {
      return _write(
        serverType: serverType,
        server: server,
        key: key,
        accountId: accountId,
        profileId: match.id,
        certificate: certificate,
      );
    }
    if (index.profiles.length + index.unreadable.length >= maxProfiles) {
      throw TooManySavedArchives();
    }
    final der = certificate.der;
    final profile = (
      id: newProfileId(),
      label: defaultLabel(server),
      serverType: serverType,
      server: server,
      accountId: accountId,
      ownCertificate: der != null,
    );
    await _stage(profile, key, der);
    try {
      await _writeIndex(profile.id, [
        ...index.profiles,
        profile,
      ], index.unreadable);
    } catch (_) {
      await _unstage(profile.id);
      rethrow;
    }
    await _removeLegacy();
    return profile.id;
  });

  Future<String> _write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
    String? profileId,
    CertificateChange certificate = const CertificateChange.keep(),
    bool keepActive = false,
  }) async {
    // Absent and unreadable are distinct: never overwrite an unknown store.
    final index = await _readIndex() ?? ConnectionIndex.empty;
    final profiles = [...index.profiles];
    final target = profileId ?? index.active;
    final at = profiles.indexWhere((item) => item.id == target);
    if (profileId != null && at < 0) {
      throw SavedArchiveMissing();
    }
    final current = at < 0 ? null : profiles[at];
    final sameDestination =
        current != null &&
        current.serverType == serverType &&
        current.server == server;
    String? active(String id) => keepActive ? index.active : id;
    if (sameDestination &&
        certificate.keep &&
        await _storage.read(key: '$_keyPrefix${current.id}') == key) {
      profiles[at] = (
        id: current.id,
        label: current.label,
        serverType: serverType,
        server: server,
        accountId: accountId,
        ownCertificate: current.ownCertificate,
      );
      await _writeIndex(active(current.id), profiles, index.unreadable);
      return current.id;
    }
    if (current == null &&
        profiles.length + index.unreadable.length >= maxProfiles) {
      throw TooManySavedArchives();
    }
    // A kept certificate moves with the profile only to the same
    // destination; a changed type or address starts from default trust.
    // A damaged record that should be kept stops the write instead.
    final der = certificate.keep
        ? (sameDestination ? await _certificateFor(current) : null)
        : certificate.der;
    final profile = (
      id: newProfileId(),
      label: current?.label ?? defaultLabel(server),
      serverType: serverType,
      server: server,
      accountId: accountId,
      ownCertificate: der != null,
    );
    await _stage(profile, key, der);
    if (at < 0) {
      profiles.add(profile);
    } else {
      profiles[at] = profile;
    }
    final wasActive = index.active == current?.id;
    try {
      await _writeIndex(
        keepActive && !wasActive ? index.active : profile.id,
        profiles,
        index.unreadable,
      );
    } catch (_) {
      await _unstage(profile.id);
      rethrow;
    }
    if (current != null) await _unstage(current.id);
    await _removeLegacy();
    return profile.id;
  }

  /// Writes a new profile's key and, when given, its certificate record.
  /// Failures attempt cleanup; a later read retries orphan cleanup.
  Future<void> _stage(
    ConnectionProfile profile,
    String key,
    List<int>? der,
  ) async {
    try {
      await _storage.write(key: '$_keyPrefix${profile.id}', value: key);
      if (der == null) return;
      await _storage.write(
        key: '$_trustPrefix${profile.id}',
        value: encodeCertificate(
          serverType: profile.serverType,
          server: profile.server,
          der: der,
        ),
      );
    } catch (_) {
      await _unstage(profile.id);
      rethrow;
    }
  }

  /// Removes a profile's key and certificate entries, quietly.
  Future<void> _unstage(String id) async {
    await _deleteQuietly('$_keyPrefix$id');
    await _deleteQuietly('$_trustPrefix$id');
  }

  /// The profile's own certificate, or null when it has none. Throws
  /// [SavedCertificateUnavailable] when it claims one this build can't use.
  Future<List<int>?> _certificateFor(ConnectionProfile profile) async {
    if (!profile.ownCertificate) return null;
    final text = await _storage.read(key: '$_trustPrefix${profile.id}');
    if (text == null) {
      throw const SavedCertificateUnavailable('Saved certificate is missing.');
    }
    return decodeCertificate(
      text,
      serverType: profile.serverType,
      server: profile.server,
    );
  }

  /// The saved connection of the readable profile [id], with its key, without
  /// changing which profile is active. Throws [FormatException] when the
  /// profile or its key cannot be read.
  Future<SavedConnection> connection(String id) => _serialized(() async {
    final index = await _readIndex();
    final profile = index?.profiles.where((item) => item.id == id).firstOrNull;
    if (profile == null) {
      throw const FormatException('Saved archive is unavailable.');
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
      certificate: await _certificateFor(profile),
    );
  });

  /// The saved archives for the picker, without keys. [SavedArchives.unreadable]
  /// is true when the index exists but this build cannot read it; that is
  /// the only case in which the app offers [reset]. Storage failures throw.
  Future<SavedArchives> overview() => _serialized(() async {
    final text = await _storage.read(key: _indexEntry);
    if (text == null) {
      final legacy = await _storage.read(key: _legacyEntry);
      if (legacy != null) {
        try {
          decode(legacy);
        } on FormatException {
          return (
            active: null,
            profiles: const <ConnectionProfile>[],
            unreadable: true,
          );
        }
      }
      return (
        active: null,
        profiles: const <ConnectionProfile>[],
        unreadable: false,
      );
    }
    try {
      final index = decodeIndex(text);
      return (
        active: index.active,
        profiles: index.profiles,
        unreadable: false,
      );
    } on FormatException {
      return (
        active: null,
        profiles: const <ConnectionProfile>[],
        unreadable: true,
      );
    }
  });

  /// The explicit all-archives reset: removes the index, every key and
  /// certificate entry and any legacy record from this device. It never contacts a server. If the
  /// stored entries cannot be listed, nothing is removed and this throws.
  Future<void> reset() => _serialized(() async {
    final all = await _storage.readAll();
    // Keep the index until all credentials are removed. On failure, setup
    // can still offer a retry instead of claiming every key was forgotten.
    for (final name in [...all.keys]) {
      if (name.startsWith(_keyPrefix) || name.startsWith(_trustPrefix)) {
        await _storage.delete(key: name);
      }
    }
    await _storage.delete(key: _legacyEntry);
    await _storage.delete(key: _indexEntry);
  });

  /// Renames the readable profile [id]. The label is cleaned with
  /// [cleanLabel]. Throws [SavedArchiveMissing] when [id] is not saved and
  /// [FormatException] when the index cannot be read.
  Future<void> rename(String id, String label) => _serialized(() async {
    final index = await _readIndex();
    final profiles = [...?index?.profiles];
    final at = profiles.indexWhere((item) => item.id == id);
    if (index == null || at < 0) throw SavedArchiveMissing();
    final current = profiles[at];
    profiles[at] = (
      id: current.id,
      label: cleanLabel(label, current.server),
      serverType: current.serverType,
      server: current.server,
      accountId: current.accountId,
      ownCertificate: current.ownCertificate,
    );
    await _writeIndex(index.active, profiles, index.unreadable);
  });

  /// Forgets the readable profile [id], its key and its own certificate;
  /// other profiles are kept.
  /// Forgetting the active profile leaves none active. Server mail and keys
  /// on the server are not touched. Throws [SavedArchiveMissing] when [id] is
  /// not saved and [FormatException] when the index cannot be read.
  Future<void> forget(String id) => _serialized(() async {
    final index = await _readIndex();
    if (index == null || !index.profiles.any((item) => item.id == id)) {
      throw SavedArchiveMissing();
    }
    await _writeIndex(index.active == id ? null : index.active, [
      for (final item in index.profiles)
        if (item.id != id) item,
    ], index.unreadable);
    await _unstage(id);
  });

  /// A label as saved: control characters become spaces, surrounding space
  /// is removed, an empty label becomes [defaultLabel] of [server], and the
  /// result is cut to [maxLabelLength] UTF-16 units without splitting a
  /// character.
  static String cleanLabel(String label, String server) {
    final text = label.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ').trim();
    if (text.isEmpty) return defaultLabel(server);
    final runes = text.runes.toList();
    var result = text;
    while (result.length > maxLabelLength) {
      runes.removeLast();
      result = String.fromCharCodes(runes).trimRight();
    }
    return result;
  }

  /// Forgets the active connection: its profile, its key and any legacy
  /// record. Other profiles are kept. An unreadable index is preserved and
  /// causes a format failure; this is not an all-archives reset.
  Future<void> delete() => _serialized(_delete);

  Future<void> _delete() async {
    final index = await _readIndex();
    if (index == null) {
      await _storage.delete(key: _legacyEntry);
      return;
    }
    final active = index.active;
    final profiles = [
      for (final item in index.profiles)
        if (item.id != active) item,
    ];
    final unreadable = [
      for (final item in index.unreadable)
        if (active == null || item is! Map || item['id'] != active) item,
    ];
    await _writeIndex(null, profiles, unreadable);
    if (active != null) await _unstage(active);
    await _removeLegacy();
  }

  /// Every readable saved profile, without keys, for the archive picker.
  Future<List<ConnectionProfile>> profiles() =>
      _serialized(() async => (await _readIndex())?.profiles ?? const []);

  Future<void> _migrate(SavedConnection saved) async {
    final profile = (
      id: newProfileId(),
      label: defaultLabel(saved.server),
      serverType: saved.serverType,
      server: saved.server,
      accountId: saved.accountId,
      ownCertificate: false,
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

  Future<void> _removeLegacy() => _deleteQuietly(_legacyEntry);

  Future<void> _removeOrphanKeys(ConnectionIndex index) async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } catch (_) {
      return;
    }
    // IDs of unreadable profiles count too, so their keys and certificates
    // survive for a build that can read them. A readable profile keeps a
    // certificate entry only while the index says it has one.
    final readable = {for (final p in index.profiles) p.id};
    final known = {
      for (final id in index.referencedIds) '$_keyPrefix$id',
      for (final p in index.profiles)
        if (p.ownCertificate) '$_trustPrefix${p.id}',
      for (final id in index.referencedIds)
        if (!readable.contains(id)) '$_trustPrefix$id',
    };
    for (final name in [...all.keys]) {
      if ((name.startsWith(_keyPrefix) || name.startsWith(_trustPrefix)) &&
          !known.contains(name)) {
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

  /// Decodes a v3 (default trust) or v4 (custom trust) index. Profiles that fail validation, or repeat an ID,
  /// are kept aside unchanged in [ConnectionIndex.unreadable] and written
  /// back as they were; an unknown version or shape throws
  /// [FormatException].
  static ConnectionIndex decodeIndex(String text) {
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic> ||
        (data['version'] != currentVersion &&
            data['version'] != certificateIndexVersion)) {
      throw const FormatException('Saved archives version is unknown.');
    }
    final list = data['profiles'];
    final active = data['active'];
    if (list is! List<dynamic> || (active != null && active is! String)) {
      throw const FormatException('Saved archives are unreadable.');
    }
    if (data['version'] == currentVersion &&
        list.any((item) => item is Map && item.containsKey('ownCertificate'))) {
      throw const FormatException(
        'Custom trust requires the newer index format.',
      );
    }
    final profiles = <ConnectionProfile>[];
    final unreadable = <Object?>[];
    final referenced = <String>{};
    final counts = <String, int>{};
    for (final item in list) {
      final id = item is Map ? item['id'] : null;
      if (id is String) counts[id] = (counts[id] ?? 0) + 1;
    }
    for (final item in list) {
      final profile = _decodeProfile(item);
      final rawId = item is Map<String, dynamic> ? item['id'] : null;
      if (rawId is String) referenced.add(rawId);
      if (profile == null || counts[profile.id] != 1) {
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
    // Absent means default trust; any value but true is from a format this
    // build doesn't know, so the profile is kept aside unchanged.
    final own = value.containsKey('ownCertificate')
        ? value['ownCertificate']
        : false;
    if (own is! bool || (value.containsKey('ownCertificate') && !own)) {
      return null;
    }
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
      ownCertificate: own,
    );
  }

  /// Encodes v4 when custom-trust markers exist; otherwise preserves v3.
  static String encodeIndex(
    String? active,
    List<ConnectionProfile> profiles, {
    List<Object?> unreadable = const [],
  }) => jsonEncode({
    'version':
        profiles.any((profile) => profile.ownCertificate) ||
            unreadable.any(
              (item) => item is Map && item.containsKey('ownCertificate'),
            )
        ? certificateIndexVersion
        : currentVersion,
    'active': active,
    'profiles': [
      for (final item in profiles)
        {
          'id': item.id,
          'label': item.label,
          'serverType': item.serverType.id,
          'server': item.server,
          'accountId': item.accountId,
          if (item.ownCertificate) 'ownCertificate': true,
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
        certificate: null,
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
      certificate: null,
    );
  }

  /// Encodes an archive's own certificate record for [serverType] and
  /// [server].
  static String encodeCertificate({
    required ArchiveServerType serverType,
    required String server,
    required List<int> der,
  }) {
    if (der.isEmpty || der.length > certificateImportByteLimit) {
      throw ArgumentError('Certificate size is out of range.');
    }
    return jsonEncode({
      'version': trustVersion,
      'serverType': serverType.id,
      'server': server,
      'der': base64.encode(der),
      'sha256': _sha256Hex(der),
    });
  }

  /// Decodes a certificate record and checks it belongs to [serverType] and
  /// [server] and still matches its fingerprint. Throws
  /// [SavedCertificateUnavailable] otherwise; never returns default trust.
  static List<int> decodeCertificate(
    String text, {
    required ArchiveServerType serverType,
    required String server,
  }) {
    const damaged = SavedCertificateUnavailable(
      'Saved certificate is damaged.',
    );
    if (text.length > 128 * 1024) throw damaged;
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      throw damaged;
    }
    if (data is! Map<String, dynamic>) throw damaged;
    if (data['version'] != trustVersion) {
      throw const SavedCertificateUnavailable(
        'Saved certificate needs a newer version of MailBurrow.',
      );
    }
    if (data['serverType'] != serverType.id || data['server'] != server) {
      throw const SavedCertificateUnavailable(
        'Saved certificate belongs to a different server.',
      );
    }
    final encoded = data['der'], sha256 = data['sha256'];
    if (encoded is! String ||
        sha256 is! String ||
        encoded.length > ((certificateImportByteLimit + 2) ~/ 3) * 4 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw damaged;
    }
    final List<int> der;
    try {
      der = base64.decode(encoded);
    } on FormatException {
      throw damaged;
    }
    if (der.isEmpty ||
        der.length > certificateImportByteLimit ||
        _sha256Hex(der) != sha256) {
      throw damaged;
    }
    return List.unmodifiable(der);
  }

  static String _sha256Hex(List<int> der) => SHA256Digest()
      .process(Uint8List.fromList(der))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

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

  /// Every text profile ID in the index, readable or not.
  final Set<String> referencedIds;
}
