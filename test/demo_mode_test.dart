import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/demo/demo_archive.dart';
import 'package:mailburrow/demo/demo_banner.dart';
import 'package:mailburrow/screens/archive_home.dart';
import 'package:mailburrow/screens/settings_view.dart';
import 'package:mailburrow/screens/setup_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String archiveJson;

  // Read the asset outside the fake test clock, then build each demo from it.
  setUpAll(() async {
    archiveJson = await rootBundle.loadString(demoArchiveAsset);
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Widget app({double textScale = 1}) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: ArchiveHome(
      demoLoader: () async =>
          DemoArchive.parse(archiveJson, latency: Duration.zero),
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

  final banner = find.text('Demo · sample mail');

  testWidgets('Try the demo opens labelled sample mail', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final caption = find.text(
      'Sample mail built into the app. No server needed.',
    );
    await tester.scrollUntilVisible(
      caption,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(caption, findsOneWidget);
    await startDemo(tester);

    expect(banner, findsOneWidget);
    expect(find.text('Welcome to the MailBurrow demo'), findsOneWidget);
    expect(find.text('Connect to archive'), findsNothing);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Search'));
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
  });

  testWidgets('Settings shows the demo and Exit demo returns to setup', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await startDemo(tester);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();

    expect(banner, findsOneWidget);
    expect(find.text('Built-in demo, no server'), findsOneWidget);
    expect(find.text('Demo mode'), findsOneWidget);
    expect(find.text('Disconnect and forget connection'), findsNothing);
    final exit = find.text('Exit demo');
    await tester.scrollUntilVisible(
      exit,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(exit);
    await tester.pumpAndSettle();

    expect(banner, findsNothing);
    expect(find.text('Connect to archive'), findsOneWidget);
    expect(find.text('Try the demo'), findsOneWidget);
  });

  testWidgets('the banner Exit button leaves the demo', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await startDemo(tester);
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(find.text('Connect to archive'), findsOneWidget);
  });

  testWidgets('the message reader shows the banner and can exit', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await startDemo(tester);
    await tester.tap(find.text('Welcome to the MailBurrow demo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Let the message body finish preparing in its background isolate.
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Welcome to the MailBurrow demo'), findsOneWidget);
    expect(banner, findsOneWidget);
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();
    expect(find.text('Message'), findsNothing);
    expect(banner, findsNothing);
    expect(find.text('Connect to archive'), findsOneWidget);
  });

  Future<void> openConnectionSettings(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    if (tester.view.physicalSize.width < 1000 &&
        MediaQuery.of(tester.element(find.byType(SettingsView))).textScaler.scale(10) > 20) {
      final list = find.descendant(of: find.byType(SettingsView), matching: find.byType(Scrollable)).first;
      final raw = find.text('Connection settings');
      final position = tester.state<ScrollableState>(list).position;
      fail('settings=${tester.getRect(find.byType(SettingsView))} list=${tester.getRect(list)} '
          'tile=${raw.evaluate().isEmpty ? 'unbuilt' : tester.getRect(raw)} '
          'nav=${tester.getRect(find.byType(NavigationBar))} banner=${tester.getRect(find.byType(DemoBanner))} '
          'pixels=${position.pixels} max=${position.maxScrollExtent} viewport=${position.viewportDimension} '
          'view=${tester.view.physicalSize}');
    }
    // Scroll until the row can actually be tapped: at large text it can
    // otherwise sit behind the navigation bar.
    final tile = find.text('Connection settings').hitTestable();
    await tester.scrollUntilVisible(
      tile,
      60,
      scrollable: find
          .descendant(
            of: find.byType(SettingsView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(SetupView), findsOneWidget);
  }

  testWidgets('Connection settings keeps the banner; Cancel and Exit work', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await startDemo(tester);

    await openConnectionSettings(tester);
    expect(banner, findsOneWidget);
    expect(find.text('Try the demo'), findsNothing);
    final cancel = find.text('Cancel').hitTestable();
    await tester.scrollUntilVisible(
      cancel,
      60,
      scrollable: find
          .descendant(
            of: find.byType(SetupView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
    expect(find.byType(SetupView), findsNothing);

    await openConnectionSettings(tester);
    expect(banner, findsOneWidget);
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(find.text('Connect to archive'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Try the demo'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Try the demo'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  for (final size in [const Size(320, 640), const Size(780, 360)]) {
    testWidgets('demo entry and banner fit at 3x text in $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(textScale: 3));
      await tester.pumpAndSettle();
      await startDemo(tester);
      expect(banner, findsOneWidget);
      expect(find.text('Exit').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await openConnectionSettings(tester);
      expect(banner, findsOneWidget);
      expect(find.text('Exit').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Exit'));
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
