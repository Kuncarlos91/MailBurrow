import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/content_safety.dart';
import 'package:mailburrow/attachments.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/attachment_download.dart';

void main() {
  test('creates writable download folders inside the existing cache', () async {
    final cache = await Directory.systemTemp.createTemp('mailshelf-test-');
    try {
      final download = await createAttachmentDirectory(cache);
      expect(await download.exists(), isTrue);
      expect(download.parent.path, cache.path);
      final file = await File(
        '${download.path}/attachment.txt',
      ).writeAsString('test');
      expect(await file.readAsString(), 'test');
    } finally {
      await cache.delete(recursive: true);
    }
  });
  test(
    'flags active files, disguised extensions, archives, and bidi names',
    () {
      expect(
        attachmentCaution('invoice.pdf.exe', 'application/octet-stream'),
        isNotNull,
      );
      expect(attachmentCaution('NOTES.PS1', ''), isNotNull);
      expect(attachmentCaution('documents.zip', ''), contains('Archives'));
      expect(
        attachmentCaution('report\u202efdp.exe', ''),
        contains('disguise'),
      );
      expect(attachmentCaution('notes.pdf', 'application/pdf'), isNull);
    },
  );
  test('uses exact folder components for caution banners', () {
    expect(isCautionFolder('[Gmail]/Spam'), isTrue);
    expect(isCautionFolder('INBOX/Junk Email'), isTrue);
    expect(isCautionFolder('Work/Spam research'), isFalse);
  });
  testWidgets('attachment confirmation can be cancelled without downloading', (
    tester,
  ) async {
    final api = RecordingApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageAttachments(
            api: api,
            emailId: 1,
            attachments: const [MailAttachment(2, 'invoice.pdf.exe', 2048)],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Save unscanned attachment?'), findsOneWidget);
    expect(find.text('Download anyway'), findsOneWidget);
    expect(api.downloads, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.downloads, 0);
  });
  testWidgets(
    'interrupted download removes partial private file and allows retry',
    (tester) async {
      final cache = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('mailshelf-interruption-'),
      ))!;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => cache.path,
      );
      final api = InterruptedApi();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageAttachments(
                api: api,
                emailId: 1,
                attachments: const [MailAttachment(2, 'report.pdf', 2048)],
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Download and save'));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 250));
          // The widget must finish its finally block after the failed download.
          for (
            var attempt = 0;
            attempt < 100 && await cache.list().isEmpty == false;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(
          api.failed.isCompleted,
          isTrue,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join(' | '),
        );
        expect(
          find.textContaining('download connection failed'),
          findsOneWidget,
        );
        expect(await tester.runAsync(() => cache.list().isEmpty), isTrue);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
              .onPressed,
          isNotNull,
        );
        expect(find.textContaining('Open saved file:'), findsNothing);
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await tester.runAsync(() => cache.delete(recursive: true));
      }
    },
  );
}

class InterruptedApi extends ArchiveApi {
  InterruptedApi() : super(Uri.parse('https://example.com'), 'test-only');
  final failed = Completer<void>();
  @override
  Future<void> downloadAttachment(
    int emailId,
    int attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int)? onProgress,
  }) async {
    await destination.writeAsString('partial private attachment');
    failed.complete();
    throw const SocketException('Connection interrupted');
  }
}

class RecordingApi extends ArchiveApi {
  RecordingApi() : super(Uri.parse('https://example.com'), 'test-only');
  int downloads = 0;
  @override
  Future<void> downloadAttachment(
    int emailId,
    int attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int)? onProgress,
  }) async {
    downloads++;
  }
}
