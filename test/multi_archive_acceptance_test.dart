// Interaction acceptance tests for several saved archives, one per item in
// the completion plan's list. They run against synthetic servers; device,
// native secure-storage and signed-upgrade checks are separate.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_capabilities.dart';
import 'package:mailburrow/archive_errors.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/open_archiver_api.dart' show openArchiverCapabilities;
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';

const storage = FlutterSecureStorage();
const store = ConnectionStore();
const hostA = 'a.example';
const hostB = 'b.example';

/// How a synthetic server behaves.
class LabServer {
  LabServer({this.acceptedKey, ArchiveCapabilities? capabilities})
    : capabilities = capabilities ?? ArchiveCapabilities.full;
  final ArchiveCapabilities capabilities;

  /// The only key the server accepts; null accepts any key.
  String? acceptedKey;
  bool offline = false;
  Completer<void>? holdAccounts;

  /// Holds mail requests for this query until completed.
  final held = <String, Completer<void>>{};
  final filtersSeen = <SearchFilters>[];
}

/// Every server and every client created, so tests can check which key was
/// sent to which address.
final servers = <String, LabServer>{};
final clients = <LabClient>[];

class LabClient extends FakeArchiveBackend {
  LabClient(super.server, super.key) {
    clients.add(this);
  }
  LabServer get lab => servers[server.host]!;
  bool closed = false;

  @override
  ArchiveCapabilities get capabilities => lab.capabilities;

  void _check() {
    if (closed) throw StateError('closed client used');
    if (lab.offline) throw const SocketException('offline');
    final accepted = lab.acceptedKey;
    if (accepted != null && accepted != key) throw const ArchiveFailure(401);
  }

  @override
  Future<List<ArchiveAccount>> accounts() async {
    await lab.holdAccounts?.future;
    _check();
    // Equal IDs on every server.
    return [
      for (final id in ['1', '2'])
        ArchiveAccount(id: id, emailAddress: 'user$id@${server.host}'),
    ];
  }

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async {
    _check();
    return [ArchiveFolder('Inbox', 'INBOX', 1, 0)];
  }

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    _check();
    lab.filtersSeen.add(filters);
    await lab.held[query]?.future;
    return MailPage(
      items: [
        MailSummary(id: '1', subject: '${server.host} $accountId $query'.trim()),
      ],
    );
  }

  @override
  Future<MailMessage> message(String id) async {
    _check();
    return MailMessage(subject: 'Message $id on ${server.host}');
  }

  @override
  void close() => closed = true;
}

ArchiveSession newSession() =>
    ArchiveSession(backendFactory: (type, server, key) => LabClient(server, key));

Future<void> addArchive(
  ArchiveSession session,
  ArchiveServerType type,
  String host,
  String key,
) async {
  session.openSetup();
  session.chooseServerType(type);
  session.server.text = host;
  session.keyInput.text = key;
  await session.connect();
}

ConnectionProfile archiveAt(ArchiveSession session, String host) =>
    session.archives.firstWhere((item) => item.server == 'https://$host');

