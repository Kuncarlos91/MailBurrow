import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'archive_api.dart';
import 'archive_capabilities.dart';
import 'attachment_download.dart';
import 'mime_bodies.dart';
import 'open_archiver_detail.dart';
import 'search_filters.dart';

/// Results per page, matching Mail-Archiver's page size.
const openArchiverPageSize = 25;

/// Approved phone budgets for opening a message (plan, November 12, 2026):
/// the response on the wire, the decoded `.eml`, and all other JSON text.
const openArchiverMaxMessageWireBytes = 40 * 1024 * 1024;
const openArchiverMaxRawBytes = 10 * 1024 * 1024;
const openArchiverMaxDetailFieldBytes = 4 * 1024 * 1024;

/// Time to read a message response after its headers, and to read its MIME
/// structure afterwards.
const openArchiverMessageReadTimeout = Duration(seconds: 60);
const openArchiverMimeTimeout = Duration(seconds: 5);

/// Message IDs remembered from lists and searches, to know each message's
/// source before opening it.
const _rememberedMessages = 2000;

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
/// with the decoded response. Messages open within the approved phone
/// budgets (see [message]), and their attachments save through the
/// storage route (see [downloadAttachment]).
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

  // Preserve-original policy per source, from the last accounts() call.
  // A source with a missing or malformed flag has no entry.
  final _sourcePolicy = <String, bool>{};

  // Which source each listed message came from.
  final _messageSource = <String, String>{};

  // Attachments listed by opened messages: their message, storage path and
  // stated size, for saving them.
  final _attachments =
      <String, ({String emailId, String storagePath, int size})>{};

  /// The storage path of an attachment listed by an opened message; null
  /// when unknown.
  String? attachmentStoragePath(String attachmentId) =>
      _attachments[attachmentId]?.storagePath;

  void _remember(String source, Iterable<MailSummary> items) {
    if (_messageSource.length > _rememberedMessages) _messageSource.clear();
    for (final item in items) {
      _messageSource[item.id] = source;
    }
  }

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
    final accounts = [for (final item in result) openArchiverSource(item)];
    _sourcePolicy.clear();
    for (var i = 0; i < accounts.length; i++) {
      try {
        _sourcePolicy[accounts[i].id] = openArchiverPreservesOriginals(
          result[i],
        );
      } on FormatException {
        // Unknown policy: messages from this source are not opened.
      }
    }
    return accounts;
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
      final result = openArchiverListPage(
        await get('archived-emails/ingestion-source/$source', {
          'page': '$page',
          'limit': '$openArchiverPageSize',
        }),
      );
      _remember(source, result.items);
      return result;
    }
    final result = openArchiverSearchPage(
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
    _remember(source, result.items);
    return result;
  }

  /// Opens a message from a source whose policy allows it.
  ///
  /// Sources that keep full original files carry their attachments inside
  /// `raw`, so fetching it would download attachments without the user's
  /// confirmation. They are refused before any request, as are messages
  /// whose source or policy is unknown.
  @override
  Future<MailMessage> message(String id) async {
    final messageId = _openArchiverId(id);
    final source = _messageSource[messageId];
    if (source == null) {
      throw const ArchiveMessageRefused(
        'Open this message from its mail list.',
      );
    }
    var preserves = _sourcePolicy[source];
    if (preserves == null) {
      await accounts();
      preserves = _sourcePolicy[source];
    }
    if (preserves == null) {
      throw const ArchiveMessageRefused(
        'Open Archiver did not say whether this source keeps full original '
        'messages, so MailBurrow will not open its mail.',
      );
    }
    if (preserves) {
      throw const ArchiveMessageRefused(
        'This source keeps full original messages, attachments included, '
        'so MailBurrow does not open them. Use the Open Archiver website '
        'for this source.',
      );
    }
    final detail = await send(
      'archived-emails/$messageId',
      null,
      readOpenArchiverDetail,
      timeout: openArchiverMessageReadTimeout,
    );
    final fields = detail.fields;
    final listed = fields['ingestionSourceId'];
    if (listed != null && listed != source) {
      throw const FormatException('Message source does not match');
    }
    final bodies = await _readBodies(
      detail.raw,
    ).timeout(openArchiverMimeTimeout);
    final attachments = openArchiverAttachments(fields['attachments']);
    if (_attachments.length > _rememberedMessages) _attachments.clear();
    for (final file in attachments) {
      _attachments[file.attachment.id] = (
        emailId: messageId,
        storagePath: file.storagePath,
        size: file.attachment.size,
      );
    }
    return MailMessage(
      subject: _text(fields, 'subject'),
      from: _sender(_text(fields, 'senderName'), _text(fields, 'senderEmail')),
      sentDate: _text(fields, 'sentAt'),
      folderName: _text(fields, 'path'),
      htmlBody: bodies.html,
      textBody: bodies.text,
      attachments: [for (final file in attachments) file.attachment],
    );
  }

  /// Saves an attachment listed by a message this backend opened, through
  /// `GET /storage/download?path=<storagePath>`.
  ///
  /// That route streams without a `Content-Length`, so the size stated in
  /// the message's attachment record is enforced instead: above the
  /// attachment limit it is refused before any request, and the download
  /// must match it exactly or the partial file is deleted.
  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) async {
    final messageId = _openArchiverId(emailId);
    final fileId = _openArchiverId(attachmentId);
    final known = _attachments[fileId];
    if (known == null || known.emailId != messageId) {
      throw const ArchiveMessageRefused(
        'Open the message again to save this attachment.',
      );
    }
    await downloadTo(
      server.replace(
        path: '${server.path}/api/v1/storage/download',
        queryParameters: {'path': known.storagePath},
      ),
      destination,
      transfer: transfer,
      onProgress: onProgress,
      expectedBytes: known.size,
    );
  }
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
/// Missing or malformed policy is unknown, never permission to fetch raw mail.
bool openArchiverPreservesOriginals(Object? value) {
  final flag = _object(value, 'source')['preserveOriginalFile'];
  if (flag is! bool) {
    throw const FormatException('Invalid preserve-original flag');
  }
  return flag;
}

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
  if (stamp is int) {
    // Preserve the seconds/milliseconds compatibility heuristic for either
    // sign. Negative Unix timestamps represent valid pre-1970 messages.
    final millis = stamp > 100000000000 || stamp < -100000000000
        ? stamp
        : stamp * 1000;
    // Check before DateTime construction so malformed values remain safe
    // format failures rather than escaping as RangeError.
    const maxDateMillis = 8640000000000000;
    if (millis < -maxDateMillis || millis > maxDateMillis) {
      throw const FormatException('Invalid timestamp');
    }
    sent = DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    ).toIso8601String();
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

