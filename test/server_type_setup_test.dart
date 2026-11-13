import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/open_archiver_api.dart';
import 'package:mailburrow/screens/setup_view.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';

import 'support/fake_archive_backend.dart';

/// A fake that remembers which server type created it.
class TypedBackend extends FakeArchiveBackend {
  TypedBackend(this.type, Uri server, String key, {this.fail = false})
    : super(server, key);
  final ArchiveServerType type;
  final bool fail;
  var closed = false;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (fail) throw const ArchiveFailure(401);
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
  final text = await const FlutterSecureStorage().read(key: 'connection');
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
}
