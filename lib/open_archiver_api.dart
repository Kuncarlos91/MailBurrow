import 'dart:io';

import 'archive_api.dart';
import 'archive_capabilities.dart';
import 'attachment_download.dart';
import 'search_filters.dart';

/// Results per page, matching Mail-Archiver's page size.
const openArchiverPageSize = 25;

/// What Open Archiver v0.6.2 supports through MailBurrow: sources have no
/// folders, search filters by sent date and sorts by date only, search
/// totals are Meilisearch estimates, and its dashboard totals cover the
/// whole server rather than the key, so they are never requested.
final openArchiverCapabilities = ArchiveCapabilities(
  folders: false,
  dateRangeFilter: true,
  directionFilter: false,
  sortFields: {'sentDate'},
  sortOrders: {'desc', 'asc'},
  estimatedTotals: true,
  archiveStats: false,
);

// Open Archiver IDs are UUID text. Validate before building any URL path,
// so an ID can never add path segments or a query.
final _openArchiverIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

String _openArchiverId(String id) {
  if (!_openArchiverIdPattern.hasMatch(id)) {
    throw const FormatException('Invalid Open Archiver identifier.');
  }
  return id;
}

/// The Open Archiver implementation of [ArchiveBackend] for v0.6.2, using
/// its API under `/api/v1/` with an `X-API-KEY` header.
///
/// Sources become accounts. A plain newest-first listing uses the source
/// browse route (exact totals); searches, date filters and oldest-first
/// order use the search route limited to that source (estimated totals).
/// Search hits carry whole index documents, including extracted attachment
/// text: only the fields the list shows are kept, and the rest is dropped
/// with the decoded response. Opening messages and saving attachments come
/// in later Phase 3 steps.
class OpenArchiverApi extends ArchiveApi {
  OpenArchiverApi(
    super.server,
    super.key, {
    super.attachmentByteLimit,
    super.attachmentDeadline,
    super.attachmentIdleTimeout,
    super.responseTimeout,
  });

  @override
  ArchiveCapabilities get capabilities => openArchiverCapabilities;

  @override
  void authorize(HttpClientRequest request) =>
      request.headers.set('X-API-KEY', key);

  @override
  bool isMailRequest(String path) =>
      path == 'search' || path.startsWith('archived-emails/ingestion-source/');

  @override
  Future<List<ArchiveAccount>> accounts() async {
    final result = await get('ingestion-sources');
    if (result is! List<dynamic>) {
      throw const FormatException('Invalid source response');
    }
    return [for (final item in result) openArchiverSource(item)];
  }

  @override
  Future<List<ArchiveFolder>> folders(String id) async =>
      throw UnsupportedError('Open Archiver sources have no folders.');

  @override
  Future<ArchiveStats> stats() async =>
      throw UnsupportedError('Open Archiver totals are server-wide.');

  @override
  Future<MailPage> emails(
    String id,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    final source = _openArchiverId(id);
    if (folder != null) {
      throw ArgumentError.value(folder, 'folder', 'Open Archiver has no folders');
    }
    if (!capabilities.allows(filters)) {
      throw ArgumentError.value(filters, 'filters', 'Unsupported filters');
    }
    if (page < 1) throw ArgumentError.value(page, 'page');
    final browse =
        query.trim().isEmpty &&
        filters.from == null &&
        filters.to == null &&
        filters.sortOrder == 'desc';
    if (browse) {
      return openArchiverListPage(
        await get('archived-emails/ingestion-source/$source', {
          'page': '$page',
          'limit': '$openArchiverPageSize',
        }),
      );
    }
    return openArchiverSearchPage(
      await get('search', {
        'keywords': query.trim(),
        'sources': source,
        'page': '$page',
        'limit': '$openArchiverPageSize',
        'sort': filters.sortOrder == 'asc' ? 'date_asc' : 'date_desc',
        if (filters.from != null) 'dateFrom': dateLabel(filters.from!),
        if (filters.to != null) 'dateTo': dateLabel(filters.to!),
      }),
    );
  }

  @override
  Future<MailMessage> message(String id) async =>
      throw UnsupportedError('Opening Open Archiver messages comes in 3b.');

  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) async => throw UnsupportedError('Open Archiver attachments come in 3c.');
}

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Invalid $what response');
}

