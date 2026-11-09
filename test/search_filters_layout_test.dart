import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/search_filters.dart';

Future<void> openFilters(
  WidgetTester tester, {
  required Size size,
  SearchFilters initial = const SearchFilters(),
  required ValueChanged<SearchFilters?> onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(3)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showModalBottomSheet<SearchFilters>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => SearchFiltersSheet(filters: initial),
              ),
            ),
            child: const Text('Open filters'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open filters'));
  await tester.pumpAndSettle();
}

Future<void> selectChoice(WidgetTester tester, int index, String label) async {
  final control = find.byType(DropdownButton<String>).at(index);
  await tester.scrollUntilVisible(
    control,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
  final option = find.text(label).last;
  await tester.scrollUntilVisible(
    option,
    80,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(option);
  await tester.pumpAndSettle();
  final selected = find.descendant(of: control, matching: find.text(label));
  final textRect = tester.getRect(selected);
  final controlRect = tester.getRect(control);
  expect(textRect.top, greaterThanOrEqualTo(controlRect.top));
  expect(textRect.bottom, lessThanOrEqualTo(controlRect.bottom));
  expect(textRect.left, greaterThanOrEqualTo(controlRect.left));
  expect(textRect.right, lessThanOrEqualTo(controlRect.right));
  expect(tester.takeException(), isNull);
}

void main() {
  for (final size in [const Size(780, 360), const Size(320, 640)]) {
    testWidgets(
      'filter choices remain readable/selectable at 3x text in $size',
      (tester) async {
        SearchFilters? result;
        await openFilters(
          tester,
          size: size,
          onResult: (value) => result = value,
        );
        await selectChoice(tester, 0, 'Outgoing');
        await selectChoice(tester, 1, 'Received date');
        await selectChoice(tester, 2, 'Ascending');
        await tester.scrollUntilVisible(
          find.text('Apply'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(result?.parameters, {
          'direction': 'outgoing',
          'sortBy': 'receivedDate',
          'sortOrder': 'asc',
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large-text action buttons do not overlap and Reset retains defaults',
    (tester) async {
      SearchFilters? result;
      await openFilters(
        tester,
        size: const Size(320, 640),
        initial: SearchFilters(
          from: DateTime(2026, 11, 1),
          direction: 'incoming',
          sortBy: 'subject',
          sortOrder: 'asc',
        ),
        onResult: (value) => result = value,
      );
      await tester.scrollUntilVisible(
        find.text('Apply'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      final reset = tester.getRect(find.widgetWithText(TextButton, 'Reset'));
      final apply = tester.getRect(find.widgetWithText(FilledButton, 'Apply'));
      expect(reset.overlaps(apply), isFalse);
      await tester.ensureVisible(find.text('Reset'));
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Apply'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result?.active, isFalse);
      expect(result?.from, isNull);
      expect(result?.parameters, {'sortBy': 'sentDate', 'sortOrder': 'desc'});
      expect(tester.takeException(), isNull);
    },
  );
}
