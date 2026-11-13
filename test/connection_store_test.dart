import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/state/connection_store.dart';

String v1(Map<String, Object?> data) => jsonEncode(data);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('version 1 (0.3.0-rc.9 and earlier)', () {
    test('reads as Mail-Archiver with the account ID as text', () {
      final saved = ConnectionStore.decode(
        v1({'server': 'https://a.example', 'key': 'test-only', 'accountId': 7}),
      );
      expect(saved.serverType, ArchiveServerType.mailArchiver);
      expect(saved.server, 'https://a.example');
      expect(saved.key, 'test-only');
      expect(saved.accountId, '7');
    });

    test('keeps a missing or non-numeric account as none', () {
      for (final id in [null, 'x', 1.5, true]) {
        final saved = ConnectionStore.decode(
          v1({'server': 'https://a.example', 'key': 'k', 'accountId': id}),
        );
        expect(saved.accountId, isNull, reason: '$id');
      }
      expect(
        ConnectionStore.decode(v1({'server': 'https://a.example', 'key': 'k'}))
            .accountId,
        isNull,
      );
    });
  });

  group('version 2', () {
    test('round-trips numeric-looking and UUID account IDs as text', () {
      for (final (input, stored) in <(String?, String?)>[
        ('7', '7'),
        (
          'aaaaaaaa-0000-4000-8000-000000000001',
          'aaaaaaaa-0000-4000-8000-000000000001',
        ),
        (null, null),
      ]) {
        final encoded = ConnectionStore.encode(
          serverType: ArchiveServerType.mailArchiver,
          server: 'https://a.example',
          key: 'k',
          accountId: input,
        );
        expect(jsonDecode(encoded), {
          'version': 2,
          'serverType': 'mail-archiver',
          'server': 'https://a.example',
          'key': 'k',
          'accountId': stored,
        });
        final saved = ConnectionStore.decode(encoded);
        expect(saved.serverType, ArchiveServerType.mailArchiver);
        expect(saved.accountId, stored);
      }
    });

    test('rejects unknown versions and server types instead of guessing', () {
      Map<String, Object?> base() => {
        'version': 2,
        'serverType': 'mail-archiver',
        'server': 'https://a.example',
        'key': 'k',
        'accountId': '1',
      };
      final broken = <Map<String, Object?>>[
        base()..['version'] = 3,
        base()..['version'] = '2',
        base()..['version'] = null,
        base()..remove('version'),
        base()
          ..remove('version')
          ..['serverType'] = 'some-future-server',
        base()
          ..remove('version')
          ..['serverType'] = null,
        (base()..['version'] = null)..remove('serverType'),
        base()..['serverType'] = 'some-future-server',
        base()..remove('serverType'),
        base()..['accountId'] = 1,
        base()..remove('key'),
        base()..['server'] = 5,
      ];
      for (final data in broken) {
        expect(
          () => ConnectionStore.decode(jsonEncode(data)),
          throwsFormatException,
          reason: '$data',
        );
      }
      expect(() => ConnectionStore.decode('[]'), throwsFormatException);
      expect(() => ConnectionStore.decode('not json'), throwsFormatException);
    });
  });

  group('version 3 store', () {
    const storage = FlutterSecureStorage();
    const store = ConnectionStore();
    const first = 'https://a.example';

    Future<Map<String, dynamic>> index() async =>
        jsonDecode((await storage.read(key: 'connections'))!)
            as Map<String, dynamic>;
    Future<Map<String, String>> keyEntries() async => {
      for (final entry in (await storage.readAll()).entries)
        if (entry.key.startsWith('connection.key.')) entry.key: entry.value,
    };

    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('writes an index without keys and one key entry', () async {
      expect(await store.read(), isNull);
      await store.write(
        serverType: ArchiveServerType.openArchiver,
        server: first,
        key: 'secret-one',
        accountId: 'src-1',
      );
      final saved = await index();
      expect(saved['version'], 3);
      expect(jsonEncode(saved), isNot(contains('secret-one')));
      final profile = (saved['profiles'] as List).single as Map;
      expect(saved['active'], profile['id']);
      expect(profile['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(profile['label'], 'a.example');
      expect(profile['serverType'], 'open-archiver');
      expect(await keyEntries(), {'connection.key.${profile['id']}': 'secret-one'});
      final read = await store.read();
      expect(read?.serverType, ArchiveServerType.openArchiver);
      expect(read?.key, 'secret-one');
      expect(read?.accountId, 'src-1');
      expect(await storage.read(key: 'connection'), isNull);
    });

    test('an account change keeps the profile; a key change restages it', () async {
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'k1', accountId: '1');
      final id = (await index())['active'];
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'k1', accountId: '2');
      expect((await index())['active'], id);
      expect((await store.read())?.accountId, '2');
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'k2', accountId: '2');
      final next = (await index())['active'];
      expect(next, isNot(id));
      expect(await keyEntries(), {'connection.key.$next': 'k2'});
      expect(((await index())['profiles'] as List), hasLength(1));
    });

    for (final (label, legacy, account) in [
      ('version 2', ConnectionStore.encode(serverType: ArchiveServerType.openArchiver, server: first, key: 'k', accountId: 'src'), 'src'),
      ('version 1', jsonEncode({'server': first, 'key': 'k', 'accountId': 7}), '7'),
    ]) {
      test('migrates a $label record once, then removes it', () async {
        FlutterSecureStorage.setMockInitialValues({'connection': legacy});
        final saved = await store.read();
        expect(saved?.key, 'k');
        expect(saved?.accountId, account);
        expect(await storage.read(key: 'connection'), isNull);
        final id = (await index())['active'];
        expect((await store.read())?.key, 'k');
        expect((await index())['active'], id);
        expect(await keyEntries(), hasLength(1));
      });
    }

    test('leaves an unreadable legacy record untouched', () async {
      const broken = '{"version": 9, "server": "x", "key": "k"}';
      FlutterSecureStorage.setMockInitialValues({'connection': broken});
      await expectLater(store.read(), throwsFormatException);
      expect(await storage.read(key: 'connection'), broken);
      expect(await storage.read(key: 'connections'), isNull);
    });

    test('a failed migration keeps the legacy record and no stray key', () async {
      final legacy = ConnectionStore.encode(serverType: ArchiveServerType.mailArchiver, server: first, key: 'k', accountId: null);
      FlutterSecureStorage.setMockInitialValues({'connection': legacy});
      final failing = ConnectionStore(entries: FailingEntries({'connections'}));
      expect((await failing.read())?.key, 'k');
      expect(await storage.read(key: 'connection'), legacy);
      expect(await keyEntries(), isEmpty);
    });

    test('a failed replacement keeps the working profile and key', () async {
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'old', accountId: '1');
      final failing = ConnectionStore(entries: FailingEntries({'connections'}));
      await expectLater(
        failing.write(serverType: ArchiveServerType.openArchiver, server: 'https://b.example', key: 'new', accountId: null),
        throwsA(isA<StateError>()),
      );
      final saved = await store.read();
      expect(saved?.key, 'old');
      expect(saved?.server, first);
      expect(await keyEntries(), hasLength(1));
    });

    test('the index wins over a leftover legacy record', () async {
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'new', accountId: null);
      await storage.write(
        key: 'connection',
        value: ConnectionStore.encode(serverType: ArchiveServerType.mailArchiver, server: 'https://old.example', key: 'old', accountId: null),
      );
      expect((await store.read())?.key, 'new');
      expect(await storage.read(key: 'connection'), isNull);
    });

    test('keeps unreadable profiles and their keys, removes orphans', () async {
      final known = ConnectionStore.newProfileId();
      final future = ConnectionStore.newProfileId();
      FlutterSecureStorage.setMockInitialValues({
        'connections': jsonEncode({
          'version': 3,
          'active': known,
          'profiles': [
            {'id': known, 'label': 'Home', 'serverType': 'mail-archiver', 'server': first, 'accountId': null},
            {'id': future, 'label': 'Later', 'serverType': 'some-future-server', 'server': first},
          ],
        }),
        'connection.key.$known': 'k-known',
        'connection.key.$future': 'k-future',
        'connection.key.${ConnectionStore.newProfileId()}': 'orphan',
      });
      expect((await store.read())?.key, 'k-known');
      expect(await keyEntries(), hasLength(2));
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'k-known', accountId: '5');
      final profiles = (await index())['profiles'] as List;
      expect(profiles, hasLength(2));
      expect(profiles.last['serverType'], 'some-future-server');
      expect((await store.profiles()).map((item) => item.label), ['Home']);
    });

    test('forgetting removes only the active profile', () async {
      final other = ConnectionStore.newProfileId();
      await store.write(serverType: ArchiveServerType.mailArchiver, server: first, key: 'active', accountId: null);
      final active = (await index())['active'] as String;
      final saved = await index();
      (saved['profiles'] as List).add({'id': other, 'label': 'Other', 'serverType': 'open-archiver', 'server': 'https://b.example', 'accountId': null});
      await storage.write(key: 'connections', value: jsonEncode(saved));
      await storage.write(key: 'connection.key.$other', value: 'other');
      await store.delete();
      expect(await store.read(), isNull);
      expect((await index())['active'], isNull);
      expect(await keyEntries(), {'connection.key.$other': 'other'});
      expect(await storage.read(key: 'connection.key.$active'), isNull);
    });

    test('forgetting an unreadable index clears it and every key', () async {
      FlutterSecureStorage.setMockInitialValues({
        'connections': '{"version": 99}',
        'connection.key.${ConnectionStore.newProfileId()}': 'k',
        'connection': '{}',
      });
      await expectLater(store.read(), throwsFormatException);
      await store.delete();
      expect(await storage.readAll(), isEmpty);
    });

    test('rejects an active profile that is unreadable or has no key', () async {
      final id = ConnectionStore.newProfileId();
      String index(Map<String, Object?> profile) => jsonEncode({
        'version': 3,
        'active': id,
        'profiles': [profile],
      });
      for (final values in <Map<String, String>>[
        {'connections': index({'id': id, 'label': 'x', 'serverType': 'nope', 'server': first})},
        {'connections': index({'id': id, 'label': 'x', 'serverType': 'mail-archiver', 'server': first})},
        {'connections': jsonEncode({'version': 2, 'profiles': []})},
        {'connections': jsonEncode({'version': 3, 'active': 5, 'profiles': []})},
      ]) {
        FlutterSecureStorage.setMockInitialValues(values);
        await expectLater(store.read(), throwsFormatException, reason: '$values');
      }
    });

    test('labels default to the host and IDs are random', () {
      expect(ConnectionStore.defaultLabel('https://mail.example:8443/archive'), 'mail.example');
      expect(ConnectionStore.defaultLabel('https://${'a' * 70}.example').length, 60);
      final ids = {for (var i = 0; i < 50; i++) ConnectionStore.newProfileId()};
      expect(ids, hasLength(50));
    });
  });

  test('server type IDs are stable', () {
    expect(ArchiveServerType.mailArchiver.id, 'mail-archiver');
    expect(
      ArchiveServerType.fromId('mail-archiver'),
      ArchiveServerType.mailArchiver,
    );
    expect(ArchiveServerType.fromId('Mail-Archiver'), isNull);
    expect(ArchiveServerType.fromId(null), isNull);
  });
}

/// Secure storage that fails writes to the named entries.
class FailingEntries extends SecureEntries {
  FailingEntries(this.failing);
  final Set<String> failing;

  @override
  Future<void> write({required String key, required String value}) async {
    if (failing.contains(key)) throw StateError('write failed');
    return super.write(key: key, value: value);
  }
}
