import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mailburrow/app.dart';
import 'package:mailburrow/screens/archive_home.dart';

void main() {
  testWidgets('fresh install starts blank and hides the key', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MailShelfPreview());
    await tester.pumpAndSettle();
    expect(find.text('Connect to archive'), findsOneWidget);
    expect(find.text('MailBurrow'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Support'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Privacy notice'), findsOneWidget);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller!.text, isEmpty);
    expect(fields[1].controller!.text, isEmpty);
    expect(fields[1].obscureText, isTrue);
  });
  for (final size in [const Size(320, 640), const Size(780, 360)]) {
    testWidgets('self-hosted setup stays usable at 3x text in $size', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(3)),
            child: child!,
          ),
          home: const ArchiveHome(),
        ),
      );
      await tester.pumpAndSettle();
      final server = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'HTTPS server address',
      );
      await tester.scrollUntilVisible(
        server,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(server, 'archive.example.invalid');
      await tester.pumpAndSettle();
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final key = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'API key',
      );
      await tester.scrollUntilVisible(
        key,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<TextField>(key).obscureText, isTrue);
      await tester.scrollUntilVisible(
        find.text('Connect to archive'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Connect to archive'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to archive').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Connect to archive'));
      await tester.pumpAndSettle();
      // Blank key fails locally: no hosted signup or network request is needed.
      expect(find.text('Enter your API key.'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  }
}
