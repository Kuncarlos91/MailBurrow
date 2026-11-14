import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'archive_backend.dart';
import 'archive_capabilities.dart';
import 'archive_models.dart';
import 'archive_errors.dart';
import 'search_filters.dart';
import 'attachment_download.dart';

// Preserve existing imports while consumers migrate to the shared contract.
export 'archive_models.dart';
export 'archive_errors.dart';

// Mail-Archiver uses numeric wire IDs. Keep that restriction in its adapter,
// rather than imposing it on every backend or interpolating opaque path input.
String _mailArchiverId(String id) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(id)) {
    throw const FormatException('Invalid Mail-Archiver identifier.');
  }
  return id;
}

Uri validateServer(String value) {
  final input = value.trim();
  if (input.isEmpty || RegExp(r'\s').hasMatch(input)) {
    throw const FormatException('Use an HTTPS server address.');
  }
  final hasProtocol = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(input);
  final uri = Uri.parse(hasProtocol ? input : 'https://$input');
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Use an HTTPS server address.');
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

// Bound server responses before allocating JSON objects or preparing email HTML.
const maxApiResponseBytes = 8 * 1024 * 1024;

Future<dynamic> decodeArchiveJson(
  Stream<List<int>> response, {
  int contentLength = -1,
  int byteLimit = maxApiResponseBytes,
}) async {
  if (byteLimit < 1) throw ArgumentError.value(byteLimit);
  if (contentLength > byteLimit) throw const ArchiveResponseTooLarge();
  final buffer = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response) {
    if (chunk.length > byteLimit - length) {
      throw const ArchiveResponseTooLarge();
    }
    length += chunk.length;
    buffer.add(chunk);
  }
  final bytes = buffer.takeBytes();
  return _decodeArchiveBytes(bytes);
}

Future<dynamic> _decodeArchiveBytes(Uint8List bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)));

/// How long to wait for a connection to the server, including the address
/// lookup. With a VPN such as Tailscale still up while the device is offline,
/// connection attempts fail only at this limit, so it is kept short. Once
/// connected, the request and response limits apply as before.
const archiveConnectTimeout = Duration(seconds: 10);

/// The Mail-Archiver implementation of [ArchiveBackend], using its read-only
/// REST API under `/api/v1/`.
///
/// It also owns the shared HTTPS transport: one pooled client, disabled
/// redirects, response size and time limits, and per-call cancellation.
/// Another backend on the same transport extends it and overrides
/// [authorize], [isMailRequest] and the backend methods; see
/// `OpenArchiverApi`.
class ArchiveApi implements ArchiveBackend {
  ArchiveApi(
    this.server,
    this.key, {
    this.attachmentByteLimit = maxAttachmentDownloadBytes,
    this.attachmentDeadline = attachmentDownloadDeadline,
    this.attachmentIdleTimeout = attachmentDownloadIdleTimeout,
    this.responseTimeout = const Duration(seconds: 30),
  });
  final int attachmentByteLimit;
  final Duration attachmentDeadline, attachmentIdleTimeout;

  /// Time allowed to read and decode an API response body after headers.
  final Duration responseTimeout;
  @override
  final Uri server;
  @override
  final String key;

  @override
  ArchiveCapabilities get capabilities => ArchiveCapabilities.full;

  // One client per connection lets API calls reuse TLS connections.
  // Attachment downloads keep their own client in [_clients].
  HttpClient? _apiClient;
  final _calls = <_ApiCall>{};
  final _clients = <HttpClient>{};
  bool _closed = false;