String? _text(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('Invalid $field');
}

int _count(Map<String, dynamic> json, String field, {int? fallback}) {
  final value = json[field] ?? fallback;
  if (value is int && value >= 0) return value;
  throw FormatException('Invalid $field');
}

/// One ingestion source as an account. Sources have a name, not an address.
ArchiveAccount openArchiverSource(Object? value) {
  final json = _object(value, 'source');
  final name = json['name'];
  return ArchiveAccount(
    id: archiveId(json['id']),
    name: name is String ? name : null,
  );
}

/// Whether a source keeps full original messages, attachments included.
/// Such sources cannot be opened within the download contract (Phase 3b).
bool openArchiverPreservesOriginals(Object? value) =>
    _object(value, 'source')['preserveOriginalFile'] == true;

String? _sender(String? name, String? address) {
  final label = name?.trim() ?? '';
  final email = address?.trim() ?? '';
  if (label.isEmpty) return email.isEmpty ? null : email;
  return email.isEmpty ? label : '$label <$email>';
}

/// A browse-route item: `senderName`, `senderEmail`, ISO `sentAt`.
MailSummary openArchiverListItem(Object? value) {
  final json = _object(value, 'message list');
  return MailSummary(
    id: archiveId(json['id']),
    subject: _text(json, 'subject'),
    from: _sender(_text(json, 'senderName'), _text(json, 'senderEmail')),
    sentDate: _text(json, 'sentAt'),
    hasAttachments: json['hasAttachments'] == true,
  );
}

/// A search hit: `fromName`, `from`, and `timestamp` in seconds or
/// milliseconds. Body text, attachment text and highlighted copies in the
/// hit are deliberately not read.
MailSummary openArchiverSearchHit(Object? value) {
  final json = _object(value, 'search');
  final stamp = json['timestamp'];
  String? sent;
  if (stamp is int && stamp >= 0) {
    final millis = stamp > 100000000000 ? stamp : stamp * 1000;
    sent = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
        .toIso8601String();
  } else if (stamp != null) {
    throw const FormatException('Invalid timestamp');
  }
  return MailSummary(
    id: archiveId(json['id']),
    subject: _text(json, 'subject'),
    from: _sender(_text(json, 'fromName'), _text(json, 'from')),
    sentDate: sent,
    hasAttachments: json['hasAttachments'] == true,
  );
}

int _pages(int total, int limit) =>
    total == 0 ? 0 : (total + limit - 1) ~/ limit;

/// The browse route's `items`, `total`, `page` and `limit`. Totals are exact.
MailPage openArchiverListPage(Object? value) {
  final json = _object(value, 'message list');
  final items = json['items'];
  if (items is! List<dynamic>) {
    throw const FormatException('Invalid message list response');
  }
  final total = _count(json, 'total');
  final limit = _count(json, 'limit', fallback: openArchiverPageSize);
  final page = _count(json, 'page', fallback: 1);
  if (limit < 1 || page < 1) throw const FormatException('Invalid paging');
  return MailPage(
    items: [for (final item in items) openArchiverListItem(item)],
    page: page,
    totalPages: _pages(total, limit),
    totalItems: total,
    totalIsEstimate: false,
  );
}

/// The search route's `hits`, `total`, `page`, `limit` and, when present,
/// `totalPages`. Totals are estimates.
MailPage openArchiverSearchPage(Object? value) {
  final json = _object(value, 'search');
  final hits = json['hits'];
  if (hits is! List<dynamic>) {
    throw const FormatException('Invalid search response');
  }
  final total = _count(json, 'total');
  final limit = _count(json, 'limit', fallback: openArchiverPageSize);
  final page = _count(json, 'page', fallback: 1);
  if (limit < 1 || page < 1) throw const FormatException('Invalid paging');
  final reported = json['totalPages'];
  if (reported != null && (reported is! int || reported < 0)) {
    throw const FormatException('Invalid totalPages');
  }
  return MailPage(
    items: [for (final hit in hits) openArchiverSearchHit(hit)],
    page: page,
    totalPages: reported as int? ?? _pages(total, limit),
    totalItems: total,
    totalIsEstimate: true,
  );
}
