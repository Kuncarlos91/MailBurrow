import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/attachment_download.dart';

void main() {
  late Directory temporary;
  late File destination;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('attachment-test-');
    destination = File('${temporary.path}/sample.txt');
  });
  tearDown(() async => temporary.delete(recursive: true));

  for (final size in [0, 4]) {
    test('accepts $size bytes at or below the exact byte cap', () async {
      final response = DownloadResponse(
        Stream.value(List.filled(size, 65)),
        size,
      );
      final client = DownloadClient(response);
      final progress = <int>[];
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://example.com/archive'),
          'test-only',
          attachmentByteLimit: 4,
        );
        await api.downloadAttachment(
          1,
          2,
          destination,
          onProgress: progress.add,
        );
        expect(await destination.length(), size);
        expect(
          client.url.toString(),
          'https://example.com/archive/api/v1/emails/1/attachments/2',
        );
        expect(client.request.followRedirects, isFalse);
        expect(
          client.request.recordedHeaders.values[HttpHeaders
              .authorizationHeader],
          'Bearer test-only',
        );
        expect(client.closed, isTrue);
      }, createHttpClient: (_) => client);
    });
  }

  test(
    'unknown length counts every chunk and reports actual written bytes',
    () async {
      final client = DownloadClient(
        DownloadResponse(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          -1,
        ),
      );
      final progress = <int>[];
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://example.com'),
          'test-only',
          attachmentByteLimit: 4,
        );
        await api.downloadAttachment(
          1,
          2,
          destination,
          onProgress: progress.add,
        );
        expect(await destination.readAsBytes(), [1, 2, 3, 4]);
        expect(progress, [2, 4]);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'rejects oversized declared body before creating a download file',
    () async {
      final response = DownloadResponse(Stream.value([1]), 5);
      final client = DownloadClient(response);
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://example.com'),
          'test-only',
          attachmentByteLimit: 4,
        );
        await expectLater(
          api.downloadAttachment(1, 2, destination),
          throwsA(isA<AttachmentTooLarge>()),
        );
        expect(response.listened, isFalse);
        expect(await destination.exists(), isFalse);
        expect(client.closed, isTrue);
      }, createHttpClient: (_) => client);
    },
  );

  for (final declared in [-1, 1]) {
    test(
      'streamed byte cap rejects oversize despite declared length $declared',
      () async {
        final response = DownloadResponse(
          Stream.fromIterable([
            [1, 2],
            [3, 4, 5],
          ]),
          declared,
        );
        final client = DownloadClient(response);
        final progress = <int>[];
        await HttpOverrides.runZoned(() async {
          final api = ArchiveApi(
            Uri.parse('https://example.com'),
            'test-only',
            attachmentByteLimit: 4,
          );
          await expectLater(
            api.downloadAttachment(1, 2, destination, onProgress: progress.add),
            throwsA(isA<AttachmentTooLarge>()),
          );
          expect(progress, [2]);
          expect(await destination.exists(), isFalse);
          expect(client.closed, isTrue);
        }, createHttpClient: (_) => client);
      },
    );
  }

  test(
    'total deadline interrupts a continuous trickle despite idle activity',
    () async {
      final controller = StreamController<List<int>>();
      var written = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => controller.add([1]),
      );
      final client = DownloadClient(DownloadResponse(controller.stream, -1));
      try {
        await HttpOverrides.runZoned(() async {
          final api = ArchiveApi(
            Uri.parse('https://example.com'),
            'test-only',
            attachmentByteLimit: 100000,
            attachmentDeadline: const Duration(milliseconds: 180),
            attachmentIdleTimeout: const Duration(milliseconds: 90),
          );
          await expectLater(
            api.downloadAttachment(
              1,
              2,
              destination,
              onProgress: (bytes) => written = bytes,
            ),
            throwsA(isA<TimeoutException>()),
          );
          expect(written, greaterThan(0));
          expect(client.closed, isTrue);
          expect(await destination.exists(), isFalse);
        }, createHttpClient: (_) => client);
      } finally {
        timer.cancel();
        unawaited(controller.close());
      }
    },
  );

  test('total deadline covers a request waiting for response headers', () async {
    final response = Completer<HttpClientResponse>();
    final client = DownloadClient(null, response: response.future);
    await HttpOverrides.runZoned(() async {
      final api = ArchiveApi(
        Uri.parse('https://example.com'),
        'test-only',
        attachmentDeadline: const Duration(milliseconds: 25),
      );
      await expectLater(
        api.downloadAttachment(1, 2, destination),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.closed, isTrue);
      expect(await destination.exists(), isFalse);
      // A late connection error remains observed after the timed-out operation.
      response.completeError(const SocketException('Synthetic late failure'));
      await Future<void>.delayed(Duration.zero);
    }, createHttpClient: (_) => client);
  });

  test(
    'idle timeout interrupts a stalled response and removes its partial file',
    () async {
      final controller = StreamController<List<int>>()..add([1]);
      final client = DownloadClient(DownloadResponse(controller.stream, -1));
      try {
        await HttpOverrides.runZoned(() async {
          final api = ArchiveApi(
            Uri.parse('https://example.com'),
            'test-only',
            attachmentIdleTimeout: const Duration(milliseconds: 30),
          );
          await expectLater(
            api.downloadAttachment(1, 2, destination),
            throwsA(isA<TimeoutException>()),
          );
          expect(await destination.exists(), isFalse);
          expect(client.closed, isTrue);
        }, createHttpClient: (_) => client);
      } finally {
        unawaited(controller.close());
      }
    },
  );

  test(
    'cancel removes partial file without cancelling another request or connection',
    () async {
      final response = Completer<HttpClientResponse>();
      final accountClient = DownloadClient(null, response: response.future);
      final chunks = StreamController<List<int>>()..add([1, 2]);
      final downloadClient = DownloadClient(
        DownloadResponse(chunks.stream, -1),
      );
      // API calls share one client; the follow-up call reuses it.
      accountClient.followUps.add(
        DownloadResponse(Stream.value(utf8.encode('[]')), 2),
      );
      final clients = [accountClient, downloadClient].iterator;
      final transfer = AttachmentDownload();
      final started = Completer<void>();
      try {
        await HttpOverrides.runZoned(
          () async {
            final api = ArchiveApi(
              Uri.parse('https://example.com'),
              'test-only',
            );
            final pendingAccount = api.accounts();
            final result = api.downloadAttachment(
              1,
              2,
              destination,
              transfer: transfer,
              onProgress: (_) {
                if (!started.isCompleted) started.complete();
              },
            );
            final check = expectLater(
              result,
              throwsA(isA<AttachmentDownloadCancelled>()),
            );
            await started.future;
            transfer.cancel();
            transfer.cancel();
            await check;
            expect(downloadClient.closed, isTrue);
            expect(accountClient.closed, isFalse);
            expect(await destination.exists(), isFalse);
            response.complete(
              DownloadResponse(Stream.value(utf8.encode('[]')), 2),
            );
            expect(await pendingAccount, isEmpty);
            expect(await api.accounts(), isEmpty);
            api.close();
          },
          createHttpClient: (_) {
            expect(clients.moveNext(), isTrue);
            return clients.current;
          },
        );
      } finally {
        unawaited(chunks.close());
      }
    },
  );

  test('cancel before start creates neither request nor file', () async {
    final transfer = AttachmentDownload()..cancel();
    var created = false;
    await HttpOverrides.runZoned(
      () async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        await expectLater(
          api.downloadAttachment(1, 2, destination, transfer: transfer),
          throwsA(isA<AttachmentDownloadCancelled>()),
        );
        expect(created, isFalse);
        expect(await destination.exists(), isFalse);
      },
      createHttpClient: (_) {
        created = true;
        throw StateError('Unexpected client');
      },
    );
  });

  test(
    'non-200 response never writes server error contents to a file',
    () async {
      final response = DownloadResponse(
        Stream.value([1, 2]),
        2,
        statusCode: 403,
      );
      final client = DownloadClient(response);
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        await expectLater(
          api.downloadAttachment(1, 2, destination),
          throwsA(
            isA<ArchiveFailure>().having(
              (error) => error.status,
              'status',
              403,
            ),
          ),
        );
        expect(response.listened, isFalse);
        expect(await destination.exists(), isFalse);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'write failure closes the output/client and deletes the failed private file',
    () async {
      final file = FailingFile();
      final client = DownloadClient(DownloadResponse(Stream.value([1, 2]), 2));
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        await expectLater(
          api.downloadAttachment(1, 2, file),
          throwsA(isA<FileSystemException>()),
        );
        expect(file.output.closed, isTrue);
        expect(file.deleted, isTrue);
        expect(client.closed, isTrue);
      }, createHttpClient: (_) => client);
    },
  );
}

