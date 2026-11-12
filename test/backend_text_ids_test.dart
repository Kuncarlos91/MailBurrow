import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/attachments.dart';
import 'package:mailburrow/screens/message_reader.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';

import 'support/fake_archive_backend.dart';

const firstId = 'aaaaaaaa-0000-4000-8000-000000000001';
const secondId = 'aaaaaaaa-0000-4000-8000-000000000002';
const messageId = 'bbbbbbbb-0000-4000-8000-000000000001';
const attachmentId = 'cccccccc-0000-4000-8000-000000000001';

class TextIdBackend extends FakeArchiveBackend {
  TextIdBackend(super.server, super.key);
  final requestedAccounts = <String>[];
  String? requestedMessage;

  @override
  Future<List<dynamic>> accounts() async => [
    {'id': firstId, 'emailAddress': 'one@example.com'},
    {'id': secondId, 'emailAddress': 'two@example.com'},
  ];

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async {
    requestedAccounts.add(accountId);
    return [];
  }

  @override
  Future<Map<String, dynamic>> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    requestedAccounts.add(accountId);
    return {
      'items': [
        {'id': messageId, 'subject': 'Opaque ID message'},
      ],
      'page': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> message(String id) async {
    requestedMessage = id;
    return {
      'id': id,
      'subject': 'Opaque ID message',
      'textBody': 'Fictional body',
      'attachments': [
        {'id': attachmentId, 'fileName': 'sample.txt', 'size': 4},
      ],
    };
  }
}

class RecordingWireApi extends ArchiveApi {
  RecordingWireApi() : super(Uri.parse('https://archive.example'), 'test-only');
  String? path;
  Map<String, String>? query;

  @override
  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    this.path = path;
    this.query = query;
    return path.endsWith('/folders') ? <dynamic>[] : <String, dynamic>{};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ID normalization retains text and rejects non-identifiers', () {
    expect(archiveId(7), '7');
    expect(archiveId(firstId), firstId);
    expect(archiveId('0007'), '0007', reason: 'text IDs are opaque');
    for (final value in [null, true, 1.5, '', <Object>[], <String, Object>{}]) {
      expect(() => archiveId(value), throwsFormatException);
    }
    expect(() => MailAttachment.fromJson({'id': null}), throwsFormatException);
  });

  test(
    'UUID account selection survives switching and restoration unchanged',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final backend = TextIdBackend(
        Uri.parse('https://archive.example'),
        'test-only',
      );
      ArchiveSession create() => ArchiveSession(apiFactory: (_, _) => backend);
      var session = create();
      session.server.text = backend.server.toString();
      session.keyInput.text = backend.key;
      await session.connect();
      expect(session.account?['id'], firstId);
      await session.switchAccount({
        'id': secondId,
        'emailAddress': 'two@example.com',
      });
      expect(session.account?['id'], secondId);
      expect(backend.requestedAccounts, containsAll([firstId, secondId]));
      final saved = jsonDecode(
        (await const FlutterSecureStorage().read(key: 'connection'))!,
      );
      expect(saved['accountId'], secondId);
      session.dispose();
      session = create();
      await session.restore();
      expect(session.account?['id'], secondId);
      session.dispose();
    },
  );

  testWidgets('reader and attachment controls retain opaque text IDs', (
    tester,
  ) async {
    final backend = TextIdBackend(
      Uri.parse('https://archive.example'),
      'test-only',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MessageReader(api: backend, id: messageId),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(backend.requestedMessage, messageId);
    final controls = tester.widget<MessageAttachments>(
      find.byType(MessageAttachments),
    );
    expect(controls.emailId, messageId);
    expect(controls.attachments.single.id, attachmentId);
    expect(tester.takeException(), isNull);
  });

  test(
    'Mail-Archiver keeps numeric wire IDs and rejects opaque/path input',
    () async {
      final api = RecordingWireApi();
      await api.folders('7');
      expect(api.path, 'accounts/7/folders');
      await api.message('42');
      expect(api.path, 'emails/42');
      await api.emails('7', '', 1);
      expect(api.query?['accountId'], '7');
      for (final id in ['', '../42', '42/other', '42?key=x', firstId]) {
        api.path = null;
        await expectLater(api.message(id), throwsFormatException);
        await expectLater(api.folders(id), throwsFormatException);
        await expectLater(api.emails(id, '', 1), throwsFormatException);
        await expectLater(
          api.downloadAttachment(id, '1', File('unused')),
          throwsFormatException,
        );
        await expectLater(
          api.downloadAttachment('1', id, File('unused')),
          throwsFormatException,
        );
        expect(
          api.path,
          isNull,
          reason: 'invalid IDs never reach the transport',
        );
      }
      api.close();
    },
  );
}
