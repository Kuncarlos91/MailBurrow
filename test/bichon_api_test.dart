import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/bichon_api.dart';
import 'package:mailburrow/message_load.dart';
import 'package:mailburrow/search_filters.dart';

// Fictional fixtures shaped like Bichon 2.4.2 Community responses.
const alex = 579812555935764;
const bakery = 1323817549755429;
const inbox = 6510112620251780;
const family = 5728395994606390;
const envA = '6781e159-ff59-4c2d-849e-82b840376898';
const envB = '0b0c1d2e-0000-4000-8000-000000000002';
const hash = '7f858a877caecdf93a4a392e4890cbc8f5f9ec313a331384e39d87676a00dd2b';

Map<String, Object?> envelope(
  String id, {
  int account = alex,
  int mailbox = inbox,
  int regular = 0,
}) => {
  'id': id,
  'account_id': account,
  'account_email': 'alex.rivera@example.com',
  'mailbox_id': mailbox,
  'mailbox_name': 'INBOX',
  'subject': 'Book club: next pick',
  'from': 'friend@example.com',
  'from_name': 'Sam Friend',
  'to': ['alex.rivera@example.com'],
  'date': 1793178900000,
  'attachment_count': regular + 1,
  'regular_attachment_count': regular,
  'preview': 'Fictional preview text',
  'tags': null,
};

class Sent {
  Sent(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, Object> headers;
  final List<int> body;
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
}

typedef Handler = (int, List<int>) Function(Sent request);

/// Routes requests by path below /api/v1/ and records each one.
class FakeBichonClient implements HttpClient {
  FakeBichonClient(this.routes);
  final Map<String, Handler> routes;
  final sent = <Sent>[];

  /// Paths whose responses wait until the test completes their gate.
  final holds = <String, Completer<void>>{};
  @override
  Duration? connectionTimeout;

