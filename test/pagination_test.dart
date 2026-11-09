import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/pagination.dart';

void main() {
  testWidgets('page picker validates range and accepts keyboard submission', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showArchivePagePicker(
                  context,
                  currentPage: 1,
                  totalPages: 6990,
                );
              },
              child: const Text('Choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    for (final invalid in ['', '0', '-1', '6991', 'abc']) {
      await tester.enterText(find.byType(TextField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, 'Go'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a page from 1 to 6990.'), findsOneWidget);
      expect(selected, isNull);
    }
    await tester.enterText(find.byType(TextField), '3500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(selected, 3500);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling page selection returns no request', (tester) async {
    int? selected;
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showArchivePagePicker(
                  context,
                  currentPage: 99,
                  totalPages: 6990,
                );
                completed = true;
              },
              child: const Text('Choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '99',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });
}
