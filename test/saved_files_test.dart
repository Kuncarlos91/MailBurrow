import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/saved_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(savedFilesChannel, null);
  });
  test('preserves full document URI from save through explicit open', () async {
    const location =
        'content://com.android.providers.downloads.documents/document/msf%3A123';
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(savedFilesChannel, (call) async {
          calls.add(call);
          return call.method == 'save' ? location : 'opened';
        });
    final saved = await saveDownloadedFile(
      '/cache/test/report.pdf',
      'report.pdf',
      'application/pdf',
    );
    expect(saved, location);
    expect(calls.length, 1);
    expect(await openSavedFile(saved!), 'opened');
    expect(calls.last.arguments['location'], location);
  });
  test(
    'Android releases the saved document grant without deleting it',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(savedFilesChannel, (call) async {
            calls.add(call);
            return null;
          });
      await releaseSavedFile('content://example/document/saved');
      expect(calls.map((call) => call.method), ['release']);
      expect(calls.single.arguments, {
        'location': 'content://example/document/saved',
      });
    },
  );

  test('normal file operations never opt into diagnostic logging', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(savedFilesChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'save' => 'content://example/document/saved',
            'locate' => 'content://example/document/reselected',
            'open' => 'opened',
            _ => null,
          };
        });
    await saveDownloadedFile(
      '/cache/test/sample.txt',
      'sample.txt',
      'text/plain',
    );
    await openSavedFile('content://example/document/saved');
    await chooseSavedFile();
    await releaseSavedFile('content://example/document/saved');
    expect(calls.map((call) => call.method), [
      'save',
      'open',
      'locate',
      'release',
    ]);
    for (final call in calls) {
      final arguments = call.arguments as Map<dynamic, dynamic>?;
      expect(arguments?.containsKey('diagnostics') ?? false, isFalse);
    }
  });

  test('cancelled save returns no location and never requests open', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(savedFilesChannel, (call) async {
          methods.add(call.method);
          return null;
        });
    expect(
      await saveDownloadedFile('/cache/test', 'test.txt', 'text/plain'),
      isNull,
    );
    expect(methods, ['save']);
  });
  test('missing viewer outcome reaches the interface', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(savedFilesChannel, (_) async => 'no_app');
    expect(await openSavedFile('content://example/document/1'), 'no_app');
  });
  group('iOS provider permission handoff', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test(
      'keeps native token, opens explicitly and releases session access',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(savedFilesChannel, (call) async {
              calls.add(call);
              return switch (call.method) {
                'save' => 'opaque-session-token',
                'open' => 'opened',
                _ => null,
              };
            });
        final token = await saveDownloadedFile(
          '/cache/report.pdf',
          'report.pdf',
          'application/pdf',
        );
        expect(token, 'opaque-session-token');
        // Saving must not trigger opening, nor attempt a Dart File.exists on a token.
        expect(calls.map((c) => c.method), ['save']);
        expect(await openSavedFile(token!), 'opened');
        await releaseSavedFile(token);
        expect(calls.map((c) => c.method), ['save', 'open', 'release']);
        expect(calls.last.arguments, {'location': token});
      },
    );

    test('cancelled picker does not request opening', () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(savedFilesChannel, (call) async {
            methods.add(call.method);
            return null;
          });
      expect(
        await saveDownloadedFile('/cache/test', 'test.txt', 'text/plain'),
        isNull,
      );
      expect(methods, ['save']);
    });

    test(
      'missing or removed document reports unavailable without retrying save',
      () async {
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(savedFilesChannel, (call) async {
              methods.add(call.method);
              return 'unavailable';
            });
        expect(await openSavedFile('expired-token'), 'unavailable');
        expect(methods, ['open']);
      },
    );

    test('release tolerates a disconnected native engine', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(savedFilesChannel, (_) async {
            throw PlatformException(code: 'unavailable');
          });
      await releaseSavedFile('session-token');
    });
  });
}
