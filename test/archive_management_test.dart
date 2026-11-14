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

/// Synthetic archive whose mail names its server; servers listed in
/// [offlineHosts] refuse every request.
class HostArchive extends FakeArchiveBackend {
  HostArchive(super.server, super.key);
  static final offlineHosts = <String>{};
  bool closed = false;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (offlineHosts.contains(server.host)) {
      throw const SocketException('offline');
    }
    return [ArchiveAccount(id: '1', emailAddress: 'one@${server.host}')];
  }

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => [];

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => MailPage(
    items: [MailSummary(id: '1', subject: '${server.host} mail')],
  );

  @override
  void close() => closed = true;
}

Future<Map<String, String>> keyEntries() async => {
  for (final entry in (await storage.readAll()).entries)
    if (entry.key.startsWith('connection.key.')) entry.key: entry.value,
};

Future<(String, String)> seedTwo() async {
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
    accountId: '1',
  );
  return (a, b);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    HostArchive.offlineHosts.clear();
  });

  group('store', () {
    test('rename changes only the label', () async {
      final (a, b) = await seedTwo();
      await store.rename(a, '  Family\narchive  ');
      final overview = await store.overview();
      expect(overview.profiles.first.label, 'Family archive');
      expect(overview.profiles.first.server, first);
      expect(overview.active, b);
      expect((await store.connection(a)).key, 'key-a');
      await store.rename(a, '   ');
      expect((await store.overview()).profiles.first.label, 'a.example');
      await expectLater(
        store.rename(ConnectionStore.newProfileId(), 'x'),
        throwsA(isA<SavedArchiveMissing>()),
      );
    });

    test('labels are cut without splitting a character', () {
      final long = '${'a' * 59}😀';
      final cleaned = ConnectionStore.cleanLabel(long, first);
      expect(cleaned, 'a' * 59);
      expect(ConnectionStore.cleanLabel('b' * 80, first), 'b' * 60);
    });

    test('forget removes one archive and its key', () async {
      final (a, b) = await seedTwo();
      await store.forget(a);
      final overview = await store.overview();
      expect(overview.profiles.map((item) => item.id), [b]);
      expect(overview.active, b);
      expect(await keyEntries(), {'connection.key.$b': 'key-b'});
      await store.forget(b);
      expect((await store.overview()).active, isNull);
      expect(await keyEntries(), isEmpty);
      await expectLater(store.forget(b), throwsA(isA<SavedArchiveMissing>()));
    });

    test('an unreadable index blocks rename and forget', () async {
      final id = ConnectionStore.newProfileId();
      final values = {'connections': '{"version":99}', 'connection.key.$id': 'k'};
      FlutterSecureStorage.setMockInitialValues(values);
      await expectLater(store.rename(id, 'x'), throwsA(anything));
      await expectLater(store.forget(id), throwsA(anything));
      expect(await storage.readAll(), values);
    });
  });

  group('session', () {
    late ArchiveSession session;
    late List<HostArchive> created;

    setUp(() async {
      created = [];
      await seedTwo();
      session = ArchiveSession(
        backendFactory: (type, server, key) {
          final api = HostArchive(server, key);
          created.add(api);
          return api;
        },
      );
      await session.restore();
    });
    tearDown(() => session.dispose());

    ConnectionProfile archive(String host) =>
        session.archives.firstWhere((item) => item.server.contains(host));

    test('changing an address needs the key again and keeps the type', () async {
      final b = archive('b.example');
      session.openReconfigure(b.id);
      expect(session.reconfiguring?.id, b.id);
      expect(session.server.text, second);
      expect(session.keyInput.text, isEmpty);
      expect(session.setupServerType, ArchiveServerType.openArchiver);
      session.chooseServerType(ArchiveServerType.mailArchiver);
      expect(session.setupServerType, ArchiveServerType.openArchiver);
      final before = created.length;
      session.server.text = 'c.example';
      await session.connect();
      expect(session.error, 'Enter your API key.');
      expect(created.length, before, reason: 'no request without a new key');
      session.keyInput.text = 'key-c';
      await session.connect();
      expect(session.setup, isFalse);
      expect(session.reconfiguring, isNull);
      expect((session.api! as HostArchive).key, 'key-c');
      expect(session.messages.single.subject, 'c.example mail');
      final changed = session.archives.firstWhere((item) => item.label == b.label);
      expect(changed.server, 'https://c.example');
      expect(changed.serverType, ArchiveServerType.openArchiver);
      expect(session.archives, hasLength(2));
      final keys = (await keyEntries()).values.toSet();
      expect(keys, {'key-a', 'key-c'});
    });

    test('a failed change keeps the saved archive and the open one', () async {
      final b = archive('b.example');
      final open = session.api!;
      HostArchive.offlineHosts.add('c.example');
      session.openReconfigure(b.id);
      session.server.text = 'c.example';
      session.keyInput.text = 'key-c';
      await session.connect();
      expect(session.setup, isTrue);
      expect(session.api, same(open));
      expect(created.last.closed, isTrue);
      expect((await store.connection(b.id)).key, 'key-b');
      session.cancelSetup();
      expect(session.reconfiguring, isNull);
      expect(session.setup, isFalse);
      expect(session.server.text, second);
    });

    test('a change may not duplicate another archive', () async {
      // Add a second Mail-Archiver archive, then try to move a.example onto
      // its address.
      session.openSetup();
      session.chooseServerType(ArchiveServerType.mailArchiver);
      session.server.text = 'c.example';
      session.keyInput.text = 'key-c';
      await session.connect();
      expect(session.archives, hasLength(3));
      final before = created.length;
      session.openReconfigure(archive('a.example').id);
      session.server.text = 'c.example';
      session.keyInput.text = 'key-x';
      await session.connect();
      expect(session.error, contains('already uses'));
      expect(created.length, before, reason: 'no request is sent');
      expect((await store.connection(archive('a.example').id)).key, 'key-a');
    });

    test('forgetting another archive keeps the open one', () async {
      final a = archive('a.example');
      final open = session.api;
      expect(await session.forgetArchive(a.id), isTrue);
      expect(session.api, same(open));
      expect(session.archives.single.server, second);
    });

    test('forgetting the open archive closes it and opens nothing', () async {
      final b = archive('b.example');
      final count = created.length;
      expect(await session.forgetArchive(b.id), isTrue);
      expect(session.setup, isTrue);
      expect(session.api, isNull);
      expect(created.length, count);
      expect(session.archives.single.server, first);
      expect(await store.read(), isNull);
    });

    test('renaming updates the picker label', () async {
      final b = archive('b.example');
      expect(await session.renameArchive(b.id, 'Work'), isTrue);
      expect(session.activeArchive?.label, 'Work');
      final saved = jsonDecode((await storage.read(key: 'connections'))!);
      expect(jsonEncode(saved), isNot(contains('key-')));
    });
  });

  group('screens', () {
    Future<void> openArchives(WidgetTester tester) async {
      await tester.runAsync(seedTwo);
      await tester.pumpWidget(
        MaterialApp(
          home: ArchiveHome(apiFactory: (server, key) => HostArchive(server, key)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archives'));
      await tester.pumpAndSettle();
    }

    testWidgets('rename from Settings → Archives', (tester) async {
      await openArchives(tester);
      expect(find.text('Mail-Archiver · a.example'), findsOneWidget);
      await tester.tap(find.byTooltip('Actions for a.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Family');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Family'), findsOneWidget);
    });

    testWidgets('forget needs confirmation and keeps server mail', (tester) async {
      await openArchives(tester);
      await tester.tap(find.byTooltip('Actions for a.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget on this device'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not changed'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Mail-Archiver · a.example'), findsOneWidget);
      await tester.tap(find.byTooltip('Actions for a.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget on this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(find.text('Mail-Archiver · a.example'), findsNothing);
      expect(await tester.runAsync(keyEntries), hasLength(1));
    });

    testWidgets('change address or key opens setup for that archive', (tester) async {
      await openArchives(tester);
      await tester.tap(find.byTooltip('Actions for b.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change address or key'));
      await tester.pumpAndSettle();
      expect(find.text('Change b.example'), findsOneWidget);
      expect(find.text('Save and connect'), findsOneWidget);
      expect(find.text('Try the demo'), findsNothing);
    });
  });
}
