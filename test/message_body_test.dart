import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/message_body.dart';

void main() {
  test('API text alternative length must not reject a bounded HTML layout', () {
    final source = File(
      'test/fixtures/nested_marketing_layout.html',
    ).readAsStringSync();
    final body = prepareEmailBody(source, 'API text alternative ' * 1000);
    expect(body.html.isNotEmpty, isTrue);
    expect(body.html, isNot(contains('<table')));
    expect(body.notice, contains('Simplified layout'));
    final ordinary = prepareEmailBody(
      '<p><strong>Readable HTML</strong></p>',
      'API text alternative ' * 1000,
    );
    expect(ordinary.html, contains('<strong>Readable HTML</strong>'));
  });
  test(
    'marketing layout is flattened while safe links and emphasis survive',
    () {
      final source = File(
        'test/fixtures/nested_marketing_layout.html',
      ).readAsStringSync();
      expect(RegExp('<table>').allMatches(source).length, 90);
      final body = prepareEmailBody(source, '');
      expect(body.notice, contains('Simplified layout'));
      expect(body.html, contains('<strong>'));
      expect(body.html, contains('<h1>'));
      expect(body.html, contains('https://example.invalid/link-1'));
      expect(body.html, isNot(contains('<table')));
      expect(body.html, isNot(contains('<img')));
      expect(body.html, isNot(contains('<style')));
    },
  );
  test('linear fallback still removes unsafe links and active content', () {
    final body = prepareEmailBody(
      '<table><tr><td><table><tr><td><strong>Visible</strong><a href="javascript:alert(1)" onclick="bad()">Bad link</a><script>hidden script</script><img src="https://tracker"></td></tr></table></td></tr></table>',
      '',
    );
    expect(body.html, contains('<strong>Visible</strong>'));
    expect(body.html, isNot(contains('javascript')));
    expect(body.html, isNot(contains('onclick')));
    expect(body.html, isNot(contains('hidden script')));
    expect(body.html, isNot(contains('tracker')));
  });
  testWidgets(
    'synthetic marketing layout renders and scrolls without table layout',
    (tester) async {
      final source = File(
        'test/fixtures/nested_marketing_layout.html',
      ).readAsStringSync();
      final body = prepareEmailBody(source, '');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: MessageBody(body: body)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Simplified layout'), findsOneWidget);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'complex tables flatten and excessive depth retains plain-text fallback',
    () {
      final nested =
          '<table><tr><td><table><tr><td>Visible message</td></tr></table></td></tr></table><style>hidden CSS</style><script>hidden script</script>';
      final body = prepareEmailBody(nested, '');
      expect(body.html, contains('Visible message'));
      expect(body.html, isNot(contains('<table')));
      expect(body.text, contains('Visible message'));
      expect(body.text, isNot(contains('hidden')));
      final deep =
          '${List.filled(100, '<div>').join()}Deep message${List.filled(100, '</div>').join()}';
      expect(prepareEmailBody(deep, '').html, isEmpty);
      expect(prepareEmailBody(deep, '').text, contains('Deep message'));
    },
  );
  test('oversized messages have an explicit limited preview', () {
    final body = prepareEmailBody(
      '<p>${'x' * (maxEmailHtmlLength + 10)}</p>',
      'x' * (maxEmailTextLength + 10),
    );
    expect(body.html, isEmpty);
    expect(body.text.length, maxEmailTextLength);
    expect(body.notice, contains('limited text preview'));
  });
  test(
    'bounded HTML survives an oversized text alternative and diagnostics omit content',
    () {
      final body = prepareEmailBody(
        '<p><strong>PRIVATE CONTENT</strong></p>',
        'private-text ' * 10000,
      );
      expect(body.html, contains('<strong>PRIVATE CONTENT</strong>'));
      expect(body.textLimited, isTrue);
      expect(body.displayDetails, contains('Reason: formatted-html'));
      expect(body.displayDetails, isNot(contains('PRIVATE CONTENT')));
      expect(body.displayDetails, isNot(contains('private-text')));
    },
  );
  test('plain text without HTML still obeys the preview limits', () {
    final body = prepareEmailBody('', 'x' * (maxEmailTextLength + 1));
    expect(body.html, isEmpty);
    expect(body.textLimited, isTrue);
    expect(body.notice, contains('limited text preview'));
  });
  testWidgets('fallback offers privacy-safe display details', (tester) async {
    final body = prepareEmailBody(
      '${'<div>' * 100}PRIVATE CONTENT${'</div>' * 100}',
      '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MessageBody(body: body)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message display details'));
    await tester.pumpAndSettle();
    final details = tester.widget<SelectableText>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SelectableText),
      ),
    );
    expect(details.data, contains('layout-depth-limit'));
    expect(details.data, isNot(contains('PRIVATE CONTENT')));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
  test('worker prepares HTML without enabling remote content', () async {
    final body = await prepareEmailBodyAsync(
      '<p>Hello<img src="https://tracker"></p>',
      '',
    );
    expect(body.html, '<p>Hello</p>');
    expect(body.text, contains('Hello'));
  });
  testWidgets('simple text renders sections and keeps later text reachable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBody(
              body: PreparedEmailBody(
                '',
                '${'a' * emailTextPageLength}END OF MESSAGE',
                notice: 'Simplified text view',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('END OF MESSAGE'), findsNothing);
    await tester.ensureVisible(find.text('Next text section'));
    await tester.tap(find.text('Next text section'));
    await tester.pumpAndSettle();
    expect(find.text('END OF MESSAGE'), findsOneWidget);
  });
  test('removes remote content, scripts, styles, and active attributes', () {
    final result = safeEmailHtml(
      '<style>bad CSS</style><p style="background:url(https://tracker)">Hello <b>world</b><img src="https://tracker"><script>bad()</script><iframe src="https://tracker"></iframe><a href="https://example.com" onclick="bad()">Read</a></p>',
    );
    expect(
      result,
      '<p>Hello <b>world</b><a href="https://example.com">Read</a></p>',
    );
  });
  test('allows only credential-free HTTP and HTTPS links', () {
    for (final value in [
      'javascript:alert(1)',
      'file:///secret',
      'data:text/html,test',
      'https://user:secret@example.com',
      '/relative',
    ]) {
      expect(webLink(value), isNull);
    }
    expect(webLink('https://example.com/path?q=hello')?.host, 'example.com');
    expect(safeEmailHtml('<a href="javascript:alert(1)">Label</a>'), 'Label');
  });
  test('plain text is escaped and web URLs are linked', () {
    final result = plainEmailHtml(
      '<script>not markup</script>\nhttps://example.com',
    );
    expect(result, contains('&lt;script&gt;'));
    expect(result, contains('<a href="https://example.com">'));
    expect(result, contains('<br>'));
  });
}
