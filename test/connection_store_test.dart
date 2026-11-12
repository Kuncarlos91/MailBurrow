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
    test('round-trips numeric and text account IDs as text', () {
      for (final (input, stored) in [
        (7, '7'),
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

  test('write stores version 2 and read returns it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = ConnectionStore();
    expect(await store.read(), isNull);
    await store.write(
      serverType: ArchiveServerType.mailArchiver,
      server: 'https://a.example',
      key: 'k',
      accountId: 3,
    );
    final raw = await const FlutterSecureStorage().read(key: 'connection');
    expect(jsonDecode(raw!)['version'], 2);
    final saved = await store.read();
    expect(saved?.accountId, '3');
    await store.delete();
    expect(await store.read(), isNull);
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
