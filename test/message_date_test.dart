import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/message_date.dart';
import 'package:mailburrow/screens/archive_home.dart';

class DatedApi extends ArchiveApi {
  DatedApi() : super(Uri.parse('https://example.com'), 'test-only');
  Map<String, dynamic> get mail => {
    'id': 1,
    'from': 'Synthetic sender',
    'subject': 'Synthetic dated message',
    'sentDate': '2026-11-01T14:35:00Z',
    'textBody': 'Synthetic body',
    'hasAttachments': true,
  };
  @override
  Future<List<ArchiveAccount>> accounts() async => [
    {'id': 1},
  ].map(ArchiveAccount.fromJson).toList();
  @override
  Future<List<ArchiveFolder>> folders(String id) async => [];
  @override
  Future<MailPage> emails(
    String id,
    String query,
    int page, {
    String? folder,
    dynamic filters,
  }) async => MailPage.fromJson({
    'items': [mail],
    'page': 1,
    'totalPages': 1,
  });
  @override
  Future<MailMessage> message(String id) async => MailMessage.fromJson(mail);
}

void main() {
  test('explicit offsets retain the instant and use device local time', () {
    final parsed = MessageTimestamp.parse('2026-11-01T00:35:00.1234567+02:00')!;
    expect(parsed.date.toUtc(), DateTime.parse('2026-10-31T22:35:00.123456Z'));
    expect(parsed.date.isUtc, isFalse);
    expect(parsed.hasZone, isTrue);
    expect(parsed.hasTime, isTrue);
  });
  test('zone-less timestamps preserve their supplied calendar and time', () {
    final parsed = MessageTimestamp.parse('2026-11-01T14:35:00')!;
    expect(parsed.hasZone, isFalse);
    expect(parsed.date.hour, 14);
    expect(MessageTimestamp.parse('2026-03-08T02:30:00')!.date.hour, 2);
    expect(MessageTimestamp.parse('2026-11-01')!.hasTime, isFalse);
  });
  test('missing, malformed, rolled over and default dates are unavailable', () {
    for (final value in [
      null,
      123,
      '',
      'not a date',
      '2026-02-30T00:00:00Z',
      '2026-13-01',
      '0001-01-01T00:00:00',
      '2026-11-01T25:00:00Z',
    ]) {
      expect(MessageTimestamp.parse(value), isNull, reason: '$value');
    }
  });
  testWidgets(
    'full header labels unspecified zone and date-only does not invent time',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MessageDate(value: '2026-11-01T14:35:00', detailed: true),
                MessageDate(value: '2026-11-01', detailed: true),
                MessageDate(value: null, detailed: true),
              ],
            ),
          ),
        ),
      );
      expect(find.textContaining('time zone unspecified'), findsOneWidget);
      expect(
        find.textContaining('Sent: Sunday, November 1, 2026'),
        findsNWidgets(2),
      );
      expect(find.text('Sent date unavailable'), findsOneWidget);
    },
  );
  testWidgets(
    'Mail, Search and reader display supplied sent date alongside attachment indicator',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'connection': jsonEncode({
          'server': 'https://example.com',
          'key': 'test-only',
        }),
      });
      await tester.pumpWidget(
        MaterialApp(home: ArchiveHome(apiFactory: (_, _) => DatedApi())),
      );
      await tester.pumpAndSettle();
      final timestamp = DateTime.parse('2026-11-01T14:35:00Z').toLocal();
      final context = tester.element(find.byType(ArchiveHome));
      final date = MaterialLocalizations.of(context).formatShortDate(timestamp);
      expect(find.text(date).hitTestable(), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      await tester.tap(find.byIcon(Icons.search).last);
      await tester.pumpAndSettle();
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(find.text(date).hitTestable(), findsOneWidget);
      await tester.tap(find.text('Synthetic dated message'));
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          await tester.pump();
          if (find.textContaining('local time').evaluate().isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Sent:').hitTestable(), findsOneWidget);
      expect(find.textContaining('local time'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'date header wraps at large text in narrow landscape without clipping',
    (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(640, 320),
              textScaler: TextScaler.linear(3),
            ),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: MessageDate(
                    value: '2026-11-01T14:35:00Z',
                    detailed: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('local time'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
