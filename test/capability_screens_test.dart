import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_capabilities.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/demo/demo_archive.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';

/// A server like the planned Open Archiver backend: no folders, no direction
/// filter, date sort only, estimated totals and no per-key archive totals.
/// The narrowed demo throws if a screen asks it for any of those.
final reduced = ArchiveCapabilities(
  folders: false,
  dateRangeFilter: true,
  directionFilter: false,
  sortFields: {'sentDate'},
  sortOrders: {'desc', 'asc'},
  estimatedTotals: true,
  archiveStats: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String archiveJson;

  setUpAll(() async {
    archiveJson = await rootBundle.loadString(demoArchiveAsset);
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('supported() returns unsupported choices to their defaults', () {
    final kept = reduced.supported(
      SearchFilters(
        from: DateTime(2021),
        to: DateTime(2021, 12, 31),
        direction: 'outgoing',
        sortBy: 'subject',
        sortOrder: 'asc',
      ),
    );
    expect(kept.from, DateTime(2021));
    expect(kept.to, DateTime(2021, 12, 31));
    expect(kept.direction, '');
    expect(kept.sortBy, 'sentDate');
    expect(kept.sortOrder, 'asc');
    expect(reduced.allows(kept), isTrue);
    final full = ArchiveCapabilities.full.supported(
      const SearchFilters(direction: 'incoming', sortBy: 'from'),
    );
    expect(full.direction, 'incoming');
    expect(full.sortBy, 'from');
  });

  test('the session never sends unsupported requests', () async {
    final session = ArchiveSession(
      demoLoader: () async =>
          DemoArchive.load(latency: Duration.zero, capabilities: reduced),
    );
    addTearDown(session.dispose);
    await session.startDemo();
    expect(session.error, isNull);
    expect(session.folders, isEmpty);
    expect(session.folderError, isNull);
    await session.loadFolders();
    expect(session.folderError, isNull);
    await session.selectFolder(const ArchiveFolder('Receipts', 'Receipts', 1, 0));
    expect(session.selectedFolder, isNull);
    await session.applyFilters(
      SearchFilters(
        from: DateTime(2021),
        direction: 'outgoing',
        sortBy: 'subject',
      ),
    );
    expect(session.error, isNull);
    expect(session.filters.from, DateTime(2021));
    expect(session.filters.direction, '');
    expect(session.filters.sortBy, 'sentDate');
    expect(session.messages, isNotEmpty);
    expect(session.searchFeedback, matches(RegExp(r'about \d+ matches')));
  });

  Widget app(ArchiveCapabilities? capabilities) => MaterialApp(
    home: ArchiveHome(
      demoLoader: () async => DemoArchive.parse(
        archiveJson,
        latency: Duration.zero,
        capabilities: capabilities,
      ),
    ),
  );

  Future<void> startDemo(WidgetTester tester) async {
    final button = find.text('Try the demo');
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> openFilters(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
  }

  testWidgets('the full demo keeps folders and every filter', (tester) async {
    await tester.pumpWidget(app(null));
    await tester.pumpAndSettle();
    await startDemo(tester);
    expect(find.text('All archived mail ▾'), findsOneWidget);
    expect(find.byTooltip('Reload folders'), findsOneWidget);
    await openFilters(tester);
    expect(find.text('Sent date range · inclusive'), findsOneWidget);
    expect(find.text('Direction'), findsOneWidget);
    expect(find.text('Sort by'), findsOneWidget);
    expect(find.text('Order'), findsOneWidget);
  });

  testWidgets('a server without folders, some filters or totals', (
    tester,
  ) async {
    await tester.pumpWidget(app(reduced));
    await tester.pumpAndSettle();
    await startDemo(tester);

    // Mail loads without a folder request or folder controls.
    expect(find.text('Welcome to the MailBurrow demo'), findsOneWidget);
    expect(find.text('All archived mail ▾'), findsNothing);
    expect(find.byTooltip('Reload folders'), findsNothing);
    expect(find.text('Could not load folders. Tap Retry.'), findsNothing);

    // Only supported filters are offered, and applying them works.
    await openFilters(tester);
    expect(find.text('Sent date range · inclusive'), findsOneWidget);
    expect(find.text('Direction'), findsNothing);
    expect(find.text('Sort by'), findsNothing);
    expect(find.text('Order'), findsOneWidget);
    await tester.ensureVisible(find.text('Apply'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to the MailBurrow demo'), findsOneWidget);

    // Estimated totals are labelled as estimates.
    await tester.tap(find.widgetWithText(NavigationDestination, 'Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('about 40 matches'), findsOneWidget);

    // Settings shows account details but no server-wide totals.
    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    final accounts = find.text('Email accounts');
    await tester.scrollUntilVisible(
      accounts,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(accounts, findsOneWidget);
    expect(find.textContaining('Archiving:'), findsOneWidget);
    expect(
      find.text('Totals across all accounts accessible to this API key'),
      findsNothing,
    );
    expect(find.text('Archived messages'), findsNothing);
  });
}
