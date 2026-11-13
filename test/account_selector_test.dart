import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/search_filters.dart';
import 'support/saved_connection.dart';

class AccountsApi extends ArchiveApi {
  AccountsApi() : super(Uri.parse('https://example.com'), 'test-only');
  List<Map<String, dynamic>> available = [
    {'id': 1, 'emailAddress': 'first@example.com'},
    {'id': 2, 'emailAddress': 'second@example.com'},
  ];
  bool holdSecond = false;
  final secondMail = Completer<Map<String, dynamic>>();
  bool failAccounts = false,
      failSecond = false,
      delayMail = false,
      delayFolders = false;
  final pendingMail = Completer<Map<String, dynamic>>();
  final pendingFolders = Completer<List<ArchiveFolder>>();
  String lastId = '';
  int lastPage = 0, mailCalls = 0;
  String lastQuery = '';
  String? lastFolder;
  SearchFilters lastFilters = const SearchFilters();
  Map<String, dynamic> response(int id, int page) => {
    'items': List.generate(
      20,
      (i) => {
        'id': id * 100 + i,
        'from': 'Synthetic sender',
        'subject': 'Account $id message $i',
      },
    ),
    'page': page,
    'totalPages': 3,
  };
  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (failAccounts) throw const SocketException('private detail');
    return available.map(ArchiveAccount.fromJson).toList();
  }

  @override
  Future<MailPage> emails(
    String id,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    lastId = id;
    lastPage = page;
    lastQuery = query;
    lastFolder = folder;
    lastFilters = filters;
    mailCalls++;
    if (id == '1' && delayMail) {
      delayMail = false;
      return MailPage.fromJson(await pendingMail.future);
    }
    if (id == '2' && holdSecond) {
      holdSecond = false;
      return MailPage.fromJson(await secondMail.future);
    }
    if (id == '2' && failSecond) {
      throw const SocketException('private detail');
    }
    return MailPage.fromJson(response(int.parse(id), page));
  }

  @override
  Future<List<ArchiveFolder>> folders(String id) async {
    if (id == '1' && delayFolders) {
      delayFolders = false;
      return pendingFolders.future;
    }
    return [ArchiveFolder('Folder $id', 'Folder$id', 20, 0)];
  }

  @override
  Future<ArchiveStats> stats() async => ArchiveStats.fromJson({
    'emails': 40,
    'accounts': 2,
    'attachments': 0,
  });
}

class FailingStore extends MapBase<String, String> {
  final data = <String, String>{};
  bool fail = false;
  @override
  String? operator [](Object? key) => data[key];
  @override
  void operator []=(String key, String value) {
    if (fail) throw StateError('Synthetic storage failure');
    data[key] = value;
  }

  @override
  void clear() => data.clear();
  @override
  Iterable<String> get keys => data.keys;
  @override
  String? remove(Object? key) => data.remove(key);
}

