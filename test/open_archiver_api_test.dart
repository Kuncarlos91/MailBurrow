import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_errors.dart';
import 'package:mailburrow/open_archiver_api.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';

import 'archive_api_test.dart' show JsonHttpClient;

// Fictional fixtures shaped like Open Archiver v0.6.2 responses.
const sourceA = 'aaaaaaaa-0000-4000-8000-000000000001';
const sourceB = 'bbbbbbbb-0000-4000-8000-000000000002';
const mailA = 'cccccccc-0000-4000-8000-000000000003';
const mailB = 'dddddddd-0000-4000-8000-000000000004';

final sources = [
  {
    'id': sourceA,
    'name': 'Alex Rivera mailbox',
    'provider': 'generic_imap',
    'preserveOriginalFile': false,
  },
  {
    'id': sourceB,
    'name': 'Compliance copy',
    'provider': 'generic_imap',
    'preserveOriginalFile': true,
  },
];

Map<String, Object?> listPage({int total = 2, int page = 1}) => {
  'items': [
    {
      'id': mailA,
      'subject': 'Garden club agenda',
      'senderName': 'Riverside Garden Club',
      'senderEmail': 'volunteers@garden.example',
      'sentAt': '2026-03-02T10:00:00.000Z',
      'hasAttachments': true,
      'path': 'INBOX',
      'ingestionSourceId': sourceA,
    },
    {
      'id': mailB,
      'subject': null,
      'senderName': '',
      'senderEmail': 'alex@example.com',
      'sentAt': '2026-03-01T09:00:00.000Z',
      'hasAttachments': false,
    },
  ],
  'total': total,
  'page': page,
  'limit': 25,
};

Map<String, Object?> searchPage({Object? totalPages}) => {
  'hits': [
    {
      'id': mailA,
      'subject': 'Garden club agenda',
      'from': 'volunteers@garden.example',
      'fromName': 'Riverside Garden Club',
      'timestamp': 1772445600,
      'hasAttachments': true,
      'ingestionSourceId': sourceA,
      // Present in real hits and never read by the app.
      'body': 'Fictional body text',
      'attachments': [
        {'filename': 'agenda.txt', 'content': 'Fictional attachment text'},
      ],
      '_formatted': {'subject': '<em>Garden</em> club agenda'},
    },
    {
      'id': mailB,
      'subject': 'Receipt',
      'from': 'shop@example.com',
      'timestamp': 1772359200000,
      'hasAttachments': false,
    },
  ],
  'total': 51,
  'page': 1,
  'limit': 25,
  'totalPages': ?totalPages,
  'processingTimeMs': 3,
};

class RecordingOpenArchiver extends OpenArchiverApi {
  RecordingOpenArchiver([this.responses = const {}])
    : super(Uri.parse('https://archive.example'), 'test-only');
  final Map<String, Object?> responses;
  String? lastPath;
  Map<String, String>? lastQuery;