  Future<HttpClientRequest> _open(String method, Uri url) async =>
      FakeRequest(this, method, url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  (int, List<int>) respond(Sent request) {
    final path = request.url.path.replaceFirst('/api/v1/', '');
    for (final MapEntry(:key, :value) in routes.entries) {
      if (path == key ||
          (key.endsWith('*') &&
              path.startsWith(key.substring(0, key.length - 1)))) {
        return value(request);
      }
    }
    return (404, utf8.encode('{"message":"not found","code":404}'));
  }
}

(int, List<int>) json(Object? value) => (200, utf8.encode(jsonEncode(value)));

class FakeHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this.client, this.method, this.uri);
  final FakeBichonClient client;
  @override
  final String method;
  @override
  final Uri uri;
  final fakeHeaders = FakeHeaders();
  final body = <int>[];
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  @override
  HttpHeaders get headers => fakeHeaders;
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  Future<HttpClientResponse> close() async {
    expect(followRedirects, isFalse, reason: 'redirects must be disabled');
    final sent = Sent(method, uri, {
      ...fakeHeaders.values,
      if (fakeHeaders.contentType != null)
        'content-type': fakeHeaders.contentType.toString(),
    }, List.of(body));
    client.sent.add(sent);
    final gate = client.holds[uri.path.replaceFirst('/api/v1/', '')];
    if (gate != null) await gate.future;
    final (status, bytes) = client.respond(sent);
    return FakeResponse(status, bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;
  @override
  int get contentLength => bytes.length;
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

final server = Uri.parse('https://bichon.example:9443');

final throwsUnsupported = throwsA(isA<ArchiveUnsupportedResponse>());

Future<T> withClient<T>(
  FakeBichonClient client,
  Future<T> Function(BichonApi api) body,
) => HttpOverrides.runZoned(
  () => body(BichonApi(server, 'test-only-token')),
  createHttpClient: (_) => client,
);

final mailboxes = {
  'status': 'ready',
  'mailboxes': [
    {
      'id': family,
      'account_id': alex,
      'name': 'INBOX/Family',
      'delimiter': '/',
      'exists': 0,
      'attributes': [],
    },
    {
      'id': inbox,
      'account_id': alex,
      'name': 'INBOX',
      'delimiter': '/',
      'exists': 0,
      'attributes': [],
    },
  ],
};

Map<String, Object?> attachmentFixture() => {
  'file_type': 'image/png',
  'inline': false,
  'filename': 'fictional.png',
  'size': 412,
  'content_hash': hash,
};

class HeldBichon extends BichonApi {
  HeldBichon() : super(server, 'test-only-token');
  final started = Completer<void>();
  final release = Completer<void>();
  late Future<MailMessage> operation;
  @override
  Future<MailMessage> message(String id) => operation = super.message(id);
  @override
  Future<T> send<T>(
    String path,
    Map<String, String>? query,
    Future<T> Function(Stream<List<int>>, int) read, {
    Duration? timeout,
    List<int>? requestBody,
  }) async {
    Object data = envelope(envA);
    if (path.startsWith('message-content/')) {
      started.complete();
      await release.future;
      data = {
        'text': 'body',
        'attachments': [attachmentFixture()],
      };
    }
    final bytes = json(data).$2;
    return read(Stream.value(bytes), bytes.length);
  }
}

void main() {
  test(
    'unknown, invalid-message and stale attachment handles never download',
    () async {
      var content = <String, Object?>{
        'text': 'body',
        'attachments': [attachmentFixture()],
      };
      final client = FakeBichonClient({
        'envelope/*': (_) => json(envelope(envA)),
        'message-content/*': (_) => json(content),
      });
      final file = File('${Directory.systemTemp.path}/bichon-not-created');
      await withClient(client, (api) async {
        await expectLater(
          api.downloadAttachment('$alex:$envA', hash, file),
          throwsA(isA<ArchiveMessageRefused>()),
        );
        expect(client.sent, isEmpty);
        // A valid attachment followed by an invalid body must publish nothing.
        content['text'] = 42;
        await expectLater(api.message('$alex:$envA'), throwsUnsupported);
        final count = client.sent.length;
        await expectLater(
          api.downloadAttachment('$alex:$envA', hash, file),
          throwsA(isA<ArchiveMessageRefused>()),
        );
        expect(client.sent, hasLength(count));
        content['text'] = 'body';
        await api.message('$alex:$envA');
        content['attachments'] = [];
        await api.message('$alex:$envA');
        final afterReload = client.sent.length;
        await expectLater(
          api.downloadAttachment('$alex:$envA', hash, file),
          throwsA(isA<ArchiveMessageRefused>()),
        );
        expect(client.sent, hasLength(afterReload));
      });
    },
  );

  test(
    'a cancelled late Bichon message cannot register attachment handles',
    () async {
      final api = HeldBichon();
      final load = MessageLoad();
      final work = api.messageWithCancellation('$alex:$envA', load);
      await api.started.future;
      load.cancel();
      await expectLater(work, throwsA(isA<MessageLoadCancelled>()));
      final late = expectLater(
        api.operation,
        throwsA(isA<MessageLoadCancelled>()),
      );
      api.release.complete();
      await late;
      await expectLater(
        api.downloadAttachment(
          '$alex:$envA',
          hash,
          File('${Directory.systemTemp.path}/bichon-not-created'),
        ),
        throwsA(isA<ArchiveMessageRefused>()),
      );
    },
  );

  test(
    'invalid date extremes and non-integer zero are format errors',
    () async {
      for (final value in [-9223372036854775808, 8640000000000001, 0.0]) {
        final client = FakeBichonClient({
          'search-messages': (_) => json({
            'items': [
              {...envelope(envA), 'date': value},
            ],
            'total_items': 1,
          }),
        });
        await expectLater(
          withClient(client, (api) => api.emails('$alex', '', 1)),
          throwsUnsupported,
        );
      }
    },
  );

  test('mailbox states other than ready are not adopted', () async {
    for (final state in ['fetching', 'error', 'unexpected']) {
      final client = FakeBichonClient({
        'list-mailboxes/*': (_) => json({...mailboxes, 'status': state}),
      });
      await expectLater(
        withClient(client, (api) => api.folders('$alex')),
        throwsUnsupported,
      );
    }
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  group('literal search', () {
    test('escapes query syntax and lowercases standalone operators', () {
      expect(bichonLiteralSearch('x:y'), r'x\:y');
      expect(bichonLiteralSearch('harbor AND OR'), 'harbor and or');
      expect(bichonLiteralSearch('ANDROID'), 'ANDROID');
      expect(bichonLiteralSearch('AND\tOR'), 'and\tor');
      expect(bichonLiteralSearch('(AND)'), r'\(and\)');
      expect(bichonLiteralSearch(r'a\b'), r'a\\b');
      expect(bichonLiteralSearch('"unbalanced'), r'\"unbalanced');
      expect(bichonLiteralSearch('club: next'), r'club\: next');
      expect(bichonLiteralSearch('café 🙂'), 'café 🙂');
      for (final char in r'+-&|!(){}[]^"~*?:\/'.split('')) {
        expect(bichonLiteralSearch(char), '\\$char');
      }
    });
  });

  test(
    'lists accounts from minimal-account-list with a bearer token',
    () async {
      final client = FakeBichonClient({
        'minimal-account-list': (_) => json([
          {
            'id': alex,
            'email': 'alex.rivera@example.com',
            'name': 'Alex Rivera',
            'account_type': 'NoSync',
          },
        ]),
      });
      final accounts = await withClient(client, (api) => api.accounts());
      expect(accounts.single.id, '$alex');
      expect(accounts.single.address, 'alex.rivera@example.com');
      final request = client.sent.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), '$server/api/v1/minimal-account-list');
      expect(request.headers['authorization'], 'Bearer test-only-token');
    },
  );

  test('rejects an account list with a non-integer ID', () async {
    final client = FakeBichonClient({
      'minimal-account-list': (_) => json([
        {
          'id': '$alex',
          'email': 'alex.rivera@example.com',
          'account_type': 'NoSync',
        },
      ]),
    });
    await expectLater(
      withClient(client, (api) => api.accounts()),
      throwsUnsupported,
    );
  });

  test(
    'flattens mailboxes by path without asking the server to fetch',
    () async {
      final client = FakeBichonClient({
        'list-mailboxes/*': (_) => json(mailboxes),
      });
      final folders = await withClient(client, (api) => api.folders('$alex'));
      expect(folders.map((f) => (f.name, f.path, f.depth)), [
        ('INBOX', 'INBOX', 0),
        ('Family', 'INBOX/Family', 1),
      ]);
      expect(
        client.sent.single.url.toString(),
        '$server/api/v1/list-mailboxes/$alex',
      );
    },
  );

  test('rejects mailboxes of another account and an error status', () async {
    for (final body in [
      {
        'status': 'ready',
        'mailboxes': [
          {'id': inbox, 'account_id': bakery, 'name': 'INBOX', 'exists': 0},
        ],
      },
      {'status': 'error', 'mailboxes': []},
    ]) {
      final client = FakeBichonClient({'list-mailboxes/*': (_) => json(body)});
      await expectLater(
        withClient(client, (api) => api.folders('$alex')),
        throwsUnsupported,
      );
    }
  });

  test(
    'searches with the read-only POST, literal text, folder and dates',
    () async {
      final client = FakeBichonClient({
        'list-mailboxes/*': (_) => json(mailboxes),
        'search-messages': (_) => json({
          'items': [envelope(envA, regular: 1), envelope(envB, mailbox: inbox)],
          'total_items': 27,
          'current_page': 1,
          'page_size': 25,
        }),
      });
      final page = await withClient(client, (api) async {
        await api.folders('$alex');
        return api.emails(
          '$alex',
          '  club: next ',
          2,
          folder: 'INBOX',
          filters: SearchFilters(
            from: DateTime(2026, 11, 1),
            to: DateTime(2026, 11, 14),
            sortOrder: 'asc',
          ),
        );
      });
      final request = client.sent.last;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$server/api/v1/search-messages');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.json, {
        'filter': {
          'account_ids': [alex],
          'mailbox_ids': [inbox],
          'text': r'club\: next',
          'since': DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
          'before': DateTime.utc(2026, 11, 15).millisecondsSinceEpoch - 1,
        },
        'page': 2,
        'page_size': 25,
        'sort_by': 'DATE',
        'desc': false,
      });
      expect(page.page, 2);
      expect(page.totalItems, 27);
      expect(page.totalPages, 2);
      expect(page.totalIsEstimate, isFalse);
      final first = page.items.first;
      expect(first.id, '$alex:$envA');
      expect(first.from, 'Sam Friend <friend@example.com>');
      expect(
        first.sentDate,
        DateTime.fromMillisecondsSinceEpoch(
          1793178900000,
          isUtc: true,
        ).toIso8601String(),
      );
      expect(first.hasAttachments, isTrue);
      expect(
        page.items.last.hasAttachments,
        isFalse,
        reason: 'inline-only parts are not attachments',
      );
    },
  );

  test('a message stored without a date reports no date', () async {
    final client = FakeBichonClient({
      'search-messages': (_) => json({
        'items': [
          {...envelope(envA), 'date': 0},
        ],
        'total_items': 1,
      }),
    });
    final page = await withClient(client, (api) => api.emails('$alex', '', 1));
    expect(page.items.single.sentDate, isNull);
  });

  test('a plain listing sends no text and sorts newest first', () async {
    final client = FakeBichonClient({
      'search-messages': (_) => json({'items': [], 'total_items': 0}),
    });
    await withClient(client, (api) => api.emails('$alex', '', 1));
    expect(client.sent.single.json, {
      'filter': {
        'account_ids': [alex],
      },
      'page': 1,
      'page_size': 25,
      'sort_by': 'DATE',
      'desc': true,
    });
  });

  test(
    'rejects results from another account, folder or an oversized page',
    () async {
      for (final items in [
        [envelope(envA, account: bakery)],
        [
          for (var i = 0; i < 26; i++)
            envelope('00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}'),
        ],
      ]) {
        final client = FakeBichonClient({
          'search-messages': (_) =>
              json({'items': items, 'total_items': items.length}),
        });
        await expectLater(
          withClient(client, (api) => api.emails('$alex', '', 1)),
          throwsUnsupported,
        );
      }
      final client = FakeBichonClient({
        'list-mailboxes/*': (_) => json(mailboxes),
        'search-messages': (_) => json({
          'items': [envelope(envA, mailbox: family)],
          'total_items': 1,
        }),
      });
      await expectLater(
        withClient(client, (api) async {
          await api.folders('$alex');
          return api.emails('$alex', '', 1, folder: 'INBOX');
        }),
        throwsUnsupported,
      );
    },
  );

  test(
    'refuses over-long search text and unknown folders before any request',
    () async {
      final client = FakeBichonClient({
        'search-messages': (_) => json({'items': [], 'total_items': 0}),
      });
      await withClient(client, (api) async {
        await api.emails('$alex', '🙂' * bichonMaxSearchLength, 1);
        expect(
          client.sent,
          hasLength(1),
          reason: '256 code points are allowed',
        );
        await expectLater(
          api.emails('$alex', 'a' * (bichonMaxSearchLength + 1), 1),
          throwsA(
            isA<ArchiveSearchRefused>().having(
              (e) => readableError(e),
              'message',
              contains('too long'),
            ),
          ),
        );
        await expectLater(
          api.emails('$alex', '', 1, folder: 'Nowhere'),
          throwsFormatException,
        );
      });
      expect(client.sent, hasLength(1));
    },
  );

  test(
    'the transport refuses POST bodies over 4 KiB and POST on other routes',
    () async {
      final client = FakeBichonClient({});
      await withClient(client, (api) async {
        await expectLater(
          api.postJson('search-messages', {
            'filter': {'text': 'x' * maxRequestBodyBytes},
          }),
          throwsArgumentError,
        );
        await expectLater(
          api.postJson('delete-messages', {}),
          throwsStateError,
        );
        await expectLater(api.postJson('update-tags', {}), throwsStateError);
      });
      await HttpOverrides.runZoned(() async {
        final mailArchiver = ArchiveApi(server, 'test-only');
        await expectLater(
          mailArchiver.postJson('emails', {}),
          throwsStateError,
        );
      }, createHttpClient: (_) => client);
      expect(client.sent, isEmpty);
    },
  );

  test(
    'opens parsed content with remote content blocked and drops inline parts',
    () async {
      final client = FakeBichonClient({
        'envelope/*': (_) => json(envelope(envA, regular: 1)),
        'message-content/*': (_) => json({
          'text': 'Fictional body',
          'html': '<p>Fictional body</p>',
          'has_remote_content': false,
          'attachments': [
            {
              'file_type': 'image/png',
              'inline': false,
              'filename': 'lake-sunset.png',
              'size': 412,
              'content_hash': hash,
              'is_message': false,
              'extracted_is_ocr': false,
              'extracted_text': 'Pro-only extracted text',
            },
            {
              'file_type': 'image/gif',
              'inline': true,
              'filename': 'logo.gif',
              'size': 10,
              'content_hash': 'abc',
              'is_message': false,
              'extracted_is_ocr': false,
            },
          ],
        }),
      });
      final message = await withClient(
        client,
        (api) => api.message('$alex:$envA'),
      );
      expect(client.sent.map((r) => r.url.toString()), [
        '$server/api/v1/envelope/$alex/$envA',
        '$server/api/v1/message-content/$alex/$envA?block_remote_content=true',
      ]);
      expect(client.sent.every((r) => r.method == 'GET'), isTrue);
      expect(message.subject, 'Book club: next pick');
      expect(message.folderName, 'INBOX');
      expect(message.textBody, 'Fictional body');
      expect(message.htmlBody, '<p>Fictional body</p>');
      expect(
        message.attachments.map((a) => (a.id, a.name, a.size, a.contentType)),
        [(hash, 'lake-sunset.png', 412, 'image/png')],
      );
    },
  );

  test('rejects an envelope for a different message', () async {
    final client = FakeBichonClient({
      'envelope/*': (_) => json(envelope(envB)),
      'message-content/*': (_) => json({'has_remote_content': false}),
    });
    await expectLater(
      withClient(client, (api) => api.message('$alex:$envA')),
      throwsUnsupported,
    );
    expect(client.sent, hasLength(1));
  });

  test('refuses malformed IDs before building any URL', () async {
    final client = FakeBichonClient({});
    await withClient(client, (api) async {
      for (final id in [
        '$alex/../1:$envA',
        '$alex:../x',
        '0:$envA',
        '$alex',
        '-1:$envA',
        'x:$envA',
      ]) {
        await expectLater(api.message(id), throwsFormatException, reason: id);
      }
      await expectLater(api.folders('$alex/1'), throwsFormatException);
      await expectLater(
        api.emails('99999999999999999999', '', 1),
        throwsFormatException,
      );
      final file = File('${Directory.systemTemp.path}/bichon-never-written');
      await expectLater(
        api.downloadAttachment('$alex:$envA', '../x', file),
        throwsFormatException,
      );
    });
    expect(client.sent, isEmpty);
  });

  test('saves an attachment by content hash at its stated size', () async {
    final bytes = List<int>.generate(412, (i) => i % 251);
    final client = FakeBichonClient({
      'envelope/*': (_) => json(envelope(envA, regular: 1)),
      'message-content/*': (_) => json({
        'has_remote_content': false,
        'attachments': [
          {
            'file_type': 'image/png',
            'inline': false,
            'filename': 'lake-sunset.png',
            'size': 412,
            'content_hash': hash,
            'is_message': false,
            'extracted_is_ocr': false,
          },
        ],
      }),
      'download-attachment/*': (_) => (200, bytes),
    });
    final dir = await Directory.systemTemp.createTemp('bichon-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/lake-sunset.png');
    await withClient(client, (api) async {
      await api.message('$alex:$envA');
      await api.downloadAttachment('$alex:$envA', hash, file);
    });
    expect(await file.readAsBytes(), bytes);
    expect(
      client.sent.last.url.toString(),
      '$server/api/v1/download-attachment/$alex/$envA?content_hash=$hash',
    );
  });

  test(
    'a saved attachment that differs from its stated size is deleted',
    () async {
      final client = FakeBichonClient({
        'envelope/*': (_) => json(envelope(envA, regular: 1)),
        'message-content/*': (_) => json({
          'has_remote_content': false,
          'attachments': [
            {
              'file_type': 'image/png',
              'inline': false,
              'filename': 'a.png',
              'size': 412,
              'content_hash': hash,
              'is_message': false,
              'extracted_is_ocr': false,
            },
          ],
        }),
        'download-attachment/*': (_) => (200, List<int>.filled(500, 1)),
      });
      final dir = await Directory.systemTemp.createTemp('bichon-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.png');
      await withClient(client, (api) async {
        await api.message('$alex:$envA');
        await expectLater(
          api.downloadAttachment('$alex:$envA', hash, file),
          throwsFormatException,
        );
      });
      expect(file.existsSync(), isFalse);
    },
  );

  test(
    'declares fixed capabilities and never requests server totals',
    () async {
      expect(bichonCapabilities.folders, isTrue);
      expect(bichonCapabilities.directionFilter, isFalse);
      expect(bichonCapabilities.sortFields, {'sentDate'});
      expect(bichonCapabilities.estimatedTotals, isFalse);
      expect(bichonCapabilities.archiveStats, isFalse);
      final client = FakeBichonClient({});
      await expectLater(
        withClient(client, (api) => api.stats()),
        throwsUnsupportedError,
      );
      expect(client.sent, isEmpty);
    },
  );

  test('maps a refused token and a query error to readable messages', () async {
    for (final status in [401, 403, 400]) {
      final client = FakeBichonClient({
        'search-messages': (_) =>
            (status, utf8.encode('{"message":"x","code":$status}')),
      });
      await expectLater(
        withClient(client, (api) => api.emails('$alex', 'q', 1)),
        throwsA(
          isA<ArchiveFailure>().having((e) => e.status, 'status', status),
        ),
      );
    }
  });

  test(
    'names Bichon and the tested version for a non-conforming response',
    () async {
      final client = FakeBichonClient({
        'minimal-account-list': (_) => json({'unexpected': 'shape'}),
      });
      final error = await withClient(
        client,
        (api) => api.accounts(),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ArchiveUnsupportedResponse>());
      expect(
        readableError(error!),
        "This Bichon version isn't supported yet. MailBurrow is tested with Bichon 2.4.2.",
      );
      expect(
        readableError(const FormatException('x')),
        isNot(contains('Mail-Archiver')),
      );
    },
  );

  test(
    'cancelling mail stops an in-flight search POST but not a folder list',
    () async {
      final client = FakeBichonClient({
        'list-mailboxes/*': (_) => json(mailboxes),
        'search-messages': (_) => json({'items': [], 'total_items': 0}),
      });
      client.holds['search-messages'] = Completer<void>();
      client.holds['list-mailboxes/$alex'] = Completer<void>();
      await withClient(client, (api) async {
        final search = api.emails('$alex', 'garden', 1);
        final searchDone = expectLater(search, throwsA(isA<HttpException>()));
        final folders = api.folders('$alex');
        await Future<void>.delayed(Duration.zero);
        api.cancelEmailRequests();
        await searchDone;
        client.holds['list-mailboxes/$alex']!.complete();
        expect((await folders).map((f) => f.path), ['INBOX', 'INBOX/Family']);
        client.holds['search-messages']!.complete();
        await Future<void>.delayed(Duration.zero);
      });
    },
  );

  test(
    'a reader cancelled during the envelope request never fetches content',
    () async {
      final client = FakeBichonClient({
        'envelope/*': (_) => json(envelope(envA)),
        'message-content/*': (_) => json({'has_remote_content': false}),
      });
      client.holds['envelope/$alex/$envA'] = Completer<void>();
      await withClient(client, (api) async {
        final load = MessageLoad();
        final opening = api.messageWithCancellation('$alex:$envA', load);
        final done = expectLater(opening, throwsA(anything));
        await Future<void>.delayed(Duration.zero);
        load.cancel();
        await done;
        client.holds['envelope/$alex/$envA']!.complete();
        await Future<void>.delayed(Duration.zero);
      });
      expect(client.sent.map((r) => r.url.path), [
        '/api/v1/envelope/$alex/$envA',
      ]);
    },
  );
}
