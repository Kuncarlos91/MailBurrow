import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_backend.dart';
import 'package:mailburrow/message_load.dart';
import 'package:mailburrow/screens/message_reader.dart';

import 'archive_api_test.dart'
    show
        RoutingHttpClient,
        StreamingHttpResponse,
        HeadersArrivedRequest,
        JsonHttpRequest,
        JsonHttpResponse;
import 'support/fake_archive_backend.dart';
import 'open_archiver_message_test.dart' as fixtures;

class SequencedClient extends RoutingHttpClient {
  final requests = <Completer<HttpClientRequest>>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    final pending = Completer<HttpClientRequest>();
    requests.add(pending);
    return pending.future;
  }
}

class HeldReaderBackend extends FakeArchiveBackend
    implements CancellableMessageBackend {
  HeldReaderBackend()
    : super(Uri.parse('https://archive.example'), 'test-only');
  final response = Completer<MailMessage>();
  MessageLoad? load;
  @override
  Future<MailMessage> messageWithCancellation(String id, MessageLoad load) {
    this.load = load;
    return load.wait(response.future);
  }
}

class HeldOpenArchiver extends fixtures.FakeOpenArchiver {
  final gate = Completer<void>();
  @override
  Future<T> send<T>(
    String path,
    Map<String, String>? query,
    Future<T> Function(Stream<List<int>>, int) read, {
    Duration? timeout,
  }) async {
    await gate.future;
    return super.send(path, query, read, timeout: timeout);
  }
}

void main() {
  test(
    'cancel stops a streamed message without cancelling a second reader of the same ID',
    () async {
      final client = SequencedClient();
      await HttpOverrides.runZoned(() async {
        final api = ArchiveApi(
          Uri.parse('https://archive.example'),
          'test-only',
        );
        final firstLoad = MessageLoad();
        final first = api.messageWithCancellation('1', firstLoad);
        final firstDone = expectLater(
          first,
          throwsA(isA<MessageLoadCancelled>()),
        );
        final secondLoad = MessageLoad();
        final second = api.messageWithCancellation('1', secondLoad);
        final firstBody = StreamingHttpResponse();
        final secondBody = StreamingHttpResponse();
        client.requests[0].complete(HeadersArrivedRequest(firstBody));
        client.requests[1].complete(HeadersArrivedRequest(secondBody));
        await pumpEventQueue();
        firstBody.body.add(utf8.encode('{"subject":"unfinished'));
        await pumpEventQueue();
        firstLoad.cancel();
        await firstDone;
        await pumpEventQueue();
        expect(firstBody.bodyCancelled, isTrue);
        expect(secondBody.bodyCancelled, isFalse);
        expect(client.forceClosed, isFalse);
        secondBody.body.add(utf8.encode('{"subject":"second reader"}'));
        await secondBody.body.close();
        expect((await second).subject, 'second reader');
        api.close();
      }, createHttpClient: (_) => client);
    },
  );

  test('a connection arriving after reader cancellation is aborted', () async {
    final client = SequencedClient();
    await HttpOverrides.runZoned(() async {
      final api = ArchiveApi(Uri.parse('https://archive.example'), 'test-only');
      final load = MessageLoad();
      final pending = api.messageWithCancellation('1', load);
      final done = expectLater(pending, throwsA(isA<MessageLoadCancelled>()));
      load.cancel();
      await done;
      final late = JsonHttpRequest(JsonHttpResponse(utf8.encode('{}'), 2));
      client.requests.single.complete(late);
      await pumpEventQueue();
      expect(late.aborted, isTrue);
      expect(client.forceClosed, isFalse);
      api.close();
    }, createHttpClient: (_) => client);
  });

  test(
    'cancelled Open Archiver load cannot register late attachment handles',
    () async {
      final api = HeldOpenArchiver();
      await api.accounts();
      await api.emails(fixtures.sourceA, '', 1);
      final load = MessageLoad();
      final opening = api.messageWithCancellation(fixtures.mailA, load);
      final done = expectLater(opening, throwsA(isA<MessageLoadCancelled>()));
      load.cancel();
      await done;
      api.gate.complete();
      await pumpEventQueue();
      expect(api.attachmentStoragePath(fixtures.fileA), isNull);
      api.close();
    },
  );

  testWidgets('Back cancels at pop time before the route animation finishes', (
    tester,
  ) async {
    final api = HeldReaderBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MessageReader(api: api, id: '1'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(api.load!.isCancelled, isFalse);
    await tester.pageBack();
    expect(api.load!.isCancelled, isTrue);
    await tester.pumpAndSettle();
    api.response.complete(MailMessage(subject: 'late message'));
    await tester.pumpAndSettle();
    expect(find.text('late message'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