  @override
  void close() {
    _closed = true;
    for (final call in _calls.toList()) {
      call.cancel();
    }
    _calls.clear();
    _apiClient?.close(force: true);
    _apiClient = null;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  /// Cancels mail list and search requests only; folder, account and
  /// message requests continue on the shared connection.
  @override
  void cancelEmailRequests() {
    for (final call in _calls.where((call) => call.isMail).toList()) {
      call.cancel();
    }
  }

  /// Adds this server's credential to [request].
  void authorize(HttpClientRequest request) =>
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');

  /// Whether a request to [path] is a mail list or search, which
  /// [cancelEmailRequests] stops.
  bool isMailRequest(String path) => path == 'emails';

  Future<dynamic> get(String path, [Map<String, String>? query]) => send(
    path,
    query,
    (body, contentLength) =>
        decodeArchiveJson(body, contentLength: contentLength),
  );

  /// Sends a GET to [path] on the shared transport and hands the response
  /// body to [read], which owns its size limits. [timeout] bounds reading
  /// the body after the headers arrive; it defaults to [responseTimeout].
  Future<T> send<T>(
    String path,
    Map<String, String>? query,
    Future<T> Function(Stream<List<int>> body, int contentLength) read, {
    Duration? timeout,
  }) async {
    if (_closed) throw StateError('Archive connection closed');
    validateServer(server.toString());
    final client = _apiClient ??= HttpClient()
      ..connectionTimeout = archiveConnectTimeout;
    final call = _ApiCall(isMail: isMailRequest(path));
    _calls.add(call);
    var finished = false;
    try {
      final url = server.replace(
        path: '${server.path}/api/v1/$path',
        queryParameters: query,
      );
      Future<HttpClientRequest> open() async {
        final request = await client.getUrl(url);
        call.attach(request);
        return request;
      }

      final request = await call.guard(
        open().timeout(archiveConnectTimeout),
      );
      request.followRedirects = false;
      authorize(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await call.guard(
        request.close().timeout(const Duration(seconds: 20)),
      );
      // Once headers arrive, abort() no longer has any effect; the body is
      // read through a subscription this call owns so cancelling stops it.
      final body = call.trackBody(response);
      if (response.statusCode != 200) throw ArchiveFailure(response.statusCode);
      final result = await call.guard(
        read(body, response.contentLength).timeout(timeout ?? responseTimeout),
      );
      finished = true;
      return result;
    } finally {
      _calls.remove(call);
      // A failed, timed-out or cancelled call stops reading its response and
      // drops that connection instead of returning it to the pool half-read.
      if (!finished) call.cancel();
    }
  }

  @override
  Future<List<ArchiveAccount>> accounts() async {
    final result = await get('accounts');
    if (result is! List<dynamic>) {
      throw const FormatException('Invalid account response');
    }
    return [for (final item in result) ArchiveAccount.fromJson(item)];
  }

  @override
  Future<ArchiveStats> stats() async => ArchiveStats.fromJson(await get('stats'));
  @override
  Future<List<ArchiveFolder>> folders(String id) async => flattenFolders(
    await get('accounts/${_mailArchiverId(id)}/folders') as List<dynamic>,
  );
  @override
  Future<MailPage> emails(
    String id,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => MailPage.fromJson(
    await get('emails', {
      'accountId': _mailArchiverId(id),
      'q': query,
      'page': '$page',
      'pageSize': '25',
      ...filters.parameters,
      'folder': ?folder,
    }),
  );
  @override
  Future<MailMessage> message(String id) async =>
      MailMessage.fromJson(await get('emails/${_mailArchiverId(id)}'));

  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) async {
    if (_closed) throw StateError('Archive connection closed');
    _mailArchiverId(emailId);
    _mailArchiverId(attachmentId);
    await downloadTo(
      server.replace(
        path: '${server.path}/api/v1/emails/$emailId/attachments/$attachmentId',
      ),
      destination,
      transfer: transfer,
      onProgress: onProgress,
    );
  }

  /// Streams [url] into [destination] on a client of its own, within the
  /// attachment size, deadline and idle limits, deleting a partial file on
  /// any failure or cancellation. [expectedBytes], when the server states an
  /// attachment's size, is enforced as an exact length. The URL must use
  /// the configured server's HTTPS origin without user information or a fragment.
  Future<void> downloadTo(
    Uri url,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
    int? expectedBytes,
  }) async {
    if (_closed) throw StateError('Archive connection closed');
    validateServer(server.toString());
    if (url.scheme != server.scheme ||
        url.host != server.host ||
        url.port != server.port ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const FormatException('Invalid attachment URL');
    }

    if (expectedBytes != null && expectedBytes < 0) {
      throw ArgumentError.value(expectedBytes, 'expectedBytes');
    }
    if (expectedBytes != null && expectedBytes > attachmentByteLimit) {
      throw const AttachmentTooLarge();
    }
    if (attachmentByteLimit < 1 ||
        attachmentDeadline <= Duration.zero ||
        attachmentIdleTimeout <= Duration.zero) {
      throw ArgumentError('Invalid attachment download limits');
    }
    final active = transfer ?? AttachmentDownload();
    active.throwIfStopped();
    final client = HttpClient()
      ..connectionTimeout = archiveConnectTimeout;
    _clients.add(client);
    void stopClient() => client.close(force: true);
    active.addStopListener(stopClient);
    final deadline = Timer(attachmentDeadline, active.expire);
    RandomAccessFile? output;
    StreamIterator<List<int>>? chunks;
    var opened = false, completed = false;
    try {
      final request = await active.wait(
        client.getUrl(url).timeout(archiveConnectTimeout),
      );
      request.followRedirects = false;
      authorize(request);
      final response = await active.wait(
        request.close().timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) throw ArchiveFailure(response.statusCode);
      if (response.contentLength > attachmentByteLimit) {
        throw const AttachmentTooLarge();
      }
      if (expectedBytes != null &&
          response.contentLength >= 0 &&
          response.contentLength != expectedBytes) {
        throw const FormatException('Attachment size does not match');
      }
      active.throwIfStopped();
      output = await destination.open(mode: FileMode.write);
      opened = true;
      active.throwIfStopped();
      chunks = StreamIterator(response.timeout(attachmentIdleTimeout));
      var received = 0;
      while (await active.wait(chunks.moveNext())) {
        final chunk = chunks.current;
        if (chunk.length > attachmentByteLimit - received) {
          throw const AttachmentTooLarge();
        }
        if (expectedBytes != null && chunk.length > expectedBytes - received) {
          throw const FormatException('Attachment size does not match');
        }
        // Serialize file writes: never close/delete while a write is pending.
        await output.writeFrom(chunk);
        active.throwIfStopped();
        received += chunk.length;
        onProgress?.call(received);
      }
      active.throwIfStopped();
      if (expectedBytes != null && received != expectedBytes) {
        throw const FormatException('Attachment size does not match');
      }
      await output.flush();
      await output.close();
      output = null;
      active.throwIfStopped();
      completed = true;
    } finally {
      deadline.cancel();
      active.removeStopListener(stopClient);
      _clients.remove(client);
      client.close(force: true);
      try {
        await chunks?.cancel();
      } catch (_) {}
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (opened && !completed) {
        try {
          await destination.delete();
        } catch (_) {
          // The caller also attempts private temporary-directory cleanup.
        }
      }
    }
  }
}

List<ArchiveFolder> flattenFolders(List<dynamic> nodes, [int depth = 0]) {
  final result = <ArchiveFolder>[];
  for (final item in nodes) {
    final node = item as Map<String, dynamic>;
    result.add(
      ArchiveFolder(
        node['name'] as String,
        node['fullPath'] as String,
        node['totalCount'] as int,
        depth,
      ),
    );
    result.addAll(
      flattenFolders(node['children'] as List<dynamic>? ?? [], depth + 1),
    );
  }
  return result;
}

/// One API request on the shared client. Cancelling stops the caller's wait
/// at once. Before headers it aborts the request, including one still
/// connecting; after headers it cancels the response body subscription,
/// which [HttpClientRequest.abort] can no longer do.
class _ApiCall {
  _ApiCall({required this.isMail}) {
    _cancelled.future.ignore();
  }
  final bool isMail;
  final _cancelled = Completer<Never>();
  HttpClientRequest? _request;
  Stream<List<int>>? _bodySource;
  StreamSubscription<List<int>>? _bodySubscription;
  StreamController<List<int>>? _body;
  bool _bodyListened = false;

