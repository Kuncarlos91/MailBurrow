import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/archive_errors.dart';
import 'package:mailburrow/archive_backend.dart';
import 'package:mailburrow/attachment_download.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';

/// Synthetic archive: two accounts, and mail results that a test can hold
/// open per query to finish requests out of order.
class FakeArchiveApi extends FakeArchiveBackend {
  FakeArchiveApi(super.server, super.key);

  List<Map<String, dynamic>> accountList = [
    {'id': 1, 'emailAddress': 'one@example.com'},
    {'id': 2, 'emailAddress': 'two@example.com'},
  ];
  final held = <String, Completer<Map<String, dynamic>>>{};
  bool failMail = false;
  bool failAccounts = false;
  int mailRequests = 0;
  int cancelledMailRequests = 0;
  bool closedByApp = false;

  static Map<String, dynamic> page(String label, {int count = 1}) => {
    'items': [
      for (var i = 0; i < count; i++) {'id': i, 'subject': '$label $i'},
    ],
    'page': 1,
    'totalPages': 1,
  };

  @override
  Future<List<dynamic>> accounts() async {
    if (failAccounts) throw const ArchiveFailure(500);
    return accountList;
  }

  @override
  Future<List<ArchiveFolder>> folders(int id) async => [
    ArchiveFolder('Inbox $id', 'INBOX-$id', 1, 0),
  ];

  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) {
    mailRequests++;
    if (failMail) return Future.error(const ArchiveFailure(500));
    final hold = held['$id:$query'];
    if (hold != null) return hold.future;
    final label = query.isEmpty ? 'mail' : query;
    return Future.value(FakeArchiveApi.page('account $id $label'));
  }

  @override
  void cancelEmailRequests() {
    cancelledMailRequests++;
  }

  @override
  void close() {
    closedByApp = true;
    super.close();
  }
}

/// Lets unawaited requests and their notifications finish.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// A backend unrelated to Mail-Archiver's [ArchiveApi], showing that the app
/// needs only the [ArchiveBackend] interface.
class MemoryBackend implements ArchiveBackend {
  MemoryBackend(this.server, this.key);
  @override
  final Uri server;
  @override
  final String key;
  bool closed = false;

  @override
  Future<List<dynamic>> accounts() async => [
    {'id': 7, 'emailAddress': 'memory@example.com'},
  ];

  @override
  Future<List<ArchiveFolder>> folders(int accountId) async => const [
    ArchiveFolder('Inbox', 'INBOX', 1, 0),
  ];

  @override
  Future<Map<String, dynamic>> emails(
    int accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => {
    'items': [
      {'id': 1, 'subject': 'From memory'},
    ],
    'page': 1,
    'totalPages': 1,
  };

  @override
  Future<Map<String, dynamic>> message(int id) async => {
    'id': id,
    'subject': 'From memory',
  };

  @override
  Future<void> downloadAttachment(
    int emailId,
    int attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) async {}

  @override
  Future<Map<String, dynamic>> stats() async => {
    'emails': 1,
    'accounts': 1,
    'attachments': 0,
  };

  @override
  void cancelEmailRequests() {}

  @override
  void close() {
    closed = true;
  }
}

/// Secure storage that refuses to save, as on a device with storage problems.
class FailingStore extends ConnectionStore {
  const FailingStore();
  @override
  Future<void> write({
    required ArchiveServerType serverType,
    required String server,
    required String key,
    required Object? accountId,
  }) async => throw Exception('storage unavailable');
}

List<String> subjects(ArchiveSession session) => [
  for (final item in session.messages)
    (item as Map<String, dynamic>)['subject'] as String,
];

Future<Map<String, dynamic>?> savedConnection() async {
  final saved = await const FlutterSecureStorage().read(key: 'connection');
  return saved == null ? null : jsonDecode(saved) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeArchiveApi api;
  late ArchiveSession session;

  ArchiveSession newSession() => ArchiveSession(
    apiFactory: (server, key) => api = FakeArchiveApi(server, key),
  );

  Future<void> connectFresh() async {
    session.server.text = 'archive.example.com';
    session.keyInput.text = 'test-only';
    await session.connect();
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    session = newSession();
  });

  tearDown(() => session.dispose());

