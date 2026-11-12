import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';

void main() {
  test(
    'attachment flags are strict while account state keeps its display fallback',
    () {
      expect(
        ArchiveAccount.fromJson({
          'id': 1,
          'isEnabled': 'true',
        }).archivingEnabled,
        isNull,
        reason: 'display-only account fields fall back to "not reported"',
      );
      expect(
        () => MailSummary.fromJson({'id': 1, 'hasAttachments': 1}),
        throwsFormatException,
      );
      expect(ArchiveAccount.fromJson({'id': 1}).archivingEnabled, isNull);
      expect(MailSummary.fromJson({'id': 1}).hasAttachments, isFalse);
    },
  );

  test(
    'paging rejects invalid bounds but accepts an empty zero-page result',
    () {
      for (final page in [0, -1]) {
        expect(
          () => MailPage.fromJson({'items': [], 'page': page, 'totalPages': 1}),
          throwsFormatException,
        );
      }
      expect(
        () => MailPage.fromJson({'items': [], 'page': 1, 'totalPages': -1}),
        throwsFormatException,
      );
      final empty = MailPage.fromJson({
        'items': [],
        'page': 1,
        'totalPages': 0,
        'totalItems': 0,
      });
      expect(empty.items, isEmpty);
      expect(empty.totalPages, 0);
      expect(empty.totalItems, 0);
    },
  );

  test('malformed attachment metadata fails with FormatException', () {
    for (final fields in <Map<String, Object?>>[
      {'fileName': 5},
      {'contentType': <String>[]},
      {'size': 'six'},
      {'size': double.nan},
      {'size': double.infinity},
    ]) {
      expect(
        () => MailAttachment.fromJson({'id': 1, ...fields}),
        throwsFormatException,
        reason: fields.keys.join(','),
      );
      expect(
        () => MailMessage.fromJson({
          'attachments': [
            {'id': 1, ...fields},
          ],
        }),
        throwsFormatException,
      );
    }
    final unknown = MailAttachment.fromJson({'id': 1, 'size': -1});
    expect(unknown.size, -1);
    expect(unknown.name, 'attachment');
    expect(unknown.contentType, 'application/octet-stream');
  });

  test('wrong text types are rejected rather than becoming empty content', () {
    for (final field in [
      'subject',
      'from',
      'sentDate',
      'folderName',
      'htmlBody',
      'textBody',
    ]) {
      expect(
        () => MailMessage.fromJson({field: 42}),
        throwsFormatException,
        reason: field,
      );
    }
    for (final field in ['subject', 'from', 'sentDate']) {
      expect(
        () => MailSummary.fromJson({'id': 1, field: false}),
        throwsFormatException,
      );
    }
    // Display-only account fields keep 0.3.0's "not reported" fallback.
    final odd = ArchiveAccount.fromJson({
      'id': 1,
      'emailAddress': <Object>[],
      'lastSync': 5,
    });
    expect(odd.address, 'Email address not reported');
    expect(odd.lastSync, isNull);
    expect(MailMessage.fromJson(<String, dynamic>{}).htmlBody, '');
    expect(MailMessage.fromJson({'textBody': null}).textBody, '');
    expect(MailSummary.fromJson({'id': 1}).subject, isNull);
    expect(
      ArchiveAccount.fromJson({'id': 1}).address,
      'Email address not reported',
    );
    // Dates remain supplied text; the date widget decides whether to display them.
    expect(
      MailSummary.fromJson({'id': 1, 'sentDate': 'unavailable'}).sentDate,
      'unavailable',
    );
  });
}