String? subject(ArchiveSession session) =>
    session.messages.isEmpty ? null : session.messages.single.subject;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ArchiveSession session;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    clients.clear();
    servers
      ..clear()
      ..[hostA] = LabServer(acceptedKey: 'key-a')
      ..[hostB] = LabServer(
        acceptedKey: 'key-b',
        capabilities: openArchiverCapabilities,
      )
      ..['c.example'] = LabServer();
    session = newSession();
    await session.restore();
  });
  tearDown(() => session.dispose());

  Future<void> addBoth() async {
    await addArchive(session, ArchiveServerType.mailArchiver, hostA, 'key-a');
    await addArchive(session, ArchiveServerType.openArchiver, hostB, 'key-b');
  }

  test('add A then B: both are saved and B is open', () async {
    await addBoth();
    expect(session.archives.map((item) => item.label), [hostA, hostB]);
    expect(session.activeArchive?.label, hostB);
    expect(subject(session), '$hostB 1');
  });

  test('cancelling or failing to add B keeps A open and saved', () async {
    await addArchive(session, ArchiveServerType.mailArchiver, hostA, 'key-a');
    final open = session.api;
    session.openSetup();
    session.server.text = hostB;
    session.keyInput.text = 'key-b';
    session.cancelSetup();
    expect(session.api, same(open));
    expect(session.archives, hasLength(1));
    servers[hostB]!.offline = true;
    await addArchive(session, ArchiveServerType.openArchiver, hostB, 'key-b');
    expect(session.setup, isTrue);
    expect(session.api, same(open));
    expect(session.archives, hasLength(1));
    expect(clients.last.closed, isTrue);
    expect((await store.read())?.server, 'https://$hostA');
    session.cancelSetup();
    expect(subject(session), '$hostA 1');
  });

  test('equal account and message IDs never mix archives', () async {
    await addBoth();
    expect((await session.api!.message('1')).subject, 'Message 1 on $hostB');
    await session.switchArchive(archiveAt(session, hostA).id);
    expect(session.account?.id, '1');
    expect(subject(session), '$hostA 1');
    expect((await session.api!.message('1')).subject, 'Message 1 on $hostA');
    expect(clients.where((item) => item.server.host == hostB).every((c) => c.closed), isTrue);
  });

  test('each archive keeps its own selected account or source', () async {
    await addBoth();
    final accounts = await session.api!.accounts();
    await session.switchAccount(accounts.last);
    expect(session.account?.id, '2');
    await session.switchArchive(archiveAt(session, hostA).id);
    expect(session.account?.id, '1');
    await session.switchArchive(archiveAt(session, hostB).id);
    expect(session.account?.id, '2');
    expect(subject(session), '$hostB 2');
  });

  test('late responses from A are discarded once B is active', () async {
    await addBoth();
    await session.switchArchive(archiveAt(session, hostA).id);
    final gate = servers[hostA]!.held['late'] = Completer<void>();
    session.search.text = 'late';
    final pending = session.load(1);
    await pumpEventQueue();
    expect(session.mailLoading, isTrue);
    expect(session.canSwitchArchive, isTrue);
    await session.switchArchive(archiveAt(session, hostB).id);
    expect(subject(session), '$hostB 1');
    gate.complete();
    await pending;
    await pumpEventQueue();
    expect(subject(session), '$hostB 1');
    expect(session.activeArchive?.label, hostB);
  });

  test('offline B, then switching back to A', () async {
    await addBoth();
    servers[hostB]!.offline = true;
    await session.switchArchive(archiveAt(session, hostA).id);
    await session.switchArchive(archiveAt(session, hostB).id);
    expect(session.setup, isTrue);
    expect(session.messages, isEmpty);
    expect(session.error, startsWith('Could not open $hostB'));
    expect(session.reconnectArchive, isNull, reason: 'offline is not a key problem');
    await session.switchArchive(archiveAt(session, hostA).id);
    expect(subject(session), '$hostA 1');
  });

  test('an expired key on B offers Reconnect for B only', () async {
    await addBoth();
    await session.switchArchive(archiveAt(session, hostA).id);
    servers[hostB]!.acceptedKey = 'key-b-new';
    final b = archiveAt(session, hostB);
    await session.switchArchive(b.id);
    expect(session.error, contains('API key was not accepted'));
    expect(session.reconnectArchive?.id, b.id);
    session.openReconfigure(b.id);
    expect(session.reconfiguring?.id, b.id);
    expect(session.keyInput.text, isEmpty);
    expect(session.server.text, 'https://$hostB');
    session.keyInput.text = 'key-b-new';
    await session.connect();
    expect(session.activeArchive?.label, hostB);
    expect(session.reconnectArchive, isNull);
    expect((await store.connection(archiveAt(session, hostB).id)).key, 'key-b-new');
    expect((await store.connection(archiveAt(session, hostA).id)).key, 'key-a');
    expect(session.archives, hasLength(2));
  });

  test('an expired key found at startup offers Reconnect, and Cancel stays on setup', () async {
    await addBoth();
    servers[hostB]!.acceptedKey = 'other';
    session.dispose();
    session = newSession();
    await session.restore();
    final b = archiveAt(session, hostB);
    expect(session.reconnectArchive?.id, b.id);
    session.openReconfigure(b.id);
    session.cancelSetup();
    expect(session.setup, isTrue);
    expect(session.reconfiguring, isNull);
    expect(session.server.text, isEmpty);
    expect(session.api, isNull);
  });

  test('filters the destination does not support are cleared', () async {
    await addBoth();
    await session.switchArchive(archiveAt(session, hostA).id);
    await session.applyFilters(
      const SearchFilters(direction: 'incoming', sortBy: 'subject', sortOrder: 'asc'),
    );
    expect(session.filters.direction, 'incoming');
    servers[hostB]!.filtersSeen.clear();
    await session.switchArchive(archiveAt(session, hostB).id);
    expect(session.filters.active, isFalse);
    expect(session.search.text, isEmpty);
    for (final seen in servers[hostB]!.filtersSeen) {
      expect(seen.direction, isEmpty);
      expect(seen.sortBy, 'sentDate');
    }
  });

  test('a key is only ever sent to its own archive', () async {
    await addBoth();
    for (var i = 0; i < 3; i++) {
      await session.switchArchive(archiveAt(session, hostA).id);
      await session.switchArchive(archiveAt(session, hostB).id);
    }
    servers[hostB]!.offline = true;
    await session.switchArchive(archiveAt(session, hostA).id);
    await session.switchArchive(archiveAt(session, hostB).id);
    final expected = {hostA: 'key-a', hostB: 'key-b'};
    for (final client in clients) {
      expect(client.key, expected[client.server.host], reason: client.server.host);
    }
  });

  test('forgetting inactive and active archives is independent', () async {
    await addBoth();
    await addArchive(session, ArchiveServerType.mailArchiver, 'c.example', 'key-c');
    final open = session.api;
    expect(await session.forgetArchive(archiveAt(session, hostA).id), isTrue);
    expect(session.api, same(open));
    expect(session.archives.map((item) => item.label), [hostB, 'c.example']);
    final count = clients.length;
    expect(await session.forgetArchive(archiveAt(session, 'c.example').id), isTrue);
    expect(session.api, isNull);
    expect(clients.length, count, reason: 'nothing else opens');
    expect(session.archives.single.label, hostB);
    expect((await store.connection(session.archives.single.id)).key, 'key-b');
  });

  test('restart restores the last active archive and its source', () async {
    await addBoth();
    await session.switchArchive(archiveAt(session, hostA).id);
    await session.switchAccount((await session.api!.accounts()).last);
    session.dispose();
    session = newSession();
    await session.restore();
    expect(session.activeArchive?.label, hostA);
    expect(session.account?.id, '2');
    expect(session.archives, hasLength(2));
  });

  test('demo entry and exit leave both archives untouched', () async {
    await addBoth();
    final before = await storage.readAll();
    session.dispose();
    session = ArchiveSession(
      backendFactory: (type, server, key) => throw StateError('no connection'),
      demoLoader: () async => LabClient(Uri.parse('https://c.example'), ''),
    );
    await session.startDemo();
    expect(session.activeArchive, isNull);
    expect(session.canSwitchArchive, isFalse);
    session.exitDemo();
    expect(session.setup, isTrue);
    expect(await storage.readAll(), before);
  });

  group('screens', () {
    Future<void> seed() async {
      await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: 'https://$hostA',
        key: 'key-a',
        accountId: '1',
      );
      await store.add(
        serverType: ArchiveServerType.openArchiver,
        server: 'https://$hostB',
        key: 'key-b',
        accountId: '1',
      );
    }

    Widget app({double textScale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: ArchiveHome(apiFactory: (server, key) => LabClient(server, key)),
    );

    testWidgets('the archive switch is unreachable while a message is open', (tester) async {
      await tester.runAsync(seed);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final label = find.byKey(const ValueKey('current-archive'));
      expect(label.hitTestable(), findsOneWidget);
      await tester.tap(find.text('$hostB 1'));
      await tester.pump();
      // The body is prepared off the UI isolate.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Message 1 on $hostB'), findsOneWidget);
      expect(label.hitTestable(), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(label.hitTestable(), findsOneWidget);
    });

    testWidgets('screen readers hear the archive and the switch progress', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.runAsync(seed);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('Open Archiver · $hostB')),
        findsWidgets,
      );
      final gate = servers[hostA]!.holdAccounts = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('current-archive')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('Mail-Archiver · $hostA')), findsWidgets);
      await tester.tap(find.text(hostA).last);
      await tester.pump();
      // Let the picker finish closing; the progress spinner never settles.
      await tester.pump(const Duration(milliseconds: 600));
      final live = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      );
      expect(
        find.descendant(of: live, matching: find.text('Opening $hostA…')),
        findsOneWidget,
      );
      expect(find.text('Mail-Archiver · $hostA'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('$hostA 1'), findsOneWidget);
      semantics.dispose();
    });

    for (final (name, size, scale) in [
      ('large text', const Size(400, 800), 2.0),
      ('landscape', const Size(800, 400), 1.0),
      ('landscape with large text', const Size(800, 400), 2.0),
    ]) {
      testWidgets('picker and progress fit with $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(seed);
        await tester.pumpWidget(app(textScale: scale));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('current-archive')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Add archive'),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Add archive'), findsOneWidget);
        final gate = servers[hostA]!.holdAccounts = Completer<void>();
        await tester.scrollUntilVisible(
          find.text(hostA),
          -100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text(hostA).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Opening $hostA…'), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('current-archive')),
            matching: find.text(hostA),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('setup offers a new key when the saved one is refused', (tester) async {
      servers[hostB]!.acceptedKey = 'rotated';
      await tester.runAsync(seed);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final reconnect = find.text('Enter a new key for $hostB');
      await tester.scrollUntilVisible(
        reconnect,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(reconnect, findsOneWidget);
      await tester.tap(reconnect);
      await tester.pumpAndSettle();
      expect(find.text('Change $hostB'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'API key'), 'rotated');
      await tester.ensureVisible(find.text('Save and connect'));
      await tester.tap(find.text('Save and connect'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('current-archive')), findsOneWidget);
      expect(find.text('Enter a new key for $hostB'), findsNothing);
    });
  });
}