  test('restore without a saved connection shows setup', () async {
    await session.restore();
    expect(session.setup, isTrue);
    expect(session.restoring, isFalse);
    expect(session.busy, isFalse);
    expect(session.api, isNull);
  });

  test('connect rejects an address that is not HTTPS', () async {
    session.server.text = 'http://archive.example.com';
    session.keyInput.text = 'test-only';
    await session.connect();
    expect(session.api, isNull);
    expect(session.setup, isTrue);
    expect(session.error, contains('HTTPS'));
    expect(await savedConnection(), isNull);
  });

  test('connect loads mail and folders and saves the connection', () async {
    await connectFresh();
    expect(session.setup, isFalse);
    expect(session.busy, isFalse);
    expect(session.account?['id'], 1);
    expect(subjects(session), ['account 1 mail 0']);
    expect(session.folders.single.path, 'INBOX-1');
    expect(session.keyInput.text, isEmpty);
    final saved = await savedConnection();
    expect(saved?['server'], 'https://archive.example.com');
    expect(saved?['accountId'], '1');
    expect(saved?['version'], 2);
    expect(saved?['serverType'], 'mail-archiver');
  });

  test('restore reopens the remembered account', () async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'https://archive.example.com',
        'key': 'test-only',
        'accountId': 2,
      }),
    });
    await session.restore();
    expect(session.account?['id'], 2);
    expect(session.accountNotice, isNull);
    expect(subjects(session), ['account 2 mail 0']);
  });

  test('a saved connection from 0.3.0-rc.9 migrates to version 2', () async {
    // Version 1: no version or server type, numeric account ID.
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'https://archive.example.com',
        'key': 'test-only',
        'accountId': 2,
      }),
    });
    await session.restore();
    expect(session.account?['id'], 2);
    expect(session.serverType, ArchiveServerType.mailArchiver);
    expect(await savedConnection(), {
      'version': 2,
      'serverType': 'mail-archiver',
      'server': 'https://archive.example.com',
      'key': 'test-only',
      'accountId': '2',
    });

    // The migrated value restores the same account after an app restart.
    session.dispose();
    session = newSession();
    await session.restore();
    expect(session.account?['id'], 2);
    expect(session.accountNotice, isNull);
  });

  test('an unknown saved server type is never probed with the saved key',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'version': 2,
        'serverType': 'some-future-server',
        'server': 'https://archive.example.com',
        'key': 'test-only',
        'accountId': '2',
      }),
    });
    var created = 0;
    session.dispose();
    session = ArchiveSession(
      apiFactory: (server, key) {
        created++;
        return api = FakeArchiveApi(server, key);
      },
    );
    await session.restore();
    expect(created, 0, reason: 'no request is sent with the saved key');
    expect(session.api, isNull);
    expect(session.setup, isTrue);
    expect(session.error, contains('Saved connection unavailable'));
  });

  test('restore explains a remembered account that is gone', () async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'https://archive.example.com',
        'key': 'test-only',
        'accountId': 9,
      }),
    });
    await session.restore();
    expect(session.account?['id'], 1);
    expect(session.accountNotice, contains('no longer available'));
  });

  test(
    'a slow search that finishes last does not replace a newer one',
    () async {
      await connectFresh();
      final slow = api.held['1:slow'] = Completer();
      session.search.text = 'slow';
      final slowLoad = session.load(1);
      expect(session.mailLoading, isTrue);

      session.search.text = 'fast';
      await session.load(1);
      expect(subjects(session), ['account 1 fast 0']);

      slow.complete(FakeArchiveApi.page('stale'));
      await slowLoad;
      expect(subjects(session), ['account 1 fast 0']);
      expect(session.busy, isFalse);
      expect(session.mailLoading, isFalse);
    },
  );

  test(
    'switching account discards mail still loading for the old one',
    () async {
      await connectFresh();
      final slow = api.held['1:slow'] = Completer();
      session.search.text = 'slow';
      final slowLoad = session.load(1);

      final cancellations = api.cancelledMailRequests;
      var changed = false;
      session.onAccountChanged = (_) => changed = true;
      await session.switchAccount({'id': 2, 'emailAddress': 'two@example.com'});

      slow.complete(FakeArchiveApi.page('stale'));
      await slowLoad;
      expect(changed, isTrue);
      expect(api.cancelledMailRequests, greaterThan(cancellations));
      expect(session.account?['id'], 2);
      expect(session.search.text, isEmpty);
      expect(subjects(session), ['account 2 mail 0']);
      expect(session.folders.single.path, 'INBOX-2');
      expect(session.accountLoading, isFalse);
      expect((await savedConnection())?['accountId'], '2');
    },
  );

  test('a failed mail request reports a retry that reloads', () async {
    await connectFresh();
    String? reported;
    void Function()? retry;
    session.onMailRequestFailed = (message, action) {
      reported = message;
      retry = action;
    };
    api.failMail = true;
    await session.load(1);
    expect(session.mailRequestFailed, isTrue);
    expect(reported, isNotNull);
    expect(session.error, reported);

    api.failMail = false;
    final before = api.mailRequests;
    retry!();
    await settle();
    expect(api.mailRequests, before + 1);
    expect(session.mailRequestFailed, isFalse);
    expect(subjects(session), ['account 1 mail 0']);
  });

  test('a retry from an outdated failure does nothing', () async {
    await connectFresh();
    void Function()? retry;
    session.onMailRequestFailed = (_, action) => retry = action;
    api.failMail = true;
    await session.load(1);
    api.failMail = false;
    await session.load(1);
    final before = api.mailRequests;
    retry!();
    await settle();
    expect(api.mailRequests, before);
  });

  test('forget clears the connection, state and saved settings', () async {
    await connectFresh();
    final connected = api;
    await session.forgetConnection();
    expect(session.setup, isTrue);
    expect(session.api, isNull);
    expect(session.account, isNull);
    expect(session.messages, isEmpty);
    expect(session.folders, isEmpty);
    expect(session.server.text, isEmpty);
    expect(connected.closedByApp, isTrue);
    expect(await savedConnection(), isNull);
  });

  group('a failed connection attempt closes its client', () {
    final created = <FakeArchiveApi>[];

    Future<void> connectWith(
      void Function(FakeArchiveApi api) setUpApi, {
      ConnectionStore store = const ConnectionStore(),
    }) async {
      session.dispose();
      session = ArchiveSession(
        store: store,
        apiFactory: (server, key) {
          final made = FakeArchiveApi(server, key);
          setUpApi(made);
          created.add(made);
          return made;
        },
      );
      session.server.text = 'archive.example.com';
      session.keyInput.text = 'test-only';
      await session.connect();
    }

    setUp(created.clear);

    test('when accounts cannot be loaded', () async {
      await connectWith((api) => api.failAccounts = true);
      expect(session.api, isNull);
      expect(session.error, isNotNull);
      expect(created.single.closedByApp, isTrue);
    });

    test('when the first mail page cannot be loaded', () async {
      await connectWith((api) => api.failMail = true);
      expect(session.api, isNull);
      expect(created.single.closedByApp, isTrue);
    });

    test('when the connection cannot be saved', () async {
      await connectWith((_) {}, store: const FailingStore());
      expect(session.api, isNull);
      expect(session.error, contains('could not save'));
      expect(created.single.closedByApp, isTrue);
      expect(await savedConnection(), isNull);
    });

    test('but keeps the client of a successful connection', () async {
      await connectWith((_) {});
      expect(session.api, same(created.single));
      expect(created.single.closedByApp, isFalse);
    });
  });

  test('works with any ArchiveBackend, not only Mail-Archiver', () async {
    MemoryBackend? backend;
    session.dispose();
    session = ArchiveSession(
      apiFactory: (server, key) => backend = MemoryBackend(server, key),
    );
    session.server.text = 'archive.example.com';
    session.keyInput.text = 'test-only';
    await session.connect();
    expect(session.api, same(backend));
    expect(session.account?['id'], 7);
    expect(subjects(session), ['From memory']);
    expect(session.folders.single.path, 'INBOX');
    await session.forgetConnection();
    expect(backend!.closed, isTrue);
  });

  test('disposing while mail loads does not throw', () async {
    await connectFresh();
    final slow = api.held['1:slow'] = Completer();
    session.search.text = 'slow';
    final slowLoad = session.load(1);
    final disposed = session;
    session = newSession();
    disposed.dispose();
    slow.complete(FakeArchiveApi.page('late'));
    await slowLoad;
  });
}
