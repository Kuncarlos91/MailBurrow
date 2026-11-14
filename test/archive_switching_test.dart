import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';

const storage = FlutterSecureStorage();
const store = ConnectionStore();
const first = 'https://a.example';
const second = 'https://b.example';

/// Synthetic archive whose mail names its server, with the same account and
/// message IDs on every server.
class HostArchive extends FakeArchiveBackend {
  HostArchive(super.server, super.key);
  bool offline = false;
  bool closed = false;
  Completer<void>? holdAccounts;

  String get host => server.host;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    await holdAccounts?.future;
    if (offline) throw const SocketException('offline');
    return [
      ArchiveAccount(id: '1', emailAddress: 'one@$host'),
      ArchiveAccount(id: '2', emailAddress: 'two@$host'),
    ];
  }

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => [
    ArchiveFolder('Inbox', 'INBOX', 1, 0),
  ];

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => MailPage(
    items: [MailSummary(id: '1', subject: '$host account $accountId')],
  );

  @override
  void close() => closed = true;
}

Future<Map<String, dynamic>> savedIndex() async =>
    jsonDecode((await storage.read(key: 'connections'))!)
        as Map<String, dynamic>;

Future<Map<String, String>> keyEntries() async => {
  for (final entry in (await storage.readAll()).entries)
    if (entry.key.startsWith('connection.key.')) entry.key: entry.value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('store', () {
    test('add keeps other archives and makes the new one active', () async {
      final a = await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'key-a',
        accountId: '1',
      );
      final b = await store.add(
        serverType: ArchiveServerType.openArchiver,
        server: second,
        key: 'key-b',
        accountId: null,
      );
      expect(a, isNot(b));
      final index = await savedIndex();
      expect(index['active'], b);
      expect(index['profiles'], hasLength(2));
      expect(jsonEncode(index), isNot(contains('key-')));
      expect((await store.read())?.key, 'key-b');
      expect((await store.connection(a)).key, 'key-a');
      // Reading one archive's credentials does not change the active one.
      expect((await savedIndex())['active'], b);
      final overview = await store.overview();
      expect(overview.unreadable, isFalse);
      expect(overview.active, b);
      expect(overview.profiles.map((item) => item.label), [
        'a.example',
        'b.example',
      ]);
    });

    test('adding the same type and address again re-keys that archive', () async {
      final a = await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'old',
        accountId: '1',
      );
      final again = await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'new',
        accountId: '2',
      );
      expect(again, isNot(a));
      expect(await keyEntries(), {'connection.key.$again': 'new'});
      // A different type at the same address is a different archive.
      await store.add(
        serverType: ArchiveServerType.openArchiver,
        server: first,
        key: 'other',
        accountId: null,
      );
      expect((await savedIndex())['profiles'], hasLength(2));
    });

    test('write with a profile ID updates and activates only that archive', () async {
      final a = await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'key-a',
        accountId: '1',
      );
      final b = await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: second,
        key: 'key-b',
        accountId: '1',
      );
      final written = await store.write(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'key-a',
        accountId: '2',
        profileId: a,
      );
      expect(written, a);
      final index = await savedIndex();
      expect(index['active'], a);
      expect((await store.connection(b)).accountId, '1');
      expect((await store.connection(a)).accountId, '2');
      await expectLater(
        store.write(
          serverType: ArchiveServerType.mailArchiver,
          server: first,
          key: 'k',
          accountId: null,
          profileId: ConnectionStore.newProfileId(),
        ),
        throwsA(isA<SavedArchiveMissing>()),
      );
    });

    test('add refuses more than the archive limit', () async {
      for (var i = 0; i < ConnectionStore.maxProfiles; i++) {
        await store.add(
          serverType: ArchiveServerType.mailArchiver,
          server: 'https://n$i.example',
          key: 'k$i',
          accountId: null,
        );
      }
      await expectLater(
        store.add(
          serverType: ArchiveServerType.mailArchiver,
          server: 'https://extra.example',
          key: 'k',
          accountId: null,
        ),
        throwsA(isA<TooManySavedArchives>()),
      );
      expect((await savedIndex())['profiles'], hasLength(ConnectionStore.maxProfiles));
    });

    test('an unreadable index is reported and blocks add', () async {
      FlutterSecureStorage.setMockInitialValues({'connections': '{broken'});
      expect((await store.overview()).unreadable, isTrue);
      await expectLater(
        store.add(
          serverType: ArchiveServerType.mailArchiver,
          server: first,
          key: 'k',
          accountId: null,
        ),
        throwsFormatException,
      );
      expect(await storage.read(key: 'connections'), '{broken');
    });

    test('reset removes every saved archive, key and legacy record only', () async {
      final values = {
        'connections': '{"version":99}',
        'connection.key.${ConnectionStore.newProfileId()}': 'one',
        'connection.key.${ConnectionStore.newProfileId()}': 'two',
        'connection': '{}',
        'unrelated': 'kept',
      };
      FlutterSecureStorage.setMockInitialValues(values);
      await store.reset();
      expect(await storage.readAll(), {'unrelated': 'kept'});
      final overview = await store.overview();
      expect(overview.unreadable, isFalse);
      expect(overview.profiles, isEmpty);
    });
  });

  group('session', () {
    late List<HostArchive> created;
    late ArchiveSession session;
    Completer<void>? hold;

    ArchiveSession newSession() => ArchiveSession(
      backendFactory: (type, server, key) {
        final api = HostArchive(server, key)..holdAccounts = hold;
        created.add(api);
        return api;
      },
    );

    Future<void> add(String server, String key) async {
      session.openSetup();
      session.server.text = server;
      session.keyInput.text = key;
      await session.connect();
    }

    setUp(() {
      created = [];
      hold = null;
      session = newSession();
    });
    tearDown(() => session.dispose());

    test('adding a second archive keeps the first and switches back', () async {
      await session.restore();
      await add(first, 'key-a');
      await session.switchAccount(
        (await session.api!.accounts()).firstWhere((item) => item.id == '2'),
      );
      await add(second, 'key-b');
      expect(session.archives, hasLength(2));
      expect(session.activeArchive?.label, 'b.example');
      expect(session.messages.single.subject, 'b.example account 1');
      final a = session.archives.first;
      final b = session.archives.last;
      final previous = session.api as HostArchive;
      await session.switchArchive(a.id);
      expect(previous.closed, isTrue);
      expect(session.activeArchiveId, a.id);
      expect(session.account?.id, '2', reason: 'remembered per archive');
      expect(session.messages.single.subject, 'a.example account 2');
      expect((session.api as HostArchive).key, 'key-a');
      expect((await store.read())?.server, first);
      await session.switchArchive(b.id);
      expect(session.account?.id, '1');
      expect((session.api as HostArchive).key, 'key-b');
    });

    test('switching clears the old archive before the new one answers', () async {
      await session.restore();
      await add(first, 'key-a');
      await add(second, 'key-b');
      final a = session.archives.first;
      session.search.text = 'leftover';
      await session.applyFilters(const SearchFilters());
      final gate = hold = Completer<void>();
      final switching = session.switchArchive(a.id);
      expect(session.switchingArchive?.id, a.id);
      expect(session.messages, isEmpty);
      expect(session.account, isNull);
      expect(session.api, isNull);
      expect(session.search.text, isEmpty);
      expect(session.canSwitchArchive, isFalse);
      await pumpEventQueue();
      expect(session.messages, isEmpty, reason: 'still waiting for a.example');
      gate.complete();
      await switching;
      expect(session.switchingArchive, isNull);
      expect(session.messages.single.subject, startsWith('a.example'));
    });

    test('a failed switch names the destination and keeps both archives', () async {
      await session.restore();
      await add(first, 'key-a');
      await add(second, 'key-b');
      final a = session.archives.first;
      final b = session.archives.last;
      await session.switchArchive(a.id);
      final factory = created.length;
      session.dispose();
      session = ArchiveSession(
        backendFactory: (type, server, key) {
          final api = HostArchive(server, key)..offline = server.host == 'b.example';
          created.add(api);
          return api;
        },
      );
      await session.restore();
      expect(session.activeArchiveId, a.id);
      await session.switchArchive(b.id);
      expect(created.length, greaterThan(factory));
      expect(created.last.closed, isTrue, reason: 'failed candidate closed');
      expect(session.setup, isTrue);
      expect(session.api, isNull);
      expect(session.messages, isEmpty);
      expect(session.error, startsWith('Could not open b.example (Mail-Archiver).'));
      expect(session.archives, hasLength(2));
      // The working archive stays active for the next start.
      expect((await store.read())?.server, first);
      expect((await savedIndex())['active'], a.id);
      // Retry targets the failed destination, and switching back works.
      final before = created.length;
      await session.retrySaved();
      expect(created.length, before + 1);
      expect(created.last.server.host, 'b.example');
      await session.switchArchive(a.id);
      expect(session.messages.single.subject, startsWith('a.example'));
      expect((session.api as HostArchive).key, 'key-a');
    });

    test('forgetting the active archive keeps the other without opening it', () async {
      await session.restore();
      await add(first, 'key-a');
      await add(second, 'key-b');
      final count = created.length;
      await session.forgetConnection();
      expect(session.setup, isTrue);
      expect(session.api, isNull);
      expect(created.length, count, reason: 'nothing reconnects');
      expect(session.archives.single.label, 'a.example');
      expect(await store.read(), isNull);
    });

    test('demo entry and exit keep saved archives and reconnect nothing', () async {
      await session.restore();
      await add(first, 'key-a');
      await add(second, 'key-b');
      session.dispose();
      session = ArchiveSession(
        backendFactory: (type, server, key) =>
            throw StateError('no connection expected'),
        demoLoader: () async => HostArchive(Uri.parse('https://demo.example'), ''),
      );
      await session.startDemo();
      expect(session.canSwitchArchive, isFalse);
      expect(session.activeArchive, isNull);
      session.exitDemo();
      expect(session.setup, isTrue);
    });

    test('the reset is offered only for an unreadable index', () async {
      FlutterSecureStorage.setMockInitialValues({
        'connections': '{"version":99}',
        'connection.key.${ConnectionStore.newProfileId()}': 'kept',
      });
      await session.restore();
      expect(session.savedArchivesUnreadable, isTrue);
      expect(session.error, contains('cannot be read'));
      await add(first, 'key-a');
      expect(session.api, isNull, reason: 'connect cannot overwrite it');
      expect(await keyEntries(), hasLength(1));
      await session.resetSavedArchives();
      expect(session.savedArchivesUnreadable, isFalse);
      expect(await storage.readAll(), isEmpty);
      await add(first, 'key-a');
      expect(session.api, isNotNull);
      // A readable store never offers or performs the reset.
      await session.resetSavedArchives();
      expect(await keyEntries(), hasLength(1));
    });
  });

  group('screens', () {
    Future<void> seedTwo() async {
      await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: first,
        key: 'key-a',
        accountId: '1',
      );
      await store.add(
        serverType: ArchiveServerType.openArchiver,
        server: second,
        key: 'key-b',
        accountId: '1',
      );
    }

    testWidgets('the archive label opens the picker and switches', (tester) async {
      await tester.runAsync(seedTwo);
      await tester.pumpWidget(
        MaterialApp(
          home: ArchiveHome(apiFactory: (server, key) => HostArchive(server, key)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('b.example account 1'), findsOneWidget);
      final label = find.byKey(const ValueKey('current-archive'));
      expect(
        find.descendant(of: label, matching: find.text('Open Archiver · b.example')),
        findsOneWidget,
      );
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(find.text('Archives'), findsOneWidget);
      expect(find.text('Add archive'), findsOneWidget);
      expect(find.text('Mail-Archiver · a.example'), findsOneWidget);
      await tester.tap(find.text('a.example').last);
      await tester.pumpAndSettle();
      expect(find.text('a.example account 1'), findsOneWidget);
      expect(find.text('b.example account 1'), findsNothing);
    });

    testWidgets('Add archive opens setup and Cancel keeps the archive', (tester) async {
      await tester.runAsync(seedTwo);
      await tester.pumpWidget(
        MaterialApp(
          home: ArchiveHome(apiFactory: (server, key) => HostArchive(server, key)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('current-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add archive'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to archive'), findsOneWidget);
      expect(find.text('Saved archives'), findsNothing);
      await tester.scrollUntilVisible(find.text('Cancel'), 200);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('b.example account 1'), findsOneWidget);
    });

    testWidgets('setup lists saved archives when none is open', (tester) async {
      await tester.runAsync(() async {
        await seedTwo();
        await store.delete();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ArchiveHome(apiFactory: (server, key) => HostArchive(server, key)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved archives'), findsOneWidget);
      expect(find.text('Mail-Archiver · a.example'), findsOneWidget);
      expect(find.text('Retry saved connection'), findsNothing);
      await tester.tap(find.text('Mail-Archiver · a.example'));
      await tester.pumpAndSettle();
      expect(find.text('a.example account 1'), findsOneWidget);
    });

    testWidgets('the reset needs confirmation', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'connections': '{broken',
        'connection.key.${ConnectionStore.newProfileId()}': 'kept',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ArchiveHome(apiFactory: (server, key) => HostArchive(server, key)),
        ),
      );
      await tester.pumpAndSettle();
      final reset = find.text('Remove all saved archives…');
      expect(reset, findsOneWidget);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(find.text('Remove all saved archives?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(keyEntries), hasLength(1));
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove all'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(storage.readAll), isEmpty);
      expect(find.text('Remove all saved archives…'), findsNothing);
    });
  });
}
