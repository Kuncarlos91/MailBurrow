import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/third_party_licenses.dart';

void main() {
  testWidgets('offline notices open, display a registered license and return', (
    tester,
  ) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks([
        'synthetic_component',
      ], 'Synthetic notice retained for this test.');
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ThirdPartyLicensesTile())),
    );
    await tester.tap(find.text('Open source licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('MailBurrow'), findsOneWidget);
    await tester.tap(find.text('synthetic_component'));
    await tester.pumpAndSettle();
    expect(
      find.text('Synthetic notice retained for this test.'),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open source licenses'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('license entry remains reachable at large text in landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks([
        'synthetic_component',
      ], 'Synthetic notice.');
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(3)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: ThirdPartyLicensesTile()),
        ),
      ),
    );
    await tester.tap(find.text('Open source licenses'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('synthetic_component'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('synthetic_component').hitTestable(), findsOneWidget);
    await tester.tap(find.text('synthetic_component'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic notice.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
