import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/attachment_download.dart';
import 'package:mailburrow/attachments.dart';

import 'support/fake_archive_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  setUp(
    () async => cache = await Directory.systemTemp.createTemp('attachment-ui-'),
  );
  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  Future<void> settleIo(
    WidgetTester tester,
    Future<bool> Function() ready,
  ) async {
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.pump();
        if (await ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail(
        'Synthetic attachment operation did not finish: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
      );
    });
    await tester.pump();
  }

  Future<void> startSave(WidgetTester tester) async {
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Download and save'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
  }

  Future<void> harness(
    WidgetTester tester,
    ControlledDownloadApi api, {
    int size = 2,
    Future<String?> Function()? save,
    Future<String?> Function(MethodCall)? nativeCall,
  }) async {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => cache.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      savedFilesChannelForTest,
      (call) async => nativeCall != null
          ? await nativeCall(call)
          : call.method == 'save'
          ? await save?.call()
          : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        savedFilesChannelForTest,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Reader')),
                    body: MessageAttachments(
                      api: api,
                      emailId: '1',
                      attachments: [MailAttachment('2', 'sample.txt', size)],
                    ),
                  ),
                ),
              ),
              child: const Text('Home'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'cancelled replacement save preserves the previously saved file',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      var saves = 0;
      final opened = <String>[];
      await harness(
        tester,
        api,
        nativeCall: (call) async {
          if (call.method == 'save') {
            saves++;
            return saves == 1 ? 'content://example/document/saved' : null;
          }
          if (call.method == 'open') {
            opened.add(call.arguments['location'] as String);
            return 'opened';
          }
          return null;
        },
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => saves == 1 && await cache.list().isEmpty,
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => saves == 2 && await cache.list().isEmpty,
      );
      expect(find.text('Save cancelled.'), findsOneWidget);
      await tester.tap(find.text('Open saved file: sample.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(opened, ['content://example/document/saved']);
      expect(api.attempts, 2);
    },
  );

  testWidgets(
    'dismissed external opening retains the same saved location for retry',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      var saves = 0;
      final opened = <String>[];
      await harness(
        tester,
        api,
        nativeCall: (call) async {
          if (call.method == 'save') {
            saves++;
            return 'content://example/document/saved';
          }
          if (call.method == 'open') {
            opened.add(call.arguments['location'] as String);
            return 'opened'; // Android dispatch returns before the chooser closes.
          }
          return null;
        },
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => saves == 1 && await cache.list().isEmpty,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('Open saved file: sample.txt'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open file'));
        await tester.pumpAndSettle();
      }
      expect(opened, List.filled(2, 'content://example/document/saved'));
      expect(api.attempts, 1);
      expect(saves, 1);
    },
  );

  testWidgets(
    'leaving reader releases saved access only after repeat opens finish',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      final calls = <MethodCall>[];
      await harness(
        tester,
        api,
        nativeCall: (call) async {
          calls.add(call);
          return switch (call.method) {
            'save' => 'content://example/document/saved',
            'open' => 'opened',
            _ => null,
          };
        },
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => calls.isNotEmpty && await cache.list().isEmpty,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('Open saved file: sample.txt'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open file'));
        await tester.pumpAndSettle();
      }
      expect(calls.map((call) => call.method), ['save', 'open', 'open']);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), [
        'save',
        'open',
        'open',
        'release',
      ]);
      expect(
        calls.last.arguments['location'],
        'content://example/document/saved',
      );
      expect(api.attempts, 1);
    },
  );

  testWidgets(
    'permission failure can reconnect an existing file without download or auto-open',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      final calls = <MethodCall>[];
      await harness(
        tester,
        api,
        nativeCall: (call) async {
          calls.add(call);
          return switch (call.method) {
            'save' => 'content://example/document/old',
            'locate' => 'content://example/document/reselected',
            'open' =>
              call.arguments['location'] == 'content://example/document/old'
                  ? 'permission_denied'
                  : 'opened',
            _ => null,
          };
        },
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => calls.isNotEmpty && await cache.list().isEmpty,
      );
      await tester.tap(find.text('Open saved file: sample.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('provider denied read access'),
        findsOneWidget,
      );
      await tester.tap(find.text('Choose saved file: sample.txt'));
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), [
        'save',
        'open',
        'locate',
        'release',
      ]);
      expect(
        calls.last.arguments['location'],
        'content://example/document/old',
      );
      expect(api.attempts, 1);
      await tester.tap(find.text('Open saved file: sample.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(
        calls.last.arguments['location'],
        'content://example/document/reselected',
      );
      expect(api.attempts, 1);
      expect(
        find.text('Open request sent. Choose a viewer if prompted.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'cancelled existing-file selection keeps the previous reference and never downloads',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      final calls = <MethodCall>[];
      await harness(
        tester,
        api,
        nativeCall: (call) async {
          calls.add(call);
          return switch (call.method) {
            'save' => 'content://example/document/old',
            'open' => 'session_expired',
            _ => null,
          };
        },
      );
      await startSave(tester);
      await settleIo(
        tester,
        () async => calls.isNotEmpty && await cache.list().isEmpty,
      );
      await tester.tap(find.text('Open saved file: sample.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('access ended for this reader'),
        findsOneWidget,
      );
      await tester.tap(find.text('Choose saved file: sample.txt'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('existing saved-file reference is unchanged'),
        findsOneWidget,
      );
      expect(calls.map((call) => call.method), ['save', 'open', 'locate']);
      await tester.tap(find.text('Open saved file: sample.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(
        calls.last.arguments['location'],
        'content://example/document/old',
      );
      expect(api.attempts, 1);
    },
  );

  testWidgets(
    'oversized metadata is rejected before download or destination picker',
    (tester) async {
      final api = ControlledDownloadApi();
      var saves = 0;
      await harness(
        tester,
        api,
        size: maxAttachmentDownloadBytes + 1,
        save: () async {
          saves++;
          return null;
        },
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.textContaining('50 MiB download limit'), findsOneWidget);
      expect(find.text('Save unscanned attachment?'), findsNothing);
      expect(api.attempts, 0);
      expect(saves, 0);
    },
  );

  testWidgets(
    'Cancel download cleans partial bytes, restores Save and permits retry',
    (tester) async {
      final api = ControlledDownloadApi();
      var saves = 0;
      await harness(
        tester,
        api,
        save: () async {
          saves++;
          return null;
        },
      );
      await startSave(tester);
      await settleIo(tester, () async => api.attempts == 1);
      expect(find.text('Cancel download'), findsOneWidget);
      await tester.runAsync(() async {
        // Progress is throttled using a real stopwatch in the widget.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        api.reportProgress!(1024);
      });
      await tester.pump();
      expect(find.text('Downloading attachment… 1.0 KB'), findsOneWidget);
      await tester.tap(find.text('Cancel download'));
      await settleIo(
        tester,
        () async => api.cancelled == 1 && await cache.list().isEmpty,
      );
      expect(find.text('Download cancelled.'), findsOneWidget);
      expect(find.text('Cancel download'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
            .onPressed,
        isNotNull,
      );
      expect(saves, 0);
      api.hold = false;
      await startSave(tester);
      await settleIo(
        tester,
        () async => saves == 1 && await cache.list().isEmpty,
      );
      expect(api.attempts, 2);
      expect(find.text('Save cancelled.'), findsOneWidget);
      expect(find.textContaining('Open saved file:'), findsNothing);
    },
  );

  testWidgets(
    'Back during download leaves reader and cancels without opening picker',
    (tester) async {
      final api = ControlledDownloadApi();
      var saves = 0;
      await harness(
        tester,
        api,
        save: () async {
          saves++;
          return null;
        },
      );
      await startSave(tester);
      await settleIo(tester, () async => api.attempts == 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await settleIo(
        tester,
        () async => api.cancelled == 1 && await cache.list().isEmpty,
      );
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Reader'), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'destination picker owns cancellation after bounded download finishes',
    (tester) async {
      final api = ControlledDownloadApi()..hold = false;
      final picker = Completer<String?>();
      var saves = 0;
      await harness(
        tester,
        api,
        save: () {
          saves++;
          return picker.future;
        },
      );
      await startSave(tester);
      await settleIo(tester, () async => saves == 1);
      expect(find.text('Choose where to save the attachment.'), findsOneWidget);
      expect(find.text('Cancel download'), findsNothing);
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((widget) => widget is PopScope),
            )
            .canPop,
        isFalse,
      );
      picker.complete(null);
      await settleIo(tester, () async => await cache.list().isEmpty);
      expect(find.text('Save cancelled.'), findsOneWidget);
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((widget) => widget is PopScope),
            )
            .canPop,
        isTrue,
      );
    },
  );
}

const savedFilesChannelForTest = MethodChannel('mailshelf/saved_files');

class ControlledDownloadApi extends FakeArchiveBackend {
  ControlledDownloadApi()
    : super(Uri.parse('https://example.com'), 'test-only');
  bool hold = true;
  void Function(int)? reportProgress;
  int attempts = 0, cancelled = 0;
  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int)? onProgress,
  }) async {
    reportProgress = onProgress;
    await destination.writeAsString('synthetic partial bytes');
    attempts++;
    try {
      if (hold) await transfer!.wait(Completer<void>().future);
    } on AttachmentDownloadCancelled {
      cancelled++;
      rethrow;
    }
  }
}
