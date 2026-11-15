import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/bichon_api.dart';
import 'package:mailburrow/open_archiver_api.dart';
import 'package:mailburrow/screens/setup_view.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';

import 'support/fake_archive_backend.dart';
import 'support/saved_connection.dart';

/// A fake that remembers which server type created it.
class TypedBackend extends FakeArchiveBackend {
  TypedBackend(this.type, Uri server, String key, {this.fail = false})
    : super(server, key);
  final ArchiveServerType type;
  final bool fail;
  var closed = false;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (fail) throw ArchiveFailure(401, credential: type.credential);
    return [
      ArchiveAccount(id: '${type.id}-1', name: '${type.label} one'),
      ArchiveAccount(id: '${type.id}-2', name: '${type.label} two'),
    ];
  }

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => MailPage(
    items: [MailSummary(id: '$accountId-mail', subject: 'From $accountId')],
  );

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => const [];

  @override
  void close() => closed = true;
}

Future<Map<String, dynamic>?> saved() async {
  final text = await savedConnectionText();
  return text == null ? null : jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<TypedBackend> created;
  var failTypes = <ArchiveServerType>{};

  // Setup is idle, as after restore() finds no saved connection.
  ArchiveSession session() => ArchiveSession(
    backendFactory: (type, server, key) {
      final backend = TypedBackend(
        type,
        server,
        key,
        fail: failTypes.contains(type),
      );
      created.add(backend);
      return backend;
    },
  )..busy = false;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    created = [];
    failTypes = {};
  });

  test('each server type has its own client and stored name', () {
    final server = Uri.parse('https://archive.example');
    final mailArchiver = createArchiveBackend(
      ArchiveServerType.mailArchiver,
      server,
      'test-only',
    );
    final openArchiver = createArchiveBackend(
      ArchiveServerType.openArchiver,
      server,
      'test-only',
    );
    expect(mailArchiver, isA<ArchiveApi>());
    expect(mailArchiver, isNot(isA<OpenArchiverApi>()));
    expect(openArchiver, isA<OpenArchiverApi>());
    mailArchiver.close();
    openArchiver.close();
    expect(ArchiveServerType.openArchiver.id, 'open-archiver');
    expect(ArchiveServerType.fromId('open-archiver'), ArchiveServerType.openArchiver);
    expect(ArchiveServerType.mailArchiver.label, 'Mail-Archiver');
    expect(ArchiveServerType.openArchiver.label, 'Open Archiver');
  });

  test('changing type requires a fresh key before any client is created', () async {
    final value = session();
    addTearDown(value.dispose);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'key-for-mail-archiver';
    value.chooseServerType(ArchiveServerType.openArchiver);
    expect(value.keyInput.text, isEmpty);
    await value.connect();
    expect(created, isEmpty);
    expect(value.error, 'Enter your API key.');
    expect(await saved(), isNull);
    value.keyInput.text = 'key-for-open-archiver';
    await value.connect();
    expect(created.single.type, ArchiveServerType.openArchiver);
    expect(created.single.key, 'key-for-open-archiver');
  });

  test('cancelled setup discards its unsaved key', () async {
    final value = session();
    addTearDown(value.dispose);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'original-key';
    await value.connect();
    final original = value.api;
    value.openSetup();
    value.chooseServerType(ArchiveServerType.openArchiver);
    value.keyInput.text = 'discarded-key';
    value.cancelSetup();
    expect(value.keyInput.text, isEmpty);
    value.openSetup();
    expect(value.keyInput.text, isEmpty);
    expect(value.setupServerType, ArchiveServerType.mailArchiver);
    expect(value.api, same(original));
    expect((await saved())?['key'], 'original-key');
  });

  test('connecting from setup uses and saves the chosen type', () async {
    final value = session();
    addTearDown(value.dispose);
    expect(value.setupServerType, ArchiveServerType.mailArchiver);
    value.chooseServerType(ArchiveServerType.openArchiver);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'test-only';
    await value.connect();
    expect(created.single.type, ArchiveServerType.openArchiver);
    expect(value.serverType, ArchiveServerType.openArchiver);
    expect(value.account?.id, 'open-archiver-1');
    expect((await saved())?['serverType'], 'open-archiver');
  });

  test('restoring uses the saved type, never the setup choice', () async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'version': 2,
        'serverType': 'open-archiver',
        'server': 'https://archive.example',
        'key': 'test-only',
        'accountId': 'open-archiver-2',
      }),
    });
    final value = session();
    addTearDown(value.dispose);
    await value.restore();
    expect(created.single.type, ArchiveServerType.openArchiver);
    expect(value.serverType, ArchiveServerType.openArchiver);
    expect(value.setupServerType, ArchiveServerType.openArchiver);
    expect(value.account?.id, 'open-archiver-2');
  });

  test('a cancelled or failed type change leaves the connection alone', () async {
    final value = session();
    addTearDown(value.dispose);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'test-only';
    await value.connect();
    final first = created.single;
    expect(first.type, ArchiveServerType.mailArchiver);

    value.openSetup();
    value.chooseServerType(ArchiveServerType.openArchiver);
    value.cancelSetup();
    expect(value.setupServerType, ArchiveServerType.mailArchiver);
    await value.switchAccount(
      const ArchiveAccount(id: 'mail-archiver-2', name: 'second'),
    );
    expect((await saved())?['serverType'], 'mail-archiver');

    failTypes = {ArchiveServerType.openArchiver};
    value.openSetup();
    value.chooseServerType(ArchiveServerType.openArchiver);
    value.keyInput.text = 'other-key';
    await value.connect();
    expect(value.error, isNotNull);
    expect(created.last.type, ArchiveServerType.openArchiver);
    expect(created.last.closed, isTrue);
    expect(value.api, same(first));
    expect(value.serverType, ArchiveServerType.mailArchiver);
    expect((await saved())?['serverType'], 'mail-archiver');
    expect((await saved())?['key'], 'test-only');
  });

  test('forgetting returns setup to Mail-Archiver', () async {
    final value = session();
    addTearDown(value.dispose);
    value.chooseServerType(ArchiveServerType.openArchiver);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'test-only';
    await value.connect();
    await value.forgetConnection();
    expect(value.serverType, ArchiveServerType.mailArchiver);
    expect(value.setupServerType, ArchiveServerType.mailArchiver);
    expect(await saved(), isNull);
  });

  testWidgets('setup offers both server types and explains each', (tester) async {
    final value = session();
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: value,
            builder: (_, _) => SetupView(session: value),
          ),
        ),
      ),
    );
    expect(find.text('Mail-Archiver'), findsOneWidget);
    expect(find.text('Open Archiver'), findsOneWidget);
    expect(find.textContaining('Tested with Open Archiver'), findsNothing);
    expect(find.text('Create an API key on your own Mail-Archiver server.'), findsOneWidget);

    await tester.tap(find.text('Open Archiver'));
    await tester.pumpAndSettle();
    expect(value.setupServerType, ArchiveServerType.openArchiver);
    expect(find.textContaining('Tested with Open Archiver 0.6.2'), findsOneWidget);
    expect(find.textContaining('Create an API key in your Open Archiver'), findsOneWidget);

    value.busy = true;
    await tester.tap(find.text('Mail-Archiver'));
    await tester.pumpAndSettle();
    expect(value.setupServerType, ArchiveServerType.openArchiver);
  });

  test('Bichon has its own client, stored name and credential wording', () {
    final bichon = createArchiveBackend(
      ArchiveServerType.bichon,
      Uri.parse('https://archive.example'),
      'test-only',
    );
    expect(bichon, isA<BichonApi>());
    bichon.close();
    expect(ArchiveServerType.bichon.id, 'bichon');
    expect(ArchiveServerType.fromId('bichon'), ArchiveServerType.bichon);
    expect(ArchiveServerType.bichon.label, 'Bichon');
    expect(ArchiveServerType.bichon.credentialLabel, 'Access token');
    expect(ArchiveServerType.mailArchiver.credentialLabel, 'API key');
    expect(ArchiveServerType.openArchiver.credentialLabel, 'API key');
  });

  test('an empty Bichon token asks for an access token', () async {
    final value = session();
    addTearDown(value.dispose);
    value.chooseServerType(ArchiveServerType.bichon);
    value.server.text = 'https://archive.example';
    await value.connect();
    expect(created, isEmpty);
    expect(value.error, 'Enter your access token.');
  });

  test('connecting and restoring use the saved Bichon type', () async {
    final value = session();
    addTearDown(value.dispose);
    value.chooseServerType(ArchiveServerType.bichon);
    value.server.text = 'https://archive.example';
    value.keyInput.text = 'test-only';
    await value.connect();
    expect(created.single.type, ArchiveServerType.bichon);
    expect((await saved())?['serverType'], 'bichon');

    final restored = session();
    addTearDown(restored.dispose);
    await restored.restore();
    expect(created.last.type, ArchiveServerType.bichon);
    expect(restored.serverType, ArchiveServerType.bichon);
    expect(restored.account?.id, 'bichon-1');
  });

  test(
    'switching among all three types pairs each archive with its own key',
    () async {
      final value = session();
      addTearDown(value.dispose);
      final types = [
        (ArchiveServerType.mailArchiver, 'https://a.example', 'key-a'),
        (ArchiveServerType.openArchiver, 'https://b.example', 'key-b'),
        (ArchiveServerType.bichon, 'https://c.example', 'key-c'),
      ];
      for (final (type, server, key) in types) {
        if (value.api != null) value.openSetup();
        value.chooseServerType(type);
        value.server.text = server;
        value.keyInput.text = key;
        await value.connect();
        expect(value.error, isNull, reason: type.label);
      }
      expect(value.archives.map((a) => a.serverType), [
        for (final (type, _, _) in types) type,
      ]);
      // Every order of switching, including back to where it started.
      for (final from in value.archives.toList()) {
        for (final to in value.archives.toList()) {
          if (from.id == to.id) continue;
          await value.switchArchive(from.id);
          await value.switchArchive(to.id);
          final backend = value.api as TypedBackend;
          final expected = types.firstWhere((t) => t.$1 == to.serverType);
          expect(backend.type, to.serverType);
          expect(backend.key, expected.$3, reason: 'never another archive key');
          expect(value.serverType, to.serverType);
          expect(value.messages.single.subject, 'From ${to.serverType.id}-1');
        }
      }
      for (final backend in created) {
        final expected = types.firstWhere((t) => t.$1 == backend.type);
        expect(backend.key, expected.$3);
      }
    },
  );

  testWidgets('setup offers Bichon with access-token wording', (tester) async {
    final value = session();
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: value,
            builder: (_, _) => SetupView(session: value),
          ),
        ),
      ),
    );
    expect(find.text('Bichon'), findsOneWidget);
    expect(find.text('Access token'), findsNothing);
    await tester.tap(find.text('Bichon'));
    await tester.pumpAndSettle();
    expect(value.setupServerType, ArchiveServerType.bichon);
    expect(find.text('Access token'), findsOneWidget);
    expect(find.text('API key'), findsNothing);
    expect(
      find.textContaining('Tested with Bichon 2.4.2 Community'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Never enter your mailbox password'),
      findsOneWidget,
    );
    expect(find.textContaining('Member user Viewer access'), findsOneWidget);
    await tester.tap(find.text('Mail-Archiver'));
    await tester.pumpAndSettle();
    expect(find.text('API key'), findsOneWidget);
    expect(find.textContaining('Tested with Bichon'), findsNothing);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets(
      'three server types fit a ${width.toInt()} dp screen at 200% text',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final value = session();
        addTearDown(value.dispose);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MaterialApp(
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: value,
                  builder: (_, _) => SetupView(session: value),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final type in ArchiveServerType.values) {
          expect(find.text(type.label), findsOneWidget);
        }
        await tester.tap(find.text('Bichon'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(value.setupServerType, ArchiveServerType.bichon);
      },
    );
  }

  testWidgets('a refused Bichon token offers a new access token', (tester) async {
    final first = session();
    await tester.runAsync(() async {
      first.chooseServerType(ArchiveServerType.bichon);
      first.server.text = 'https://archive.example';
      first.keyInput.text = 'test-only';
      await first.connect();
    });
    first.dispose();
    failTypes = {ArchiveServerType.bichon};
    final value = session();
    addTearDown(value.dispose);
    await tester.runAsync(value.restore);
    expect(value.api, isNull);
    expect(value.error, contains('Your access token was not accepted.'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: value,
            builder: (_, _) => SetupView(session: value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enter a new access token for archive.example'), findsOneWidget);
    expect(find.textContaining('Enter a new key'), findsNothing);
  });
}