  @override
  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    lastPath = path;
    lastQuery = query;
    if (path == 'ingestion-sources') return responses[path] ?? sources;
    if (path == 'search') return responses[path] ?? searchPage();
    return responses[path] ?? listPage();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sends the key as X-API-KEY under /api/v1 without redirects', () async {
    final client = JsonHttpClient(utf8.encode(jsonEncode(sources)));
    await HttpOverrides.runZoned(() async {
      final api = OpenArchiverApi(
        Uri.parse('https://example.com/archive'),
        'test-only',
      );
      final accounts = await api.accounts();
      expect(accounts.map((item) => item.id), [sourceA, sourceB]);
      expect(
        client.url.toString(),
        'https://example.com/archive/api/v1/ingestion-sources',
      );
      expect(client.request.followRedirects, isFalse);
      final headers = client.request.recordedHeaders.values.map(
        (name, value) => MapEntry(name.toLowerCase(), value),
      );
      expect(headers['x-api-key'], 'test-only');
      expect(headers.containsKey('authorization'), isFalse);
      api.close();
    }, createHttpClient: (_) => client);
  });

  test('declares what Open Archiver supports', () {
    final api = RecordingOpenArchiver();
    final capabilities = api.capabilities;
    expect(capabilities.folders, isFalse);
    expect(capabilities.dateRangeFilter, isTrue);
    expect(capabilities.directionFilter, isFalse);
    expect(capabilities.sortFields, {'sentDate'});
    expect(capabilities.sortOrders, {'desc', 'asc'});
    expect(capabilities.estimatedTotals, isTrue);
    expect(capabilities.archiveStats, isFalse);
    expect(api.isMailRequest('search'), isTrue);
    expect(api.isMailRequest('archived-emails/ingestion-source/$sourceA'), isTrue);
    expect(api.isMailRequest('ingestion-sources'), isFalse);
  });

  test('maps sources to accounts labelled by name', () async {
    final accounts = await RecordingOpenArchiver().accounts();
    expect(accounts.first.address, 'Alex Rivera mailbox');
    expect(accounts.first.emailAddress, isNull);
    expect(openArchiverPreservesOriginals(sources[0]), isFalse);
    expect(openArchiverPreservesOriginals(sources[1]), isTrue);
    expect(openArchiverSource({'id': sourceA}).address, 'Email address not reported');
    for (final bad in [
      {'id': 7.5},
      {'id': ''},
      'text',
      null,
    ]) {
      expect(() => openArchiverSource(bad), throwsFormatException);
    }
    expect(
      () => RecordingOpenArchiver({'ingestion-sources': {'id': sourceA}}).accounts(),
      throwsFormatException,
    );
  });

  test('preserve-original policy requires an explicit boolean', () {
    expect(openArchiverPreservesOriginals(sources[0]), isFalse);
    expect(openArchiverPreservesOriginals(sources[1]), isTrue);
    for (final flag in [null, 'true', 'false', 0, 1, <Object>[]]) {
      expect(
        () => openArchiverPreservesOriginals({'preserveOriginalFile': flag}),
        throwsFormatException,
      );
    }
    expect(
      () => openArchiverPreservesOriginals(<String, dynamic>{}),
      throwsFormatException,
    );
  });

  test(
    'search dates support negative epochs and reject out-of-range values',
    () {
      for (final stamp in [-315619200, -315619200000]) {
        expect(
          openArchiverSearchHit({'id': mailA, 'timestamp': stamp}).sentDate,
          '1960-01-01T00:00:00.000Z',
        );
      }
      expect(
        openArchiverSearchHit({'id': mailA, 'timestamp': -1}).sentDate,
        '1969-12-31T23:59:59.000Z',
      );
      expect(openArchiverSearchHit({'id': mailA}).sentDate, isNull);
      for (final stamp in [
        9223372036854775807,
        -9223372036854775808,
        8640000000000001,
        -8640000000000001,
      ]) {
        expect(
          () => openArchiverSearchHit({'id': mailA, 'timestamp': stamp}),
          throwsFormatException,
        );
        expect(
          () => openArchiverSearchPage({
            'hits': [
              {'id': mailA, 'timestamp': stamp},
            ],
            'total': 1,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test('a plain listing uses the source browse route with exact totals', () async {
    final api = RecordingOpenArchiver();
    final page = await api.emails(sourceA, '  ', 1);
    expect(api.lastPath, 'archived-emails/ingestion-source/$sourceA');
    expect(api.lastQuery, {'page': '1', 'limit': '25'});
    expect(page.items.map((mail) => mail.id), [mailA, mailB]);
    expect(page.items.first.from, 'Riverside Garden Club <volunteers@garden.example>');
    expect(page.items.first.sentDate, '2026-03-02T10:00:00.000Z');
    expect(page.items.first.hasAttachments, isTrue);
    expect(page.items.last.from, 'alex@example.com');
    expect(page.items.last.subject, isNull);
    expect(page.totalItems, 2);
    expect(page.totalPages, 1);
    expect(page.totalIsEstimate, isFalse);
    final more = await RecordingOpenArchiver({
      'archived-emails/ingestion-source/$sourceA': listPage(total: 51, page: 3),
    }).emails(sourceA, '', 3);
    expect(more.page, 3);
    expect(more.totalPages, 3);
    final empty = await RecordingOpenArchiver({
      'archived-emails/ingestion-source/$sourceA': {
        'items': <Object>[],
        'total': 0,
        'page': 1,
        'limit': 25,
      },
    }).emails(sourceA, '', 1);
    expect(empty.totalPages, 0);
  });

  test('searches, dates and oldest-first use search within the source', () async {
    final api = RecordingOpenArchiver();
    final page = await api.emails(
      sourceA,
      ' agenda ',
      2,
      filters: SearchFilters(
        from: DateTime(2026, 1, 5),
        to: DateTime(2026, 12, 31),
        sortOrder: 'asc',
      ),
    );
    expect(api.lastPath, 'search');
    expect(api.lastQuery, {
      'keywords': 'agenda',
      'sources': sourceA,
      'page': '2',
      'limit': '25',
      'sort': 'date_asc',
      'dateFrom': '2026-01-05',
      'dateTo': '2026-12-31',
    });
    expect(page.items.first.from, 'Riverside Garden Club <volunteers@garden.example>');
    expect(page.items.first.sentDate, '2026-03-02T10:00:00.000Z');
    expect(page.items.last.from, 'shop@example.com');
    expect(page.items.last.sentDate, '2026-03-01T10:00:00.000Z');
    expect(page.totalItems, 51);
    expect(page.totalPages, 3);
    expect(page.totalIsEstimate, isTrue);

    await api.emails(sourceA, 'x', 1);
    expect(api.lastQuery!['sort'], 'date_desc');
    expect(api.lastQuery!.containsKey('dateFrom'), isFalse);

    await api.emails(sourceA, '', 1, filters: SearchFilters(from: DateTime(2026)));
    expect(api.lastPath, 'search');
    expect(api.lastQuery!['keywords'], '');

    final reported = await RecordingOpenArchiver({
      'search': searchPage(totalPages: 4),
    }).emails(sourceA, 'x', 1);
    expect(reported.totalPages, 4);
  });

  test('rejects unsafe IDs, folders and unsupported filters before sending', () async {
    final api = RecordingOpenArchiver();
    for (final id in ['', '../$sourceA', '$sourceA/x', '$sourceA?a=b', 'a b']) {
      await expectLater(api.emails(id, '', 1), throwsFormatException, reason: id);
      expect(api.lastPath, isNull);
    }
    await expectLater(
      api.emails(sourceA, '', 1, folder: 'INBOX'),
      throwsArgumentError,
    );
    await expectLater(
      api.emails(sourceA, '', 1, filters: const SearchFilters(direction: 'outgoing')),
      throwsArgumentError,
    );
    await expectLater(
      api.emails(sourceA, '', 1, filters: const SearchFilters(sortBy: 'subject')),
      throwsArgumentError,
    );
    await expectLater(api.emails(sourceA, '', 0), throwsArgumentError);
    expect(api.lastPath, isNull);
  });

  test('unsupported features are refused, never improvised', () async {
    final api = RecordingOpenArchiver();
    await expectLater(api.folders(sourceA), throwsUnsupportedError);
    await expectLater(api.stats(), throwsUnsupportedError);
    // Never listed by this backend, so its source is unknown.
    await expectLater(
      api.message(mailA),
      throwsA(isA<ArchiveMessageRefused>()),
    );
    await expectLater(
      api.downloadAttachment(mailA, 'x', File('unused')),
      throwsUnsupportedError,
    );
    expect(api.lastPath, isNull);
  });

  test('malformed list and search responses are rejected', () async {
    final broken = <String, Object?>{
      'items not a list': {'items': 'x', 'total': 1, 'page': 1, 'limit': 25},
      'negative total': {'items': <Object>[], 'total': -1, 'page': 1, 'limit': 25},
      'zero limit': {'items': <Object>[], 'total': 0, 'page': 1, 'limit': 0},
      'subject type': {
        'items': [
          {'id': mailA, 'subject': 5},
        ],
        'total': 1,
        'page': 1,
        'limit': 25,
      },
      'missing id': {
        'items': [
          {'subject': 'x'},
        ],
        'total': 1,
        'page': 1,
        'limit': 25,
      },
    };
    for (final entry in broken.entries) {
      await expectLater(
        RecordingOpenArchiver({
          'archived-emails/ingestion-source/$sourceA': entry.value,
        }).emails(sourceA, '', 1),
        throwsFormatException,
        reason: entry.key,
      );
    }
    for (final bad in [
      {'hits': 'x', 'total': 1},
      {
        'hits': [
          {'id': mailA, 'timestamp': '2026-03-01'},
        ],
        'total': 1,
      },
      {'hits': <Object>[], 'total': 1, 'totalPages': -2},
    ]) {
      await expectLater(
        RecordingOpenArchiver({'search': bad}).emails(sourceA, 'x', 1),
        throwsFormatException,
      );
    }
  });

  test('the session labels exact browse totals and estimated search totals', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = RecordingOpenArchiver();
    final session = ArchiveSession(apiFactory: (_, _) => api);
    addTearDown(session.dispose);
    session.server.text = 'https://archive.example';
    session.keyInput.text = 'test-only';
    await session.connect();
    expect(session.account?.address, 'Alex Rivera mailbox');
    expect(session.folders, isEmpty);
    await session.load(1);
    expect(session.searchFeedback, contains('· 2 matches ·'));
    session.search.text = 'agenda';
    await session.load(1);
    expect(session.searchFeedback, contains('about 51 matches'));
    expect(api.lastPath, 'search');
  });
}
