import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/attachment_download.dart';

import 'attachment_download_test.dart' show DownloadClient, DownloadResponse;
import 'open_archiver_message_test.dart'
    show FakeOpenArchiver, detailFields, eml, fileA, mailA, sourceA, wire;

const storagePath = 'open-archiver/aaaa/agenda.txt';

Future<FakeOpenArchiver> opened([FakeOpenArchiver? value]) async {
  final api = value ?? FakeOpenArchiver();
  await api.accounts();
  await api.emails(sourceA, '', 1);
  await api.message(mailA);
  return api;
}

FakeOpenArchiver withAttachment(Map<String, Object?> attachment) =>
    FakeOpenArchiver(
      detail: wire({
        ...detailFields,
        'attachments': [attachment],
      }, utf8.encode(eml)),
    );

class ReloadableOpenArchiver extends FakeOpenArchiver {
  Uint8List? nextDetail;

  @override
  Future<T> send<T>(
    String path,
    Map<String, String>? query,
    Future<T> Function(Stream<List<int>>, int) read, {
    Duration? timeout,
  }) {
    final data = nextDetail ?? detail;
    return read(Stream.value(data), data.length);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late File destination;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('oa-attachment-test-');
    destination = File('${temporary.path}/agenda.txt');
  });
  tearDown(() async => temporary.delete(recursive: true));

  test(
    'saves through the storage route with X-API-KEY and the stated size',
    () async {
      final client = DownloadClient(
        DownloadResponse(
          Stream.fromIterable([List.filled(70, 65), List.filled(50, 66)]),
          -1,
        ),
      );
      final progress = <int>[];
      await HttpOverrides.runZoned(() async {
        final api = await opened();
        await api.downloadAttachment(
          mailA,
          fileA,
          destination,
          onProgress: progress.add,
        );
        expect(await destination.length(), 120);
        expect(progress, [70, 120]);
        expect(client.url!.path, '/api/v1/storage/download');
        expect(client.url!.queryParameters, {'path': storagePath});
        expect(client.request.followRedirects, isFalse);
        expect(client.request.recordedHeaders.values['X-API-KEY'], 'test-only');
        expect(
          client.request.recordedHeaders.values.containsKey(
            HttpHeaders.authorizationHeader,
          ),
          isFalse,
        );
        expect(client.closed, isTrue);
      }, createHttpClient: (_) => client);
    },
  );

  for (final (label, body, declared) in [
    ('short body', [List.filled(100, 65)], -1),
    ('long body', [List.filled(100, 65), List.filled(30, 65)], -1),
    ('mismatched Content-Length', [List.filled(120, 65)], 50),
  ]) {
    test('rejects a $label and deletes the partial file', () async {
      final response = DownloadResponse(Stream.fromIterable(body), declared);
      final client = DownloadClient(response);
      await HttpOverrides.runZoned(() async {
        final api = await opened();
        await expectLater(
          api.downloadAttachment(mailA, fileA, destination),
          throwsFormatException,
        );
        expect(await destination.exists(), isFalse);
        expect(client.closed, isTrue);
        if (declared >= 0) expect(response.listened, isFalse);
      }, createHttpClient: (_) => client);
    });
  }

  test(
    'refuses before any request when the attachment is unknown or too large',
    () async {
      final client = DownloadClient(DownloadResponse(const Stream.empty(), 0));
      await HttpOverrides.runZoned(() async {
        final api = await opened();
        for (final (email, file) in [
          (mailA, 'eeeeeeee-0000-4000-8000-00000000000e'),
          ('aaaaaaaa-0000-4000-8000-00000000000a', fileA),
        ]) {
          await expectLater(
            api.downloadAttachment(email, file, destination),
            throwsA(isA<ArchiveMessageRefused>()),
          );
        }
        await expectLater(
          api.downloadAttachment('../$mailA', fileA, destination),
          throwsFormatException,
        );
        await expectLater(
          api.downloadAttachment(mailA, '$fileA/x', destination),
          throwsFormatException,
        );

        final large = await opened(
          withAttachment({
            'id': fileA,
            'filename': 'big.bin',
            'sizeBytes': maxAttachmentDownloadBytes + 1,
            'storagePath': storagePath,
          }),
        );
        await expectLater(
          large.downloadAttachment(mailA, fileA, destination),
          throwsA(isA<AttachmentTooLarge>()),
        );
        expect(client.url, isNull);
        expect(await destination.exists(), isFalse);
      }, createHttpClient: (_) => client);
    },
  );

  test('reopening a message removes attachments no longer listed', () async {
    final api = ReloadableOpenArchiver();
    await opened(api);
    expect(api.attachmentStoragePath(fileA), storagePath);
    api.nextDetail = wire({
      ...detailFields,
      'attachments': <Object>[],
    }, utf8.encode(eml));
    await api.message(mailA);
    expect(api.attachmentStoragePath(fileA), isNull);
    await expectLater(
      api.downloadAttachment(mailA, fileA, destination),
      throwsA(isA<ArchiveMessageRefused>()),
    );
  });

  test('a malformed message does not register attachment handles', () async {
    final api = FakeOpenArchiver(
      detail: wire({...detailFields, 'subject': 42}, utf8.encode(eml)),
    );
    await api.accounts();
    await api.emails(sourceA, '', 1);
    await expectLater(api.message(mailA), throwsFormatException);
    expect(api.attachmentStoragePath(fileA), isNull);
    await expectLater(
      api.downloadAttachment(mailA, fileA, destination),
      throwsA(isA<ArchiveMessageRefused>()),
    );
  });

  test(
    'download helper refuses URLs outside the configured HTTPS server',
    () async {
      final client = DownloadClient(DownloadResponse(const Stream.empty(), 0));
      await HttpOverrides.runZoned(() async {
        final api = await opened();
        for (final url in [
          'https://other.example/file',
          'http://archive.example/file',
          'https://archive.example:444/file',
          'https://user@archive.example/file',
          'https://archive.example/file#fragment',
        ]) {
          await expectLater(
            api.downloadTo(Uri.parse(url), destination),
            throwsFormatException,
          );
        }
        expect(client.url, isNull);
        expect(await destination.exists(), isFalse);
      }, createHttpClient: (_) => client);
    },
  );

  test('rejects unsafe storage paths when the message opens', () async {
    for (final path in ['', 'a\nb', 'a\u0000b', 'x' * 1025]) {
      final api = withAttachment({
        'id': fileA,
        'sizeBytes': 1,
        'storagePath': path,
      });
      await api.accounts();
      await api.emails(sourceA, '', 1);
      await expectLater(api.message(mailA), throwsFormatException);
    }
  });
}