class DownloadClient implements HttpClient {
  DownloadClient(
    HttpClientResponse? value, {
    Future<HttpClientResponse>? response,
  }) : request = DownloadRequest(response ?? Future.value(value!));
  final DownloadRequest request;
  final followUps = <HttpClientResponse>[];
  var _requests = 0;
  Uri? url;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri value) async {
    url = value;
    if (_requests++ == 0) return request;
    return DownloadRequest(Future.value(followUps.removeAt(0)));
  }

  @override
  void close({bool force = false}) {
    closed = closed || force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadRequest implements HttpClientRequest {
  DownloadRequest(this.response);
  final Future<HttpClientResponse> response;
  final recordedHeaders = DownloadHeaders();
  @override
  bool followRedirects = true;
  @override
  HttpHeaders get headers => recordedHeaders;
  bool aborted = false;
  @override
  Future<HttpClientResponse> close() => response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadResponse extends Stream<List<int>> implements HttpClientResponse {
  DownloadResponse(this.body, this.contentLength, {this.statusCode = 200});
  final Stream<List<int>> body;
  bool listened = false;
  @override
  final int contentLength;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listened = true;
    return body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingFile implements File {
  final output = FailingOutput();
  bool deleted = false;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      output;
  @override
  Future<File> delete({bool recursive = false}) async {
    deleted = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingOutput implements RandomAccessFile {
  bool closed = false;
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async => throw const FileSystemException('Synthetic storage failure');
  @override
  Future<RandomAccessFile> close() async {
    closed = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
