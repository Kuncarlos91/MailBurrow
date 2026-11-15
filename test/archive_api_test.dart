import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';

void main() {
  test(
    'HTTP JSON decoding retains HTTPS auth, disabled redirects and client cleanup',
    () async {
      final client = JsonHttpClient(utf8.encode('[{"id":1}]'));
      var created = 0;
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://example.com/archive'),
          'test-only',
        );
        expect((await api.accounts()).map((account) => account.id), ['1']);
        expect(
          client.url.toString(),
          'https://example.com/archive/api/v1/accounts',
        );
        expect(client.request.followRedirects, isFalse);
        expect(
          client.request.recordedHeaders.values[HttpHeaders
              .authorizationHeader],
          'Bearer test-only',
        );
        expect(client.request.aborted, isFalse);
        expect(client.forceClosed, isFalse);
        await api.accounts();
        expect(created, 1, reason: 'API calls share one client');
        api.close();
        expect(client.forceClosed, isTrue);
      }, createHttpClient: (_) {
        created++;
        return client;
      });
    },
  );

  test(
    'oversized HTTP response aborts its request before body decoding',
    () async {
      final client = JsonHttpClient(
        [],
        declaredLength: maxApiResponseBytes + 1,
      );
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        await expectLater(
          api.accounts(),
          throwsA(isA<ArchiveResponseTooLarge>()),
        );
        expect(client.request.aborted, isTrue);
        expect(client.forceClosed, isFalse);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'closing a connection cancels non-mail requests and blocks reuse',
    () async {
      final client = PendingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final pending = api.accounts();
        final completion = expectLater(pending, throwsA(isA<HttpException>()));
        await Future<void>.delayed(Duration.zero);
        api.close();
        expect(client.forceClosed, isTrue);
        await completion;
        await expectLater(api.accounts(), throwsStateError);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'JSON reader handles chunked multibyte UTF-8 at its exact byte limit',
    () async {
      final bytes = utf8.encode('{"subject":"Café"}');
      final response = Stream<List<int>>.fromIterable(bytes.map((b) => [b]));
      final decoded = await decodeArchiveJson(
        response,
        byteLimit: bytes.length,
      );
      expect(decoded, {'subject': 'Café'});
    },
  );

  test(
    'JSON reader rejects declared and streamed oversized responses',
    () async {
      await expectLater(
        decodeArchiveJson(
          const Stream<List<int>>.empty(),
          contentLength: 17,
          byteLimit: 16,
        ),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
      await expectLater(
        decodeArchiveJson(
          Stream.fromIterable([List.filled(10, 32), List.filled(7, 32)]),
          byteLimit: 16,
        ),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
      expect(
        readableError(const ArchiveResponseTooLarge()),
        contains('too large'),
      );
    },
  );

  test(
    'JSON reader keeps malformed and invalid UTF-8 responses as safe failures',
    () async {
      for (final bytes in [
        utf8.encode('{private response'),
        [255],
      ]) {
        await expectLater(
          decodeArchiveJson(Stream.value(bytes)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'cancelling a mail search ends it without closing the shared client',
    () async {
      final client = PendingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final pending = api.emails('1', 'query', 1);
        final completion = expectLater(pending, throwsA(isA<HttpException>()));
        await Future<void>.delayed(Duration.zero);
        api.cancelEmailRequests();
        await completion;
        expect(client.forceClosed, isFalse);
        api.close();
        expect(client.forceClosed, isTrue);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'cancelling mail leaves a folder request on the same client running',
    () async {
      final client = RoutingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final mail = api.emails('1', 'query', 1);
        final mailDone = expectLater(mail, throwsA(isA<HttpException>()));
        final folders = api.folders('1');
        await Future<void>.delayed(Duration.zero);
        api.cancelEmailRequests();
        await mailDone;
        client
            .pending('/api/v1/accounts/1/folders')
            .complete(JsonHttpRequest(JsonHttpResponse(utf8.encode('[]'), 2)));
        expect(await folders, isEmpty);
        expect(client.forceClosed, isFalse);
        final cancelledMail = JsonHttpRequest(
          JsonHttpResponse(utf8.encode('{}'), 2),
        );
        client.pending('/api/v1/emails').complete(cancelledMail);
        await Future<void>.delayed(Duration.zero);
        expect(cancelledMail.aborted, isTrue);
        api.close();
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'cancelling mail after headers stops reading its body while folders load',
    () async {
      final client = RoutingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final mailBody = StreamingHttpResponse();
        final mail = api.emails('1', 'query', 1);
        final mailDone = expectLater(mail, throwsA(isA<HttpException>()));
        final folders = api.folders('1');
        client.pending('/api/v1/emails').complete(HeadersArrivedRequest(mailBody));
        await Future<void>.delayed(Duration.zero);
        mailBody.body.add(utf8.encode('{"items": ['));
        await Future<void>.delayed(Duration.zero);
        expect(mailBody.listened, isTrue);
        expect(mailBody.bodyCancelled, isFalse);

        api.cancelEmailRequests();
        await mailDone;
        await Future<void>.delayed(Duration.zero);
        expect(mailBody.bodyCancelled, isTrue);

        client
            .pending('/api/v1/accounts/1/folders')
            .complete(JsonHttpRequest(JsonHttpResponse(utf8.encode('[]'), 2)));
        expect(await folders, isEmpty);
        expect(client.forceClosed, isFalse);
        api.close();
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'a response that stalls after headers times out and stops reading',
    () async {
      final client = RoutingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://example.com'),
          'test-only',
          responseTimeout: const Duration(milliseconds: 50),
        );
        final mailBody = StreamingHttpResponse();
        final mail = api.emails('1', 'query', 1);
        final mailDone = expectLater(mail, throwsA(isA<TimeoutException>()));
        client.pending('/api/v1/emails').complete(HeadersArrivedRequest(mailBody));
        await Future<void>.delayed(Duration.zero);
        mailBody.body.add(utf8.encode('{"items": ['));
        await mailDone;
        await Future<void>.delayed(Duration.zero);
        expect(mailBody.bodyCancelled, isTrue);
        expect(client.forceClosed, isFalse);
        api.close();
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'an error status releases the unread body without closing the client',
    () async {
      final client = RoutingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final failedBody = StreamingHttpResponse(statusCode: 500);
        final accounts = api.accounts();
        final done = expectLater(accounts, throwsA(isA<ArchiveFailure>()));
        client.pending('/api/v1/accounts').complete(HeadersArrivedRequest(failedBody));
        await done;
        await Future<void>.delayed(Duration.zero);
        expect(failedBody.listened, isTrue);
        expect(failedBody.bodyCancelled, isTrue);
        expect(client.forceClosed, isFalse);
        api.close();
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'a request that finishes connecting after cancellation is aborted',
    () async {
      final client = RoutingHttpClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(Uri.parse('https://example.com'), 'test-only');
        final mail = api.emails('1', 'query', 1);
        final mailDone = expectLater(mail, throwsA(isA<HttpException>()));
        await Future<void>.delayed(Duration.zero);
        api.cancelEmailRequests();
        await mailDone;
        final lateRequest = JsonHttpRequest(JsonHttpResponse(utf8.encode('{}'), 2));
        client.pending('/api/v1/emails').complete(lateRequest);
        await Future<void>.delayed(Duration.zero);
        expect(lateRequest.aborted, isTrue);
        api.close();
      }, createHttpClient: (_) => client);
    },
  );
  test('accepts HTTPS servers and normalizes trailing slashes', () {
    expect(
      validateServer(' https://archive.example.com/ ').toString(),
      'https://archive.example.com',
    );
    expect(validateServer('https://archive.example.com/mail/').path, '/mail');
  });
  test('adds HTTPS to hostnames while retaining ports and base paths', () {
    expect(
      validateServer(' archive.example.ts.net/ ').toString(),
      'https://archive.example.ts.net',
    );
    expect(
      validateServer('archive.example.com:8443/mail/').toString(),
      'https://archive.example.com:8443/mail',
    );
    expect(validateServer('example.com').scheme, 'https');
  });
  test('rejects insecure and credential-bearing addresses', () {
    for (final value in [
      'http://example.com',
      'https://user:password@example.com',
      'https://example.com?key=secret',
      'https://example.com#fragment',
      '',
      '   ',
      'archive example.com',
      'example.com:99999',
      'http:example.com',
      'ftp://example.com',
      '//example.com',
      'user:password@example.com',
      'example.com?key=secret',
      'example.com#fragment',
    ]) {
      expect(() => validateServer(value), throwsFormatException);
    }
  });
  test('error messages never echo server responses or credentials', () {
    expect(
      readableError(const ArchiveFailure(401)),
      'Your API key was not accepted.',
    );
    expect(
      readableError(Exception('private-key')),
      isNot(contains('private-key')),
    );
  });
}

class PendingHttpClient implements HttpClient {
  final request = Completer<HttpClientRequest>();
  bool forceClosed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => request.future;
  @override
  void close({bool force = false}) {
    forceClosed = forceClosed || force;
    if (!request.isCompleted) {
      request.completeError(const HttpException('Cancelled test request'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class JsonHttpClient implements HttpClient {
  JsonHttpClient(List<int> bytes, {int? declaredLength})
    : request = JsonHttpRequest(
        JsonHttpResponse(bytes, declaredLength ?? bytes.length),
      );
  final JsonHttpRequest request;
  Uri? url;
  bool forceClosed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri value) async {
    url = value;
    return request;
  }

  @override
  void close({bool force = false}) {
    forceClosed = forceClosed || force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A response whose body arrives only when the test adds chunks, and which
/// records whether the app cancelled its subscription.
class StreamingHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  StreamingHttpResponse({this.statusCode = 200}) {
    body = StreamController<List<int>>(
      onListen: () => listened = true,
      onCancel: () => bodyCancelled = true,
    );
  }
  late final StreamController<List<int>> body;
  bool listened = false;
  bool bodyCancelled = false;
  @override
  final int statusCode;
  @override
  int get contentLength => -1;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A request that has finished sending; abort() after this point has no
/// effect, as documented for HttpClientRequest.
class HeadersArrivedRequest implements HttpClientRequest {
  HeadersArrivedRequest(this.response);
  final HttpClientResponse response;
  final recordedHeaders = RecordedHeaders();
  @override
  bool followRedirects = true;
  @override
  HttpHeaders get headers => recordedHeaders;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds each request open by path until the test completes it.
class RoutingHttpClient implements HttpClient {
  final _pending = <String, Completer<HttpClientRequest>>{};
  bool forceClosed = false;
  @override
  Duration? connectionTimeout;

  Completer<HttpClientRequest> pending(String path) =>
      _pending.putIfAbsent(path, Completer.new);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => pending(url.path).future;

  @override
  void close({bool force = false}) {
    forceClosed = forceClosed || force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class JsonHttpRequest implements HttpClientRequest {
  JsonHttpRequest(this.response);
  final JsonHttpResponse response;
  final recordedHeaders = RecordedHeaders();
  bool aborted = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  bool followRedirects = true;
  @override
  HttpHeaders get headers => recordedHeaders;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordedHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class JsonHttpResponse extends Stream<List<int>> implements HttpClientResponse {
  JsonHttpResponse(this.bytes, this.contentLength);
  final List<int> bytes;
  @override
  final int contentLength;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
