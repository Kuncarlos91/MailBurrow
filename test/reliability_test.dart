import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/screens/message_reader.dart';

import 'support/fake_archive_backend.dart';

class RecoveryApi extends ArchiveApi {
  RecoveryApi() : super(Uri.parse('https://example.com'), 'test-only');
  bool offline = true;
  int accountRequests = 0;
  @override
  Future<List<dynamic>> accounts() async {
    accountRequests++;
    if (offline) throw const SocketException('private server detail');
    return [
      {'id': 1, 'emailAddress': 'test@example.com'},
    ];
  }

  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) async => {'items': <dynamic>[], 'page': 1, 'totalPages': 1};
  @override
  Future<List<ArchiveFolder>> folders(int id) async => [];
}

class ReaderApi extends FakeArchiveBackend {
  ReaderApi() : super(Uri.parse('https://example.com'), 'test-only');
  final response = Completer<Map<String, dynamic>>();
  int requests = 0;
  @override
  Future<Map<String, dynamic>> message(int id) {
    requests++;
    return requests == 1
        ? Future.error(const ArchiveFailure(401))
        : response.future;
  }
}

class LandscapeApi extends RecoveryApi {
  LandscapeApi() {
    offline = false;
  }
  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) async => {
    'items': List.generate(
      30,
      (i) => {'id': i, 'from': 'Sender $i', 'subject': 'Landscape message $i'},
    ),
    'page': 1,
    'totalPages': 2,
  };
}

class StartupApi extends RecoveryApi {
  final pendingAccounts = Completer<List<dynamic>>();
  @override
  Future<List<dynamic>> accounts() => pendingAccounts.future;
}

class SearchApi extends LandscapeApi {
  String? lastQuery;
  String? lastFolder;
  int? lastPage;
  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) {
    lastQuery = query;
    lastFolder = folder;
    lastPage = page;
    return super.emails(id, query, page, folder: folder, filters: filters);
  }
}

class DelayedSearchApi extends SearchApi {
  final pending = Completer<Map<String, dynamic>>();
  @override
  Future<List<ArchiveFolder>> folders(int id) async => [
    const ArchiveFolder('Inbox', 'INBOX', 30, 0),
  ];
  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) {
    if (query == 'slow') {
      lastQuery = query;
      return pending.future;
    }
    return super.emails(id, query, page, folder: folder, filters: filters);
  }
}

class SwitchingArchiveApi extends RecoveryApi {
  SwitchingArchiveApi(this.folderName) {
    offline = false;
  }
  final String folderName;
  bool delayFolders = false;
  bool closed = false;
  final delayedFolders = Completer<List<ArchiveFolder>>();
  @override
  Future<List<ArchiveFolder>> folders(int id) async => delayFolders
      ? delayedFolders.future
      : [ArchiveFolder(folderName, folderName, 1, 0)];
  @override
  Future<Map<String, dynamic>> stats() async => {
    'emails': 0,
    'accounts': 1,
    'attachments': 0,
  };
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class PagingApi extends LandscapeApi {
  PagingApi({this.pageCount = 3});
  final int pageCount;
  int? lastRequestedPage;
  int pageRequests = 0;
  bool holdNext = false;
  final pendingPage = Completer<Map<String, dynamic>>();
  String? lastQuery;
  Map<String, dynamic> response(int page) => {
    'items': List.generate(
      30,
      (i) => {
        'id': page * 100 + i,
        'from': 'Sender $i',
        'subject': 'Page $page message $i',
      },
    ),
    'page': page,
    'totalPages': pageCount,
  };
  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) {
    lastQuery = query;
    lastRequestedPage = page;
    pageRequests++;
    if (holdNext) {
      holdNext = false;
      return pendingPage.future;
    }
    return Future.value(response(page));
  }
}

class SectionRecoveryApi extends PagingApi {
  bool networkOffline = false;
  bool mailDenied = false;
  @override
  Future<Map<String, dynamic>> emails(
    int id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) {
    if (networkOffline) {
      return Future.error(const SocketException('private detail'));
    }
    if (mailDenied) return Future.error(const ArchiveFailure(403));
    return super.emails(id, query, page, folder: folder, filters: filters);
  }