Future<void> openApp(
  WidgetTester tester,
  AccountsApi api, {
  int? savedId,
  Map<String, String>? store,
  bool largeText = false,
}) async {
  FlutterSecureStorage.setMockInitialValues(
    store ??
        {
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
            'accountId': ?savedId,
          }),
        },
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(largeText ? 3 : 1)),
        child: child!,
      ),
      home: ArchiveHome(apiFactory: (_, _) => api),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, int id) async {
  await tester.tap(find.byTooltip('Switch account'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final tile = find.byKey(ValueKey('account-choice-$id'));
  await tester.scrollUntilVisible(
    tile,
    100,
    scrollable: find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .last,
  );
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('switch resets account-scoped folder, query, filters and page', (
    tester,
  ) async {
    final api = AccountsApi();
    await openApp(tester, api);
    await tester.tap(find.byIcon(Icons.folder_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    final direction = find.byType(DropdownButton<String>).first;
    await tester.ensureVisible(direction);
    await tester.tap(direction);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Outgoing').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Apply'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(api.lastFilters.direction, 'outgoing');
    await tester.scrollUntilVisible(
      find.text('Older'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Older'));
    await tester.pumpAndSettle();
    expect(api.lastPage, 2);
    await choose(tester, 2);
    expect(api.lastId, '2');
    expect(api.lastPage, 1);
    expect(api.lastQuery, '');
    expect(api.lastFolder, isNull);
    expect(api.lastFilters.active, isFalse);
    expect(find.text('Account 2 message 0').hitTestable(), findsOneWidget);
    expect(find.textContaining('Account 1 message'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    final saved = jsonDecode(
      (await savedConnectionText())!,
    );
    expect(saved['accountId'], '2');
    expect(saved['key'], 'test-only');
    await tester.tap(find.byIcon(Icons.folder_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('Folder 2'), findsOneWidget);
    expect(find.text('Folder 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'visible switching progress and isolated messages on $platform',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'connection': jsonEncode({
            'server': 'https://example.com',
            'key': 'test-only',
          }),
        });
        final api = AccountsApi();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: ArchiveHome(apiFactory: (_, _) => api),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Older'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        api.holdSecond = true;
        await tester.tap(find.byTooltip('Switch account'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('account-choice-2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Switching account…').hitTestable(), findsOneWidget);
        expect(find.textContaining('Account 1 message'), findsNothing);
        expect(api.lastId, '2');
        api.secondMail.complete(api.response(2, 1));
        await tester.pumpAndSettle();
        expect(find.text('Switching account…'), findsNothing);
        expect(find.text('Account 2 message 0').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rapid return to first account ignores older selection completion',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api);
      api.holdSecond = true;
      await tester.tap(find.byTooltip('Switch account'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-choice-2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Switching account…'), findsOneWidget);
      api.delayMail = true;
      await tester.tap(find.byTooltip('Switch account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('account-choice-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.lastId, '1');
      expect(find.text('Switching account…').hitTestable(), findsOneWidget);
      api.secondMail.complete(api.response(2, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Completing B must not dismiss the still-loading return to A.
      expect(find.text('Switching account…').hitTestable(), findsOneWidget);
      expect(find.textContaining('Account 2 message'), findsNothing);
      api.pendingMail.complete(api.response(1, 1));
      await tester.pumpAndSettle();
      expect(find.text('Account 1 message 0'), findsOneWidget);
      expect(find.text('Switching account…'), findsNothing);
      expect(
        jsonDecode(
          (await savedConnectionText())!,
        )['accountId'],
        '1',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restores chosen account without selecting first returned account',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api, savedId: 2);
      expect(api.lastId, '2');
      expect(find.text('second@example.com'), findsOneWidget);
      expect(find.text('Account 2 message 0'), findsOneWidget);
    },
  );

  testWidgets(
    'old settings migrate and inaccessible remembered account falls back with notice',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api, savedId: 99);
      expect(api.lastId, '1');
      expect(
        find.textContaining('Previously selected account'),
        findsOneWidget,
      );
      expect(
        jsonDecode(
          (await savedConnectionText())!,
        )['accountId'],
        '1',
      );
    },
  );

  testWidgets(
    'remembered selection survives app recreation and a one-account response',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api);
      await choose(tester, 2);
      final saved = (await const FlutterSecureStorage().read(
        key: 'connection',
      ))!;
      await tester.pumpWidget(const SizedBox.shrink());
      final next = AccountsApi()
        ..available = [
          {'id': 2, 'emailAddress': 'second@example.com'},
        ];
      await openApp(tester, next, store: {'connection': saved});
      expect(next.lastId, '2');
      await tester.tap(find.byTooltip('Switch account'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-choice-1')), findsNothing);
      expect(find.byKey(const ValueKey('account-choice-2')), findsOneWidget);
    },
  );

  testWidgets('current selection and cancelled picker do not reload mail', (
    tester,
  ) async {
    final api = AccountsApi();
    await openApp(tester, api);
    final calls = api.mailCalls;
    await choose(tester, 1);
    expect(api.mailCalls, calls);
    await tester.tap(find.byTooltip('Switch account'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(api.mailCalls, calls);
    expect(find.byKey(const ValueKey('account-choice-2')), findsNothing);
  });

  for (final failure in [false, true]) {
    testWidgets(
      'late previous-account mail ${failure ? 'failure' : 'success'} cannot replace selection',
      (tester) async {
        final api = AccountsApi();
        await openApp(tester, api);
        api.delayMail = true;
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pump();
        await choose(tester, 2);
        if (failure) {
          api.pendingMail.completeError(const ArchiveFailure(500));
        } else {
          api.pendingMail.complete(api.response(1, 1));
        }
        await tester.pumpAndSettle();
        expect(find.text('Account 2 message 0'), findsOneWidget);
        expect(find.textContaining('Account 1 message'), findsNothing);
        expect(
          find.text('The server could not complete the request.'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'late previous-account folder ${failure ? 'failure' : 'success'} is ignored',
      (tester) async {
        final api = AccountsApi();
        await openApp(tester, api);
        api.delayFolders = true;
        await tester.tap(find.byTooltip('Reload folders'));
        await tester.pump();
        await choose(tester, 2);
        if (failure) {
          api.pendingFolders.completeError(
            const SocketException('private detail'),
          );
        } else {
          api.pendingFolders.complete([
            const ArchiveFolder('Stale folder', 'STALE', 1, 0),
          ]);
        }
        await tester.pumpAndSettle();
        expect(find.text('Could not load folders. Tap Retry.'), findsNothing);
        await tester.tap(find.byIcon(Icons.folder_outlined).first);
        await tester.pumpAndSettle();
        expect(find.text('Folder 2'), findsOneWidget);
        expect(find.text('Stale folder'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed switch load has no previous messages and retries selected account',
    (tester) async {
      final api = AccountsApi()..failSecond = true;
      await openApp(tester, api);
      await choose(tester, 2);
      expect(find.textContaining('Account 1 message'), findsNothing);
      expect(find.text('second@example.com'), findsOneWidget);
      api.failSecond = false;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Account 2 message 0'), findsOneWidget);
    },
  );

  testWidgets(
    'picker failure, empty response and retry never expose cached choices',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api);
      api.failAccounts = true;
      await tester.tap(find.byTooltip('Switch account'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-choice-1')), findsNothing);
      expect(find.textContaining('private detail'), findsNothing);
      api.failAccounts = false;
      final available = api.available;
      api.available = [];
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('No accessible email accounts.'), findsOneWidget);
      api.available = available;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-choice-2')));
      await tester.pumpAndSettle();
      expect(api.lastId, '2');
    },
  );

  testWidgets(
    'storage failure preserves current account and persisted selection',
    (tester) async {
      final store = FailingStore()
        ..['connection'] = jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        });
      final api = AccountsApi();
      await openApp(tester, api, store: store);
      final saved = store['connection'];
      store.fail = true;
      await choose(tester, 2);
      expect(api.lastId, '1');
      expect(store['connection'], saved);
      expect(find.text('Account 1 message 0'), findsOneWidget);
      expect(
        find.textContaining('Your current account is unchanged.'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Settings account row switches and recreates its account metadata',
    (tester) async {
      final api = AccountsApi();
      await openApp(tester, api);
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(TextButton, 'second@example.com'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'second@example.com'));
      await tester.pumpAndSettle();
      expect(api.lastId, '2');
      expect(find.text('Account 2 message 0'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pumpAndSettle();
      final label = find.text('Currently browsing');
      expect(label, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker remains selectable in narrow landscape at largest text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = AccountsApi();
    await openApp(tester, api, largeText: true);
    await choose(tester, 2);
    expect(api.lastId, '2');
    expect(tester.takeException(), isNull);
  });
}