/// Reads a message response within the approved budgets: the wire size from
/// `Content-Length` and while streaming, and the decoded message and other
/// fields inside [OpenArchiverDetailReader].
Future<({Map<String, dynamic> fields, Uint8List raw})> readOpenArchiverDetail(
  Stream<List<int>> body,
  int contentLength,
) async {
  if (contentLength > openArchiverMaxMessageWireBytes) {
    throw const ArchiveResponseTooLarge();
  }
  final reader = OpenArchiverDetailReader(
    maxRawBytes: openArchiverMaxRawBytes,
    maxOtherBytes: openArchiverMaxDetailFieldBytes,
  );
  var wire = 0;
  await for (final chunk in body) {
    if (chunk.length > openArchiverMaxMessageWireBytes - wire) {
      throw const ArchiveResponseTooLarge();
    }
    wire += chunk.length;
    reader.add(chunk);
  }
  return reader.close();
}

// Top level, so the isolate closure captures only the bytes.
Future<MimeBodies> _readBodies(Uint8List raw) =>
    Isolate.run(() => readMimeBodies(raw));

/// The detail response's attachment records: `id`, `filename`, `mimeType`,
/// `sizeBytes` and `storagePath`.
List<({MailAttachment attachment, String storagePath})> openArchiverAttachments(
  Object? value,
) {
  if (value == null) return const [];
  if (value is! List<dynamic>) {
    throw const FormatException('Invalid attachments');
  }
  return [
    for (final item in value)
      () {
        final json = _object(item, 'attachment');
        final size = json['sizeBytes'];
        final path = json['storagePath'];
        if (size is! int ||
            size < 0 ||
            path is! String ||
            path.isEmpty ||
            path.length > 1024 ||
            path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
          throw const FormatException('Invalid attachment');
        }
        return (
          attachment: MailAttachment(
            archiveId(json['id']),
            _text(json, 'filename') ?? 'attachment',
            size,
            _text(json, 'mimeType') ?? 'application/octet-stream',
          ),
          storagePath: path,
        );
      }(),
  ];
}
