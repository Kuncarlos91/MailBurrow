import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:mailburrow/attachments.dart';
import 'package:mailburrow/attachment_download.dart';
import 'support/fake_archive_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/app_lock/app_lock_controller.dart';
import 'package:mailburrow/app_lock/app_lock_gate.dart';
import 'package:mailburrow/app_lock/app_lock_platform.dart';
import 'package:mailburrow/app_lock/app_lock_settings.dart';
import 'app_lock_test.dart' as support;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('background success cannot authorize a much later return', () async {
    final entries = support.MemoryEntries({
      AppLockStore.entry: support.stored(true, 0),
    });
    final platform = support.FakePlatform();
    var lifecycle = AppLifecycleState.resumed;
    final lock = AppLockController(
      store: AppLockStore(entries: entries),
      platform: platform,
      lifecycleState: () => lifecycle,
    );
    addTearDown(lock.dispose);
    await lock.start();
    final unlocking = lock.unlock();
    lifecycle = AppLifecycleState.paused;
    lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
    platform.answer(AppLockAuthResult.success);
    await Future<void>.delayed(Duration.zero);
    platform.now = platform.now! + 600000;
    lifecycle = AppLifecycleState.resumed;
    lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await unlocking;
    await Future<void>.delayed(Duration.zero);
    expect(
      lock.contentVisible,
      isFalse,
      reason: 'immediate relock after genuine background',
    );
  });
  for (final repairing in [false, true]) {
    test(
      'backgrounded delayed ${repairing ? "repair" : "settings"} save cannot reveal content',
      () async {
        final entries = HeldWriteEntries({
          AppLockStore.entry: repairing ? 'invalid' : support.stored(true, 60),
        });
        final platform = support.FakePlatform();
        var lifecycle = AppLifecycleState.resumed;
        final lock = AppLockController(
          store: AppLockStore(entries: entries),
          platform: platform,
          lifecycleState: () => lifecycle,
        );
        addTearDown(lock.dispose);
        await lock.start();
        if (!repairing) {
          final unlocking = lock.unlock();
          platform.answer(AppLockAuthResult.success);
          await unlocking;
        }
        final operation = repairing
            ? lock.unlockAndRepair()
            : lock.setRelockAfter(const Duration(minutes: 5));
        await Future<void>.delayed(Duration.zero);
        platform.answer(AppLockAuthResult.success);
        await entries.started.future;
        lifecycle = AppLifecycleState.paused;
        lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
        lock.didChangeAppLifecycleState(AppLifecycleState.paused);
        platform.now = platform.now! + 600000;
        entries.finish.complete();
        await operation;
        expect(lock.contentVisible, isFalse);
        lifecycle = AppLifecycleState.resumed;
        lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(lock.contentVisible, isFalse);
      },
    );
  }
  testWidgets('completing a download while locked cannot open native save', (
    tester,
  ) async {
    final cache = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('lock-review-'),
    ))!;
    addTearDown(() async {
      if (await cache.exists()) await cache.delete(recursive: true);
    });
    final entries = support.MemoryEntries({
      AppLockStore.entry: support.stored(true, 0),
    });
    final platform = support.FakePlatform()
      ..autoAnswer = AppLockAuthResult.success;
    var lifecycle = AppLifecycleState.resumed;
    final lock = AppLockController(
      store: AppLockStore(entries: entries),
      platform: platform,
      lifecycleState: () => lifecycle,
    );
    addTearDown(lock.dispose);
    await lock.start();
    await lock.unlock();
    platform.autoAnswer = null;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const fileChannel = MethodChannel('mailshelf/saved_files');
    var saves = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => cache.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      fileChannel,
      (call) async {
        if (call.method == 'save') saves++;
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        fileChannel,
        null,
      );
    });
    final api = HeldDownload();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppLockScope(
          controller: lock,
          child: AppLockGate(controller: lock, child: child!),
        ),
        home: Scaffold(
          body: MessageAttachments(
            api: api,
            emailId: '1',
            attachments: const [MailAttachment('2', 'synthetic.txt', 3)],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download and save'));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !api.started.isCompleted; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(api.started.isCompleted, isTrue, reason: 'test download started');
    lifecycle = AppLifecycleState.paused;
    lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
    lifecycle = AppLifecycleState.resumed;
    lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(lock.contentVisible, isFalse);
    api.finish.complete();
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && saves == 0; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(saves, 0, reason: 'no native handoff while locked');
  });
  testWidgets('error unlock controls fit large text landscape', (tester) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final entries = support.MemoryEntries()
      ..readError = StateError('synthetic');
    final lock = AppLockController(
      store: AppLockStore(entries: entries),
      platform: support.FakePlatform(),
    );
    addTearDown(lock.dispose);
    await lock.start();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: AppLockGate(controller: lock, child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('app-lock-repair')));
    expect(
      find.byKey(const Key('app-lock-repair')).hitTestable(),
      findsOneWidget,
    );
  });
}

class HeldDownload extends FakeArchiveBackend {
  HeldDownload() : super(Uri.parse('https://example.com'), 'synthetic');
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int)? onProgress,
  }) async {
    started.complete();
    await finish.future;
    await destination.writeAsString('abc');
  }
}

class HeldWriteEntries extends support.MemoryEntries {
  HeldWriteEntries(super.values);
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<void> write({required String key, required String value}) async {
    started.complete();
    await finish.future;
    await super.write(key: key, value: value);
  }
}
