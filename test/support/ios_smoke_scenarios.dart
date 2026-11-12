import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/app.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/search_filters.dart';

const _server = 'https://archive.example.invalid';
const _syntheticKey = 'test-only-smoke';

class _SyntheticArchive extends ArchiveApi {
  _SyntheticArchive() : super(Uri.parse(_server), _syntheticKey);
  String lastQuery = '';

  @override
  Future<dynamic> get(String path, [Map<String, String>? query]) async =>
      throw StateError(
        'Network requests are forbidden in simulator smoke tests.',
      );

  @override
  Future<List<dynamic>> accounts() async => [
    {'id': 1, 'emailAddress': 'smoke@example.invalid', 'isEnabled': true},
  ];

  @override
  Future<List<ArchiveFolder>> folders(String id) async => [
    const ArchiveFolder('Inbox', 'INBOX', 1, 0),
  ];

  @override
  Future<Map<String, dynamic>> stats() async => {
    'emails': 1,
    'accounts': 1,
    'attachments': 0,
  };

  @override
  Future<Map<String, dynamic>> emails(
    String id,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    lastQuery = query;
    return {
      'items': [
        {
          'id': 1,
          'from': 'sender@example.invalid',
          'to': 'smoke@example.invalid',
          'subject': 'Simulator test message',
          'snippet': 'Synthetic content only.',
        },
      ],
      'page': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> message(String id) async => {
    'id': id,
    'from': 'sender@example.invalid',
    'to': 'smoke@example.invalid',
    'subject': 'Simulator test message',
    'textBody': 'Synthetic simulator message body.',
    'attachments': <dynamic>[],
  };
}

Future<void> _settle(WidgetTester tester) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 20)) {
    // Allow real native callbacks and the message-preparation isolate to finish.
    // The host harness uses a fake clock; a tight pump loop can starve that work.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) return;
  }
  throw TestFailure('Smoke UI did not settle within the bounded wait.');
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final elapsed = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 20)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

void runSmokeScenarios() {
  const storage = FlutterSecureStorage();

  // This suite is only for the newly created disposable simulator.
  setUp(() async {
    await storage.delete(key: 'connection');
    expect(await storage.read(key: 'connection'), isNull);
  });
  tearDown(() async {
    await storage.delete(key: 'connection');
  });

  testWidgets('fresh native startup is blank and obscures the key', (
    tester,
  ) async {
    await tester.pumpWidget(const MailShelfPreview());
    await _settle(tester);
    expect(find.text('Connect to archive'), findsOneWidget);
    expect(
      find.text('Saved connection unavailable. Enter your settings again.'),
      findsNothing,
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(2));
    expect(fields[0].controller!.text, isEmpty);
    expect(fields[1].controller!.text, isEmpty);
    expect(fields[1].obscureText, isTrue);

    await tester.ensureVisible(find.text('Connect to archive'));
    await tester.tap(find.text('Connect to archive'));
    await _settle(tester);
    expect(
      find.textContaining('Enter a valid HTTPS server address'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });

  testWidgets('synthetic mail navigation and native connection storage', (
    tester,
  ) async {
    final archive = _SyntheticArchive();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: ArchiveHome(apiFactory: (_, _) => archive),
      ),
    );
    await _settle(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), _server);
    await tester.enterText(fields.at(1), _syntheticKey);
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle(tester);
    await tester.ensureVisible(find.text('Connect to archive'));
    await tester.tap(find.text('Connect to archive'));
    await _settle(tester);
    expect(find.text('Simulator test message'), findsOneWidget);
    final saved = await storage.read(key: 'connection');
    expect(saved, isNotNull);
    expect(jsonDecode(saved!)['server'], _server);
    expect(jsonDecode(saved)['key'], _syntheticKey);

    await tester.tap(find.text('Simulator test message'));
    await _settle(tester);
    final body = find.textContaining(
      'Synthetic simulator message body.',
      findRichText: true,
    );
    await _waitFor(tester, body);
    expect(body, findsWidgets);
    await tester.pageBack();
    await _settle(tester);
    expect(find.text('Simulator test message'), findsOneWidget);

    await tester.tap(find.byType(NavigationDestination).at(1));
    await _settle(tester);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'synthetic');
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle(tester);
    await tester.tap(find.byTooltip('Run search'));
    await _settle(tester);
    expect(archive.lastQuery, 'synthetic');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await _settle(tester);
    expect(find.text('Your archive. Your server.'), findsOneWidget);

    // Recreate the widget tree and verify the native saved record restores.
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    await tester.pumpWidget(
      MaterialApp(home: ArchiveHome(apiFactory: (_, _) => archive)),
    );
    await _settle(tester);
    expect(find.text('Connect to archive'), findsNothing);
    expect(find.text('Simulator test message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });
}
