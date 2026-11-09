import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_information.dart';

void main() {
  test('accepts zero counts and rejects unavailable or invalid counts', () {
    expect(
      ArchiveStats.fromJson({
        'emails': 0,
        'accounts': 1,
        'attachments': 0,
      }).emails,
      0,
    );
    expect(
      () => ArchiveStats.fromJson({
        'emails': -1,
        'accounts': 1,
        'attachments': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ArchiveStats.fromJson({'accounts': 1, 'attachments': 0}),
      throwsFormatException,
    );
  });
  testWidgets('shows correctly scoped totals and account metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ArchiveInformation(
              api: StatsApi(),
              account: const {'id': 1},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Totals across all accounts accessible to this API key'),
      findsOneWidget,
    );
    expect(find.text('Archived messages'), findsOneWidget);
    expect(find.text('123'), findsOneWidget);
    expect(find.text('Archiving: Enabled'), findsOneWidget);
    expect(find.text('Not reported'), findsOneWidget);
  });
  Future<void> showAccounts(
    WidgetTester tester,
    MutableAccountsApi api, {
    bool largeText = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(largeText ? 3 : 1)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ArchiveInformation(api: api, account: const {'id': 1}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'lists only returned account addresses and marks current account',
    (tester) async {
      await showAccounts(tester, MutableAccountsApi());
      expect(find.text('Email accounts'), findsOneWidget);
      expect(find.text('first@example.com'), findsOneWidget);
      expect(find.text('second@example.com'), findsOneWidget);
      expect(find.text('Currently browsing'), findsOneWidget);
      expect(find.text('Accounts accessible to this API key.'), findsOneWidget);
    },
  );

  testWidgets(
    'refresh replaces account list without retaining removed addresses',
    (tester) async {
      final api = MutableAccountsApi();
      await showAccounts(tester, api);
      api.available = [
        {'id': 1, 'emailAddress': 'updated@example.com'},
      ];
      await tester.tap(find.byTooltip('Refresh archive information'));
      await tester.pumpAndSettle();
      expect(find.text('updated@example.com'), findsOneWidget);
      expect(find.text('first@example.com'), findsNothing);
      expect(find.text('second@example.com'), findsNothing);
    },
  );

  testWidgets('failed refresh hides stale account list until recovery', (
    tester,
  ) async {
    final api = MutableAccountsApi();
    await showAccounts(tester, api);
    api.offline = true;
    await tester.tap(find.byTooltip('Refresh archive information'));
    await tester.pumpAndSettle();
    expect(find.text('first@example.com'), findsNothing);
    expect(find.text(readableError(const SocketException(''))), findsOneWidget);
    api.offline = false;
    await tester.tap(find.byTooltip('Refresh archive information'));
    await tester.pumpAndSettle();
    expect(find.text('first@example.com'), findsOneWidget);
    expect(find.text(readableError(const SocketException(''))), findsNothing);
  });

  testWidgets('missing and long addresses remain readable at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = MutableAccountsApi()
      ..available = [
        {'id': 1},
        {'id': 2, 'emailAddress': 'synthetic.long.account.address@example.com'},
      ];
    await showAccounts(tester, api, largeText: true);
    await tester.scrollUntilVisible(
      find.text('Currently browsing'),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
    expect(find.text('Email address not reported'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('synthetic.long.account.address@example.com'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('synthetic.long.account.address@example.com').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class StatsApi extends ArchiveApi {
  StatsApi() : super(Uri.parse('https://example.com'), 'test-only');
  @override
  Future<Map<String, dynamic>> stats() async => {
    'emails': 123,
    'accounts': 1,
    'attachments': 5,
  };
  @override
  Future<List<dynamic>> accounts() async => [
    {'id': 1, 'isEnabled': true, 'lastSync': null},
  ];
}

class MutableAccountsApi extends StatsApi {
  bool offline = false;
  List<Map<String, dynamic>> available = [
    {'id': 1, 'emailAddress': 'first@example.com'},
    {'id': 2, 'emailAddress': 'second@example.com'},
  ];
  @override
  Future<List<dynamic>> accounts() async {
    if (offline) throw const SocketException('private detail');
    return available;
  }
}