  @override
  Future<List<ArchiveFolder>> folders(int id) async {
    if (networkOffline) throw const SocketException('private detail');
    return [];
  }

  @override
  Future<Map<String, dynamic>> stats() async {
    if (networkOffline) throw const SocketException('private detail');
    return {'emails': 30, 'accounts': 1, 'attachments': 0};
  }
}

void main() {
  testWidgets('Go to current page returns to top without another request', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'https://example.com',
        'key': 'test-only',
      }),
    });
    final api = PagingApi(pageCount: 6990);
    await tester.pumpWidget(
      MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
    );
    await tester.pumpAndSettle();
    final requests = api.pageRequests;
    await tester.scrollUntilVisible(
      find.byTooltip('Go to page'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(scroll.pixels, greaterThan(0));
    await tester.tap(find.byTooltip('Go to page'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Go'));
    await tester.pumpAndSettle();
    expect(scroll.pixels, 0);
    expect(api.pageRequests, requests);
    expect(tester.takeException(), isNull);
  });

  for (final searchTab in [false, true]) {
    testWidgets(
      'Go to page jumps directly and keeps ${searchTab ? 'Search' : 'Mail'} context',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = PagingApi(pageCount: 6990);
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        if (searchTab) {
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'saved query');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
        }
        await tester.scrollUntilVisible(
          find.byTooltip('Go to page'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Go to page'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, '4000');
        await tester.tap(find.widgetWithText(FilledButton, 'Go'));
        await tester.pumpAndSettle();
        expect(api.lastRequestedPage, 4000);
        expect(api.lastQuery, searchTab ? 'saved query' : '');
        expect(find.text('Page 4000 message 0').hitTestable(), findsOneWidget);
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          0,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'million-page footer wraps without overlapping on narrow large-text display',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({
        'connection': jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        }),
      });
      final api = PagingApi(pageCount: 1000000);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(3)),
            child: child!,
          ),
          home: ArchiveHome(apiFactory: (_, _) => api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('Go to page'),
        500,
        maxScrolls: 100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Go to page'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '1000000',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Go'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Older'),
        500,
        maxScrolls: 100,
        scrollable: find.byType(Scrollable).first,
      );
      final rects = [
        tester.getRect(find.widgetWithText(TextButton, 'Newer')),
        tester.getRect(find.byTooltip('Go to page')),
        tester.getRect(find.widgetWithText(TextButton, 'Older')),
      ];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse);
        }
      }
      expect(find.text('1000000 / 1000000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final searchTab in [false, true]) {
    testWidgets(
      'Older and Newer start at the top after success in ${searchTab ? 'Search' : 'Mail'}',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = PagingApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        if (searchTab) {
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'retained query');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
        }
        await tester.scrollUntilVisible(
          find.text('Older'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(scroll.pixels, greaterThan(0));
        final before = scroll.pixels;
        api.holdNext = true;
        await tester.tap(find.text('Older'));
        await tester.pump();
        expect(scroll.pixels, before);
        api.pendingPage.complete(api.response(2));
        await tester.pumpAndSettle();
        expect(scroll.pixels, 0);
        expect(find.text('Page 2 message 0').hitTestable(), findsOneWidget);
        expect(api.lastQuery, searchTab ? 'retained query' : '');
        await tester.scrollUntilVisible(
          find.text('Newer'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(scroll.pixels, greaterThan(0));
        await tester.tap(find.text('Newer'));
        await tester.pumpAndSettle();
        expect(scroll.pixels, 0);
        expect(find.text('Page 1 message 0').hitTestable(), findsOneWidget);
        expect(api.lastQuery, searchTab ? 'retained query' : '');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final searchTab in [false, true]) {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets(
        'scrolled ${searchTab ? 'Search' : 'Mail'} refresh failure is visible and retryable on $platform',
        (tester) async {
          FlutterSecureStorage.setMockInitialValues({
            'connection': jsonEncode({
              'server': 'https://example.com',
              'key': 'test-only',
            }),
          });
          final api = PagingApi();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: ArchiveHome(apiFactory: (_, _) => api),
            ),
          );
          await tester.pumpAndSettle();
          if (searchTab) {
            await tester.tap(find.byIcon(Icons.search).last);
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), 'retained query');
            await tester.testTextInput.receiveAction(TextInputAction.search);
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
          }
          await tester.scrollUntilVisible(
            find.text('Older'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          final scroll = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          final before = scroll.pixels;
          expect(before, greaterThan(0));
          api.holdNext = true;
          await tester.tap(find.byTooltip('Refresh'));
          await tester.pump();
          api.pendingPage.completeError(
            const SocketException('private server detail'),
          );
          await tester.pumpAndSettle();
          expect(scroll.pixels, before);
          final notification = find.byType(SnackBar);
          expect(notification, findsOneWidget);
          expect(
            find
                .descendant(
                  of: notification,
                  matching: find.text(readableError(const SocketException(''))),
                )
                .hitTestable(),
            findsOneWidget,
          );
          expect(find.textContaining('private server detail'), findsNothing);
          expect(
            find
                .descendant(of: notification, matching: find.text('Retry'))
                .hitTestable(),
            findsOneWidget,
          );
          final requests = api.pageRequests;
          await tester.tap(
            find.descendant(of: notification, matching: find.text('Retry')),
          );
          await tester.pumpAndSettle();
          expect(api.pageRequests, requests + 1);
          expect(api.lastQuery, searchTab ? 'retained query' : '');
          expect(api.lastRequestedPage, 1);
          expect(scroll.pixels, before);
          expect(find.byType(SnackBar), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final searchTab in [false, true]) {
    testWidgets(
      'folder refresh recovers earlier ${searchTab ? 'Search' : 'Mail'} error',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = SectionRecoveryApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        if (searchTab) {
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'retained query');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
        }
        api.networkOffline = true;
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text(readableError(const SocketException(''))),
          findsWidgets,
        );
        api.networkOffline = false;
        final before = api.pageRequests;
        await tester.tap(find.byTooltip('Reload folders'));
        await tester.pumpAndSettle();
        expect(api.pageRequests, before + 1);
        expect(api.lastQuery, searchTab ? 'retained query' : '');
        expect(
          find.text(readableError(const SocketException(''))),
          findsNothing,
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final outcome in ['recovered', 'offline', 'mail denied']) {
    testWidgets(
      'archive information refresh revalidates prior mail error: $outcome',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = SectionRecoveryApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        api.networkOffline = true;
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.settings_outlined).last);
        await tester.pumpAndSettle();
        expect(
          find.text(readableError(const SocketException(''))),
          findsWidgets,
        );
        api.networkOffline = outcome == 'offline';
        api.mailDenied = outcome == 'mail denied';
        await tester.ensureVisible(
          find.byTooltip('Refresh archive information'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Refresh archive information'));
        await tester.pumpAndSettle();
        if (outcome == 'recovered') {
          expect(
            find.text(readableError(const SocketException(''))),
            findsNothing,
          );
          expect(find.text('Archived messages'), findsOneWidget);
        } else if (outcome == 'offline') {
          expect(
            find.text(readableError(const SocketException(''))),
            findsWidgets,
          );
        } else {
          expect(
            find.text(readableError(const ArchiveFailure(403))),
            findsOneWidget,
          );
          expect(find.text('Archived messages'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed pagination preserves the current list position', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'https://example.com',
        'key': 'test-only',
      }),
    });
    final api = PagingApi();
    await tester.pumpWidget(
      MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Older'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final before = scroll.pixels;
    api.holdNext = true;
    await tester.tap(find.text('Older'));
    await tester.pump();
    api.pendingPage.completeError(const ArchiveFailure(500));
    await tester.pumpAndSettle();
    expect(scroll.pixels, before);
    await tester.scrollUntilVisible(
      find.text('1 / 3'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('1 / 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final staleFailure in [false, true]) {
    testWidgets(
      'forgotten archive cannot restore stale folder ${staleFailure ? 'errors' : 'results'}',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://old.example.com',
            'key': 'test-only',
          }),
        });
        final oldApi = SwitchingArchiveApi('Old Inbox');
        final newApi = SwitchingArchiveApi('New Inbox');
        await tester.pumpWidget(
          MaterialApp(
            home: ArchiveHome(
              apiFactory: (uri, _) =>
                  uri.host == 'old.example.com' ? oldApi : newApi,
            ),
          ),
        );
        await tester.pumpAndSettle();
        oldApi.delayFolders = true;
        await tester.tap(find.byTooltip('Reload folders'));
        await tester.pump();
        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Disconnect and forget connection'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disconnect and forget connection'));
        await tester.pumpAndSettle();
        expect(oldApi.closed, isTrue);
        expect(
          await const FlutterSecureStorage().read(key: 'connection'),
          isNull,
        );
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'https://new.example.com');
        await tester.enterText(fields.at(1), 'test-only-new');
        await tester.ensureVisible(find.text('Connect to archive'));
        await tester.tap(find.text('Connect to archive'));
        await tester.pumpAndSettle();
        if (staleFailure) {
          oldApi.delayedFolders.completeError(const ArchiveFailure(401));
        } else {
          oldApi.delayedFolders.complete([
            const ArchiveFolder('Stale private folder', 'stale', 1, 0),
          ]);
        }
        await tester.pumpAndSettle();
        expect(find.text('Could not load folders. Tap Retry.'), findsNothing);
        await tester.tap(find.byIcon(Icons.folder_outlined).first);
        await tester.pumpAndSettle();
        expect(find.text('New Inbox'), findsOneWidget);
        expect(find.text('Stale private folder'), findsNothing);
        expect(find.text('Old Inbox'), findsNothing);
        expect(newApi.closed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final staleError in [false, true]) {
    testWidgets(
      'new search starts immediately and ignores outdated ${staleError ? 'failure' : 'results'}',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = DelayedSearchApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.search).last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'slow');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(find.textContaining('Searching…'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.arrow_forward),
              )
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.textContaining(RegExp(r'Searching… \d+ s')),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), 'new query');
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.arrow_forward),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('Run search'));
        await tester.pumpAndSettle();
        expect(api.lastQuery, 'new query');
        expect(find.textContaining('Search complete'), findsOneWidget);
        expect(find.textContaining('Searching…'), findsNothing);
        if (staleError) {
          api.pending.completeError(const ArchiveFailure(401));
        } else {
          api.pending.complete({
            'items': [
              {'id': 999, 'from': 'Old', 'subject': 'Obsolete result'},
            ],
            'page': 1,
            'totalPages': 1,
          });
        }
        await tester.pumpAndSettle();
        expect(find.text('Obsolete result'), findsNothing);
        expect(find.text('Your API key was not accepted.'), findsNothing);
        expect(find.textContaining('Search complete'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final useMail in [false, true]) {
    testWidgets(
      '${useMail ? 'Mail tab' : 'Clear search'} clears query, preserves folder, and supersedes pending search',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = DelayedSearchApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.folder_outlined).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inbox'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.search).last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'slow');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(api.lastQuery, 'slow');
        if (useMail) {
          await tester.tap(find.byIcon(Icons.inbox_outlined));
        } else {
          await tester.tap(find.byTooltip('Clear search'));
        }
        await tester.pump();
        // The cleared request must finish before the outdated request does.
        await tester.pumpAndSettle();
        expect(api.lastQuery, '');
        api.pending.complete({
          'items': [
            {'id': 999, 'from': 'Stale search', 'subject': 'Stale result'},
          ],
          'page': 1,
          'totalPages': 1,
        });
        await tester.pumpAndSettle();
        expect(api.lastQuery, '');
        expect(api.lastFolder, 'INBOX');
        expect(api.lastPage, 1);
        expect(find.text('Stale result'), findsNothing);
        if (useMail) {
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byTooltip('Clear search'), findsNothing);
      },
    );
  }
  testWidgets(
    'Search navigation reveals and focuses input from a scrolled list and submits query',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'connection': jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        }),
      });
      final api = SearchApi();
      await tester.pumpWidget(
        MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Landscape message 20'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byIcon(Icons.search).last);
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), 'test search');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.lastQuery, 'test search');
      await tester.scrollUntilVisible(
        find.text('Landscape message 20'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byIcon(Icons.search).last);
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'test search',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final succeeds in [true, false]) {
    testWidgets(
      'saved startup hides setup until restoration ${succeeds ? 'succeeds' : 'fails'}',
      (tester) async {
        final saved = jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        });
        FlutterSecureStorage.setMockInitialValues({'connection': saved});
        final api = StartupApi();
        await tester.pumpWidget(
          MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Connecting to your archive…'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Connect to archive'), findsNothing);
        if (succeeds) {
          api.pendingAccounts.complete([
            {'id': 1, 'emailAddress': 'test@example.com'},
          ]);
        } else {
          api.pendingAccounts.completeError(const SocketException('offline'));
        }
        await tester.pumpAndSettle();
        expect(find.text('Connecting to your archive…'), findsNothing);
        expect(
          find.text('Retry saved connection'),
          succeeds ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(TextField),
          succeeds ? findsNothing : findsNWidgets(2),
        );
        expect(
          jsonDecode(
            (await const FlutterSecureStorage().read(key: 'connection'))!,
          ),
          succeeds
              ? {
                  ...jsonDecode(saved) as Map<String, dynamic>,
                  'version': 2,
                  'serverType': 'mail-archiver',
                  'accountId': '1',
                }
              : jsonDecode(saved),
        );
      },
    );
  }
  testWidgets(
    'landscape with largest text can scroll mail and search to pagination',
    (tester) async {
      tester.view.physicalSize = const Size(780, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({
        'connection': jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        }),
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(3)),
            child: child!,
          ),
          home: ArchiveHome(apiFactory: (_, _) => LandscapeApi()),
        ),
      );
      await tester.pumpAndSettle();
      for (var tab = 0; tab < 2; tab++) {
        if (tab == 1) {
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
        }
        await tester.scrollUntilVisible(
          find.text('Landscape message 29').hitTestable(),
          80,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 200,
        );
        expect(find.text('Landscape message 29').hitTestable(), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Older'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Older').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'failure messages distinguish actionable causes without private details',
    () {
      expect(readableError(const ArchiveFailure(403)), contains('permission'));
      expect(
        readableError(const HandshakeException('secret')),
        contains('certificate'),
      );
      expect(readableError(TimeoutException('secret')), contains('too long'));
      expect(
        readableError(const FormatException('secret')),
        contains('unexpected response'),
      );
      expect(
        readableError(const FormatException('secret')),
        isNot(contains('secret')),
      );
    },
  );

  testWidgets(
    'offline startup retries saved credentials without entering key',
    (tester) async {
      final saved = jsonEncode({
        'server': 'https://example.com',
        'key': 'test-only',
      });
      FlutterSecureStorage.setMockInitialValues({'connection': saved});
      final api = RecoveryApi();
      await tester.pumpWidget(
        MaterialApp(home: ArchiveHome(apiFactory: (_, _) => api)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Unable to connect'), findsOneWidget);
      expect(find.text('test-only'), findsNothing);
      api.offline = false;
      await tester.ensureVisible(find.text('Retry saved connection'));
      await tester.tap(find.text('Retry saved connection'));
      await tester.pumpAndSettle();
      expect(api.accountRequests, 2);
      expect(find.text('Retry saved connection'), findsNothing);
      expect(
        find.text('No messages match this folder and search.'),
        findsOneWidget,
      );
      expect(
        jsonDecode(
          (await const FlutterSecureStorage().read(key: 'connection'))!,
        ),
        {
          ...jsonDecode(saved) as Map<String, dynamic>,
          'version': 2,
          'serverType': 'mail-archiver',
          'accountId': '1',
        },
      );
    },
  );

  testWidgets(
    'reader retry clears old error and long body scrolls in landscape with large text',
    (tester) async {
      tester.view.physicalSize = const Size(780, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ReaderApi();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(3)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MessageReader(api: api, id: 1),
                  ),
                ),
                child: const Text('Read message'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Read message'));
      await tester.pumpAndSettle();
      expect(find.text('Your API key was not accepted.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.text('Your API key was not accepted.'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      api.response.complete({
        'subject': 'Long message',
        'from': 'test@example.com',
        'textBody': List.generate(
          80,
          (i) => 'Archived paragraph $i.',
        ).join('\n\n'),
      });
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(1000));
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Read message'), findsOneWidget);
    },
  );
}
