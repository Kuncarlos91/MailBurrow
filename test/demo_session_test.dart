import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/demo/demo_archive.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';

/// Records every secure-storage call so tests can prove the demo makes none.
class RecordingStore extends ConnectionStore {
  final calls = <String>[];
  @override
  Future<SavedConnection?> read() {
    calls.add('read');
    return super.read();
  }

  @override
  Future<void> write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required String? accountId,
  }) {
    calls.add('write');
    return super.write(
      serverType: serverType,
      server: server,
      key: key,
      accountId: accountId,
    );
  }

  @override
  Future<void> delete() {
    calls.add('delete');
    return super.delete();
  }
}

/// Minimal real-server stand-in for checks around the demo.
class RealArchive extends FakeArchiveBackend {
  RealArchive(super.server, super.key);
  bool closedByApp = false;
  @override
  Future<List<ArchiveAccount>> accounts() async => [
    {'id': 7, 'emailAddress': 'owner@example.com'},
  ].map(ArchiveAccount.fromJson).toList();
  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => [];
  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => MailPage.fromJson({
    'items': [
      {'id': 70, 'subject': 'Real archive message', 'from': 'a@example.com'},
    ],
    'page': page,
    'totalPages': 1,
  });
  @override
  void close() => closedByApp = true;
}

const savedJson =
    '{"server":"https://archive.example.com","key":"test-only","accountId":7}';

Future<String?> savedRaw() =>
    const FlutterSecureStorage().read(key: 'connection');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingStore store;
  late ArchiveSession session;
  final realArchives = <RealArchive>[];
  final demos = <DemoArchive>[];
  var latency = Duration.zero;

  ArchiveSession newSession() => ArchiveSession(
    store: store,
    apiFactory: (server, key) {
      final made = RealArchive(server, key);
      realArchives.add(made);
      return made;
    },
    demoLoader: () async {
      final made = await DemoArchive.load(latency: latency);
      demos.add(made);
      return made;
    },
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    latency = Duration.zero;
    realArchives.clear();
    demos.clear();
    store = RecordingStore();
    session = newSession();
  });

  tearDown(() => session.dispose());

  test('starting the demo opens fictional mail without touching storage',
      () async {
    await session.startDemo();
    expect(session.demo, isTrue);
    expect(session.setup, isFalse);
    expect(session.busy, isFalse);
    expect(session.error, isNull);
    expect(session.api!.server.host, 'demo.mailburrow.invalid');
    expect(session.account!.id, '1');
    expect(session.messages, hasLength(25));
    expect(session.totalPages, 2);
    expect(session.folders, isNotEmpty);
    expect(store.calls, isEmpty);
    expect(await savedRaw(), isNull);
  });

  test('a saved real connection survives demo browsing, switching and exit',
      () async {
    FlutterSecureStorage.setMockInitialValues({'connection': savedJson});
    await session.restore();
    expect(session.demo, isFalse);
    final before = await savedRaw();
    expect(before, isNotNull);
    session.openSetup();
    store.calls.clear();

    await session.startDemo();
    await session.switchAccount(ArchiveAccount.fromJson({'id': 2, 'emailAddress': 'bakery'}));
    expect(session.account!.id, '2');
    expect(session.messages, isNotEmpty);
    await session.applyFilters(const SearchFilters(direction: 'outgoing'));
    session.exitDemo();

    expect(store.calls, isEmpty, reason: 'no read, write or delete');
    expect(await savedRaw(), before);
    expect(session.setup, isTrue);
    expect(session.demo, isFalse);
    expect(session.api, isNull);
    expect(session.hasSavedConnection, isTrue);
    expect(session.server.text, 'https://archive.example.com');
    await expectLater(demos.single.accounts(), throwsA(isA<StateError>()));
  });

  test('forget during the demo exits without deleting the saved connection',
      () async {
    FlutterSecureStorage.setMockInitialValues({'connection': savedJson});
    await session.startDemo();
    await session.forgetConnection();
    expect(session.demo, isFalse);
    expect(session.setup, isTrue);
    expect(store.calls, isEmpty);
    expect(await savedRaw(), savedJson);
  });

  test('restoring after the demo restores the real connection, never the demo',
      () async {
    FlutterSecureStorage.setMockInitialValues({'connection': savedJson});
    await session.startDemo();
    session.exitDemo();
    session.dispose();

    session = newSession();
    await session.restore();
    expect(session.demo, isFalse);
    expect(session.setup, isFalse);
    expect(session.api, isA<RealArchive>());
    expect(demos, hasLength(1), reason: 'restore never loads the demo');

    session.dispose();
    FlutterSecureStorage.setMockInitialValues({});
    session = newSession();
    await session.restore();
    expect(session.setup, isTrue);
    expect(session.api, isNull);
  });

  test('exiting while a page is loading ignores its late result', () async {
    latency = const Duration(milliseconds: 40);
    await session.startDemo();

    final pending = session.load(2);
    session.exitDemo();
    await pending;
    expect(session.setup, isTrue);
    expect(session.demo, isFalse);
    expect(session.messages, isEmpty);
    expect(session.busy, isFalse);
    expect(session.mailLoading, isFalse);
    expect(session.error, isNull);
  });

  test('exiting while an account switch is loading ignores its results',
      () async {
    latency = const Duration(milliseconds: 40);
    await session.startDemo();
    final pending = session.switchAccount(ArchiveAccount.fromJson({'id': 3, 'emailAddress': 'club'}));
    await Future<void>.delayed(Duration.zero);
    session.exitDemo();
    await pending;
    expect(session.setup, isTrue);
    expect(session.account, isNull);
    expect(session.messages, isEmpty);
    expect(session.accountLoading, isFalse);
    expect(session.busy, isFalse);
    expect(store.calls, isEmpty);
  });

  test('connecting to a real server from the demo replaces it', () async {
    await session.startDemo();
    final demo = demos.single;
    session.openSetup();
    session.server.text = 'archive.example.com';
    session.keyInput.text = 'test-only';
    await session.connect();

    expect(session.demo, isFalse);
    expect(session.api, isA<RealArchive>());
    expect(session.account!.id, '7');
    await expectLater(demo.accounts(), throwsA(isA<StateError>()));
    expect(store.calls, ['write']);
    expect(
      jsonDecode((await savedRaw())!) as Map<String, dynamic>,
      containsPair('server', 'https://archive.example.com'),
    );
  });

  test('cancelling setup from the demo returns to the demo', () async {
    await session.startDemo();
    session.openSetup();
    session.cancelSetup();
    expect(session.demo, isTrue);
    expect(session.setup, isFalse);
  });

  test('a demo that fails to open leaves setup and storage unchanged',
      () async {
    session.dispose();
    session = ArchiveSession(
      store: store,
      demoLoader: () async => throw StateError('asset missing'),
    );
    await session.startDemo();
    expect(session.demo, isFalse);
    expect(session.setup, isTrue);
    expect(session.api, isNull);
    expect(session.busy, isFalse);
    expect(session.error, 'Could not open the demo. Try again.');
    expect(store.calls, isEmpty);
  });

  test('exitDemo does nothing outside the demo', () async {
    final before = session.setup;
    session.exitDemo();
    expect(session.setup, before);
    expect(store.calls, isEmpty);
  });

  test('the session uses the loaded demo backend', () async {
    await session.startDemo();
    expect(session.api, same(demos.single));
  });
}
