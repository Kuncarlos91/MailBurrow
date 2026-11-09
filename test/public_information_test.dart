import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/public_information.dart';

void main() {
  testWidgets(
    'public links open exact HTTPS destinations without archive data',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicInformationLinks(
              openPage: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Support'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy notice'));
      await tester.pumpAndSettle();
      expect(opened.map((uri) => uri.toString()), [
        'https://mailburrow.pages.dev/',
        'https://mailburrow.pages.dev/privacy',
      ]);
      expect(
        opened.every((uri) => uri.query.isEmpty && uri.userInfo.isEmpty),
        isTrue,
      );
    },
  );

  for (final throws in [false, true]) {
    testWidgets('browser failure is readable when throws=$throws', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicInformationLinks(
              openPage: (_) async {
                if (throws) throw Exception('synthetic failure');
                return false;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Support'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not open the website.'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic failure'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
