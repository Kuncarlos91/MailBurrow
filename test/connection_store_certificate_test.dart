import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/state/connection_store.dart';

/// In-memory secure storage that can refuse chosen writes.
class Entries extends SecureEntries {
  final values = <String, String>{};
  bool Function(String key)? failWrite;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> delete({required String key}) async => values.remove(key);
  @override
  Future<void> write({required String key, required String value}) async {
    if (failWrite?.call(key) ?? false) throw Exception('write refused');
    values[key] = value;
  }

  Iterable<String> named(String prefix) =>
      values.keys.where((k) => k.startsWith(prefix));
  Map<String, dynamic> get index =>
      jsonDecode(values['connections']!) as Map<String, dynamic>;
  List<Map<String, dynamic>> get profiles => [
    for (final p in index['profiles'] as List) p as Map<String, dynamic>,
  ];
}

const server = 'https://archive.example';
const other = 'https://other.example';
const mailArchiver = ArchiveServerType.mailArchiver;

// Opaque test bytes: storage never parses the certificate itself.
final certA = List<int>.generate(300, (i) => i % 251);
final certB = List<int>.generate(320, (i) => (i * 7) % 253);

void main() {
  late Entries entries;
  late ConnectionStore store;

  setUp(() {
    entries = Entries();
    store = ConnectionStore(entries: entries);
  });

  Future<String> addWith(List<int>? der, {String srv = server}) => store.add(
    serverType: mailArchiver,
    server: srv,
    key: 'key-1',
    accountId: '1',
    certificate: der == null
        ? const CertificateChange.keep()
        : CertificateChange.set(der),
  );

  group('saving', () {
    test('an archive with a certificate stores and reads it back', () async {
      final id = await addWith(certA);
      expect((await store.read())!.certificate, certA);
      expect((await store.connection(id)).certificate, certA);
      expect(entries.profiles.single['ownCertificate'], isTrue);
      final record =
          jsonDecode(entries.values['connection.trust.$id']!)
              as Map<String, dynamic>;
      expect(record['version'], 1);
      expect(record['serverType'], mailArchiver.id);
      expect(record['server'], server);
      expect(base64.decode(record['der'] as String), certA);
      expect(record['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect((await store.overview()).profiles.single.ownCertificate, isTrue);
    });

    test('an archive without one keeps the existing format', () async {
      await addWith(null);
      expect((await store.read())!.certificate, isNull);
      expect(entries.profiles.single.containsKey('ownCertificate'), isFalse);
      expect(entries.named('connection.trust.'), isEmpty);
    });

    test('an account-only change keeps the certificate and ID', () async {
      final id = await addWith(certA);
      final again = await store.write(
        serverType: mailArchiver,
        server: server,
        key: 'key-1',
        accountId: '2',
        profileId: id,
      );
      expect(again, id);
      expect((await store.read())!.certificate, certA);
      expect((await store.read())!.accountId, '2');
    });

    test('a new key for the same server keeps the certificate', () async {
      final id = await addWith(certA);
      final moved = await store.write(
        serverType: mailArchiver,
        server: server,
        key: 'key-2',
        accountId: '1',
        profileId: id,
      );
      expect(moved, isNot(id));
      expect((await store.read())!.certificate, certA);
      expect(entries.named('connection.trust.'), ['connection.trust.$moved']);
      expect(entries.named('connection.key.'), ['connection.key.$moved']);
    });

    test('a changed address or server type never inherits it', () async {
      final id = await addWith(certA);
      await store.write(
        serverType: mailArchiver,
        server: other,
        key: 'key-1',
        accountId: '1',
        profileId: id,
      );
      expect((await store.read())!.certificate, isNull);
      expect(entries.named('connection.trust.'), isEmpty);

      final second = await addWith(certA);
      await store.write(
        serverType: ArchiveServerType.openArchiver,
        server: server,
        key: 'key-1',
        accountId: '1',
        profileId: second,
      );
      expect((await store.read())!.certificate, isNull);
    });

    test('another server type on the same address starts without it', () async {
      await addWith(certA);
      await store.add(
        serverType: ArchiveServerType.bichon,
        server: server,
        key: 'key-b',
        accountId: null,
      );
      expect((await store.read())!.certificate, isNull);
      expect(entries.named('connection.trust.'), hasLength(1));
    });
  });

  group('replace and remove', () {
    test(
      'replacing stages a new record and keeps the archive active',
      () async {
        final id = await addWith(certA);
        final replaced = await store.setCertificate(id, certB);
        expect(replaced, isNot(id));
        expect(entries.index['active'], replaced);
        expect((await store.read())!.certificate, certB);
        expect(entries.named('connection.trust.'), [
          'connection.trust.$replaced',
        ]);
        expect((await store.read())!.key, 'key-1');
      },
    );

    test('replacing an inactive archive leaves the active one', () async {
      final first = await addWith(certA);
      final second = await addWith(null, srv: other);
      expect(entries.index['active'], second);
      final replaced = await store.setCertificate(first, certB);
      expect(entries.index['active'], second);
      expect((await store.connection(replaced)).certificate, certB);
    });

    test('removing goes back to default trust', () async {
      final id = await addWith(certA);
      final removed = await store.setCertificate(id, null);
      expect((await store.read())!.certificate, isNull);
      expect(entries.named('connection.trust.'), isEmpty);
      expect(entries.profiles.single.containsKey('ownCertificate'), isFalse);
      expect(await store.connection(removed), isNotNull);
    });

    test('a failed certificate write keeps the old record working', () async {
      final id = await addWith(certA);
      final before = Map.of(entries.values);
      entries.failWrite = (k) => k.startsWith('connection.trust.');
      await expectLater(store.setCertificate(id, certB), throwsException);
      expect(entries.values, before);
      expect((await store.read())!.certificate, certA);
    });

    test('a failed index write removes everything it staged', () async {
      final id = await addWith(certA);
      final before = Map.of(entries.values);
      entries.failWrite = (k) => k == 'connections';
      await expectLater(store.setCertificate(id, certB), throwsException);
      expect(entries.values, before);
      expect((await store.read())!.certificate, certA);
    });

    test('a failed add leaves nothing behind', () async {
      entries.failWrite = (k) => k == 'connections';
      await expectLater(addWith(certA), throwsException);
      expect(entries.values, isEmpty);
    });

    test('setCertificate on an unknown archive fails', () async {
      await expectLater(
        store.setCertificate('0' * 32, certA),
        throwsA(isA<SavedArchiveMissing>()),
      );
    });
  });

  group('forgetting', () {
    test('forget, delete and reset remove certificate entries', () async {
      final a = await addWith(certA);
      await addWith(certB, srv: other);
      await store.forget(a);
      expect(entries.named('connection.trust.'), hasLength(1));
      await store.delete();
      expect(entries.named('connection.trust.'), isEmpty);

      await addWith(certA);
      await addWith(certB, srv: other);
      await store.reset();
      expect(entries.values, isEmpty);
    });

    test('a stray certificate entry is cleaned up on read', () async {
      final id = await addWith(null);
      entries.values['connection.trust.$id'] = 'left over';
      entries.values['connection.trust.${'f' * 32}'] = 'orphan';
      await store.read();
      expect(entries.named('connection.trust.'), isEmpty);
    });
  });

  group('fails closed', () {
    Future<void> expectUnavailable(String id, String message) async {
      final before = Map.of(entries.values);
      await expectLater(
        store.read(),
        throwsA(
          isA<SavedCertificateUnavailable>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
      await expectLater(
        store.connection(id),
        throwsA(isA<SavedCertificateUnavailable>()),
      );
      // Nothing is repaired, removed or downgraded to default trust.
      expect(entries.values, before);
    }

    Map<String, dynamic> record(String id) =>
        jsonDecode(entries.values['connection.trust.$id']!)
            as Map<String, dynamic>;
    void put(String id, Map<String, dynamic> value) =>
        entries.values['connection.trust.$id'] = jsonEncode(value);

    test('a missing record', () async {
      final id = await addWith(certA);
      entries.values.remove('connection.trust.$id');
      await expectUnavailable(id, 'Saved certificate is missing.');
    });

    test('a record from a newer version', () async {
      final id = await addWith(certA);
      put(id, {...record(id), 'version': 2});
      await expectUnavailable(
        id,
        'Saved certificate needs a newer version of MailBurrow.',
      );
    });

    test('a record for another server', () async {
      final id = await addWith(certA);
      put(id, {...record(id), 'server': other});
      await expectUnavailable(
        id,
        'Saved certificate belongs to a different server.',
      );
    });

    test('a record whose bytes no longer match its fingerprint', () async {
      final id = await addWith(certA);
      put(id, {...record(id), 'der': base64.encode(certB)});
      await expectUnavailable(id, 'Saved certificate is damaged.');
      entries.values['connection.trust.$id'] = 'not json';
      await expectUnavailable(id, 'Saved certificate is damaged.');
    });

    test(
      'changing the key of an archive with a damaged record stops',
      () async {
        final id = await addWith(certA);
        entries.values['connection.trust.$id'] = 'not json';
        final before = Map.of(entries.values);
        await expectLater(
          store.write(
            serverType: mailArchiver,
            server: server,
            key: 'key-2',
            accountId: '1',
            profileId: id,
          ),
          throwsA(isA<SavedCertificateUnavailable>()),
        );
        expect(entries.values, before);
      },
    );

    test(
      'an unknown certificate flag keeps the profile aside, untouched',
      () async {
        final id = await addWith(certA);
        final index = entries.index;
        final profile = Map<String, dynamic>.of(entries.profiles.single)
          ..['ownCertificate'] = 'v2';
        entries.values['connections'] = jsonEncode({
          ...index,
          'profiles': [profile],
        });
        final overview = await store.overview();
        expect(overview.profiles, isEmpty);
        await store.read().catchError((_) => null);
        // Its key and certificate survive for a build that understands them.
        expect(entries.values.containsKey('connection.key.$id'), isTrue);
        expect(entries.values.containsKey('connection.trust.$id'), isTrue);
        await addWith(null, srv: other);
        // Writing another archive keeps it exactly as it was.
        expect(entries.profiles, contains(equals(profile)));
        expect(entries.profiles, hasLength(2));
      },
    );
  });

  test('records outside the size limit are refused', () {
    expect(
      () => ConnectionStore.encodeCertificate(
        serverType: mailArchiver,
        server: server,
        der: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => ConnectionStore.encodeCertificate(
        serverType: mailArchiver,
        server: server,
        der: List.filled(64 * 1024 + 1, 1),
      ),
      throwsArgumentError,
    );
  });
}
