/// Byte and timing meter for the Bichon phone probe. PROBE ONLY.
///
/// Wraps the real HTTP client so every response chunk the app's transport
/// receives is counted with a monotonic timestamp. It records numbers and
/// the request's last path segment class only (never hosts, tokens, IDs or
/// bodies).
library;

import 'dart:async';
import 'dart:io';

class Chunk {
  Chunk(this.kind, this.micros, this.bytes);
  final String kind;
  final int micros, bytes;
}

/// Classifies a request by its API route only.
String routeKind(Uri url) {
  final path = url.path;
  for (final kind in [
    'search-messages',
    'message-content',
    'download-attachment',
    'envelope',
    'list-mailboxes',
    'minimal-account-list',
  ]) {
    if (path.contains('/api/v1/$kind')) return kind;
  }
  return 'other';
}

class Meter {
  final clock = Stopwatch()..start();
  final chunks = <Chunk>[];
  int get now => clock.elapsedMicroseconds;

  void record(String kind, int bytes) => chunks.add(Chunk(kind, now, bytes));

  int bytes(String kind, {int afterMicros = -1}) => chunks
      .where((c) => c.kind == kind && c.micros > afterMicros)
      .fold(0, (sum, c) => sum + c.bytes);

  int? lastMicros(String kind) {
    final of = chunks.where((c) => c.kind == kind);
    return of.isEmpty ? null : of.last.micros;
  }

  void clear() => chunks.clear();
}

class MeteredHttpClient implements HttpClient {
  MeteredHttpClient(this.inner, this.meter);
  final HttpClient inner;
  final Meter meter;

  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      MeteredRequest(await inner.getUrl(url), meter, routeKind(url));
  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      MeteredRequest(await inner.postUrl(url), meter, routeKind(url));
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('probe client: ${invocation.memberName}');
}

class MeteredRequest implements HttpClientRequest {
  MeteredRequest(this.inner, this.meter, this.kind);
  final HttpClientRequest inner;
  final Meter meter;
  final String kind;

  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  int get contentLength => inner.contentLength;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  String get method => inner.method;
  @override
  Uri get uri => inner.uri;
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      inner.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> get done async =>
      MeteredResponse(await inner.done, meter, kind);
  @override
  Future<HttpClientResponse> close() async =>
      MeteredResponse(await inner.close(), meter, kind);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('probe request: ${invocation.memberName}');
}

class MeteredResponse extends Stream<List<int>> implements HttpClientResponse {
  MeteredResponse(this.inner, this.meter, this.kind);
  final HttpClientResponse inner;
  final Meter meter;
  final String kind;

  @override
  int get statusCode => inner.statusCode;
  @override
  int get contentLength => inner.contentLength;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get isRedirect => inner.isRedirect;
  @override
  String get reasonPhrase => inner.reasonPhrase;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  HttpClientResponseCompressionState get compressionState =>
      inner.compressionState;
  @override
  List<RedirectInfo> get redirects => inner.redirects;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => inner
      // Count inside a mapped stream: listeners such as StreamIterator swap
      // the subscription's data handler later, which would skip a wrapper.
      .map((data) {
        meter.record(kind, data.length);
        return data;
      })
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('probe response: ${invocation.memberName}');
}