  bool get cancelled => _cancelled.isCompleted;

  void attach(HttpClientRequest request) {
    _request = request;
    if (cancelled) request.abort();
  }

  /// Returns the response body as a stream whose source subscription this
  /// call can cancel without touching other calls on the shared client.
  Stream<List<int>> trackBody(Stream<List<int>> source) {
    _bodySource = source;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () {
        if (cancelled) {
          _stopBody();
          return;
        }
        _bodyListened = true;
        _bodySubscription = source.listen(
          body.add,
          onError: body.addError,
          onDone: body.close,
        );
      },
      onPause: () => _bodySubscription?.pause(),
      onResume: () => _bodySubscription?.resume(),
      onCancel: () {
        final subscription = _bodySubscription;
        _bodySubscription = null;
        return subscription?.cancel();
      },
    );
    _body = body;
    return body.stream;
  }

  void _stopBody() {
    final source = _bodySource;
    if (source == null) return;
    _bodySource = null;
    final subscription = _bodySubscription;
    _bodySubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    } else if (!_bodyListened) {
      // Never read: subscribe and cancel so the connection is released.
      _bodyListened = true;
      unawaited(source.listen(null, onError: (_) {}).cancel());
    }
    final body = _body;
    _body = null;
    if (body != null && body.hasListener && !body.isClosed) {
      body.addError(const HttpException('Request cancelled'));
      unawaited(body.close());
    }
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.completeError(const HttpException('Request cancelled'));
    _request?.abort();
    _stopBody();
  }

  Future<T> guard<T>(Future<T> future) =>
      Future.any<T>([future, _cancelled.future]);
}
