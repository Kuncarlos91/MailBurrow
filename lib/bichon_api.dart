import 'dart:io';

import 'archive_api.dart';
import 'archive_capabilities.dart';
import 'attachment_download.dart';
import 'message_load.dart';
import 'search_filters.dart';

/// Results per page, matching the other backends.
const bichonPageSize = 25;

/// Time to read a message's parsed content after its headers.
const bichonMessageReadTimeout = Duration(seconds: 60);

/// The Bichon version MailBurrow is tested with, named in the message shown
/// when a response does not match the tested contract.
const bichonTestedVersion = '2.4.2';

/// Longest search text, in Unicode code points, counted before escaping.
const bichonMaxSearchLength = 256;

/// What Bichon 2.4.2 Community supports through MailBurrow: accounts have
/// folders (Bichon mailboxes), search filters by sent date and sorts by date
/// only, totals are exact, and server totals are not requested.
final bichonCapabilities = ArchiveCapabilities(
  folders: true,
  folderCounts: false,
  dateRangeFilter: true,
  directionFilter: false,
  sortFields: {'sentDate'},
  sortOrders: {'desc', 'asc'},
  estimatedTotals: false,
  archiveStats: false,
);

/// Characters Bichon's query parser (Tantivy) treats as syntax.
const _querySyntax = r'+-&|!(){}[]^"~*?:\/';
final _standaloneOperator = RegExp(r'\b(?:AND|OR|NOT)\b');

/// [text] as a literal Bichon search: query-syntax characters are
/// backslash-escaped and standalone `AND`, `OR` and `NOT` are lowercased, so
/// they search as words instead of operators. Matches the encoding checked
/// on the lab (tools/bichon_lab_check.py, `literal_query`).
String bichonLiteralSearch(String text) {
  final words = text.replaceAllMapped(
    _standaloneOperator,
    (match) => match[0]!.toLowerCase(),
  );
  final out = StringBuffer();
  for (final rune in words.runes) {
    final char = String.fromCharCode(rune);
    if (_querySyntax.contains(char)) out.write(r'\');
    out.write(char);
  }
  return out.toString();
}

// Account and mailbox IDs are positive 64-bit integers; envelope IDs are
// UUID text; attachments are identified by their content hash. Validate
// before building any URL path, so an ID can never add path segments.
final _numericId = RegExp(r'^[1-9][0-9]{0,18}$');
final _envelopeId = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final _contentHash = RegExp(r'^[A-Za-z0-9]{1,128}$');

int _accountId(String id) {
  final value = _numericId.hasMatch(id) ? int.tryParse(id) : null;
  if (value == null) throw const FormatException('Invalid Bichon account.');
  return value;
}

/// The app's message ID: `<account ID>:<envelope ID>`.
({int account, String envelope}) _messageId(String id) {
  final parts = id.split(':');
  if (parts.length != 2 || !_envelopeId.hasMatch(parts[1])) {
    throw const FormatException('Invalid Bichon message.');
  }
  return (account: _accountId(parts[0]), envelope: parts[1]);
}

String _hash(String id) {
  if (!_contentHash.hasMatch(id)) {
    throw const FormatException('Invalid Bichon attachment.');
  }
  return id;
}

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Invalid Bichon $what response');
}

String? _text(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null || value is String) return value as String?;
  throw FormatException('Invalid Bichon $field');
}

int _positive(Object? value, String what) {
  if (value is int && value > 0) return value;
  throw FormatException('Invalid Bichon $what');
}

int _count(Object? value, String what) {
  if (value is int && value >= 0) return value;
  throw FormatException('Invalid Bichon $what');
}

String? _sender(String? name, String? address) {
  final label = name?.trim() ?? '';
  final email = address?.trim() ?? '';
  if (label.isEmpty) return email.isEmpty ? null : email;
  return email.isEmpty ? label : '$label <$email>';
}

/// Bichon dates are milliseconds since the epoch. Mail imported without a
/// date is stored as 0, which means "not reported", not January 1970.
String? _date(Object? value) {
  if (value == null) return null;
  if (value is! int || value < -8640000000000000 || value > 8640000000000000) {
    throw const FormatException('Invalid Bichon date');
  }
  if (value == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    value,
    isUtc: true,
  ).toIso8601String();
}

/// The Bichon implementation of [ArchiveBackend] for 2.4.2 Community, using
/// its API under `/api/v1/` with a bearer token for a read-only user.
///
/// Requests: the account list from
/// `minimal-account-list` (never `accounts` or `current-user`), mailboxes
/// from `list-mailboxes` without `remote`, mail lists and searches through
/// the read-only `search-messages` POST with literal search text, messages
/// as parsed content with remote content blocked (never raw EML), and
/// attachments by content hash only when the user saves one.
class BichonApi extends ArchiveApi {
  BichonApi(
    super.server,
    super.key, {
    super.attachmentByteLimit,
    super.attachmentDeadline,
    super.attachmentIdleTimeout,
    super.responseTimeout,
  });

  @override
  ArchiveCapabilities get capabilities => bichonCapabilities;

  // Mailbox IDs by account and folder path, from the last folders() call.
  final _mailboxes = <String, Map<String, int>>{};

  // Stated attachment sizes by message and content hash, from opened
  // messages, so a saved file must match its stated size.
  final _attachmentSizes = <String, int>{};

  /// Runs [body], reporting a response that does not match the tested
  /// contract as [ArchiveUnsupportedResponse]. Arguments are validated
  /// before it, so their errors keep their own types.
  Future<T> _contract<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on FormatException {
      throw const ArchiveUnsupportedResponse('Bichon', bichonTestedVersion);
    } on TypeError {
      throw const ArchiveUnsupportedResponse('Bichon', bichonTestedVersion);
    }
  }

  @override
  bool isMailRequest(String path) => path == 'search-messages';

  @override
  String get credentialName => 'access token';

  @override
  bool allowsPost(String path) => path == 'search-messages';

  @override
  Future<List<ArchiveAccount>> accounts() => _contract(() async {
    final result = await get('minimal-account-list');
    if (result is! List<dynamic>) {
      throw const FormatException('Invalid Bichon account response');
    }
    return [
      for (final item in result)
        () {
          final json = _object(item, 'account');
          final email = json['email'];
          final name = json['name'];
          return ArchiveAccount(
            id: _positive(json['id'], 'account').toString(),
            emailAddress: email is String ? email : null,
            name: name is String ? name : null,
          );
        }(),
    ];
  });

  @override
  Future<List<ArchiveFolder>> folders(String id) async {
    final account = _accountId(id);
    return _contract(() async {
      final json = _object(
        await get('list-mailboxes/$account'),
        'mailbox list',
      );
      final status = json['status'];
      final mailboxes = json['mailboxes'];
      if (status == 'fetching' || status == 'error') {
        throw ArchiveFoldersUnavailable(loading: status == 'fetching');
      }
      if (status != 'ready' || mailboxes is! List) {
        throw const FormatException('Invalid Bichon mailbox list');
      }
      final ids = <String, int>{};
      final folders = <ArchiveFolder>[];
      for (final item in mailboxes) {
        final mailbox = _object(item, 'mailbox');
        final id = _positive(mailbox['id'], 'mailbox');
        final path = _text(mailbox, 'name');
        final delimiter = _text(mailbox, 'delimiter') ?? '';
        if (mailbox['account_id'] != account ||
            path == null ||
            path.isEmpty ||
            ids.containsKey(path)) {
          throw const FormatException('Invalid Bichon mailbox');
        }
        ids[path] = id;
        final parts = delimiter.isEmpty ? [path] : path.split(delimiter);
        folders.add(
          ArchiveFolder(
            parts.last.isEmpty ? path : parts.last,
            path,
            _count(mailbox['exists'], 'mailbox count'),
            parts.length - 1,
          ),
        );
      }
      folders.sort((a, b) => a.path.compareTo(b.path));
      _mailboxes[id] = ids;
      return folders;
    });
  }

  @override
  Future<ArchiveStats> stats() async =>
      throw UnsupportedError('Bichon totals are not requested.');

  @override
  Future<MailPage> emails(
    String id,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async {
    final account = _accountId(id);
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (!capabilities.allows(filters)) {
      throw ArgumentError('Unsupported Bichon search filters');
    }
    final text = query.trim();
    if (text.runes.length > bichonMaxSearchLength) {
      throw const ArchiveSearchRefused(
        'Search text is too long. Use at most $bichonMaxSearchLength characters.',
      );
    }
    int? mailbox;
    if (folder != null && folder.isNotEmpty) {
      mailbox = _mailboxes[id]?[folder];
      if (mailbox == null) {
        throw const FormatException('Unknown Bichon folder');
      }
    }
    final from = filters.from, to = filters.to;
    return _contract(() async {
      final result = _object(
        await postJson('search-messages', {
          'filter': {
            'account_ids': [account],
            'mailbox_ids': ?(mailbox == null ? null : [mailbox]),
            'text': ?(text.isEmpty ? null : bichonLiteralSearch(text)),
            'since': ?(from == null
                ? null
                : DateTime.utc(
                    from.year,
                    from.month,
                    from.day,
                  ).millisecondsSinceEpoch),
            'before': ?(to == null
                ? null
                : DateTime.utc(
                        to.year,
                        to.month,
                        to.day + 1,
                      ).millisecondsSinceEpoch -
                      1),
          },
          'page': page,
          'page_size': bichonPageSize,
          'sort_by': 'DATE',
          'desc': filters.sortOrder != 'asc',
        }),
        'search',
      );
      final items = result['items'];
      final total = _count(result['total_items'], 'total');
      final pages = result['total_pages'];
      if (items is! List || items.length > bichonPageSize) {
        throw const FormatException('Invalid Bichon search response');
      }
      if (pages != null && (pages is! int || pages < 0)) {
        throw const FormatException('Invalid Bichon page count');
      }
      return MailPage(
        items: [for (final item in items) _summary(item, account, mailbox)],
        page: page,
        totalPages:
            pages as int? ?? (total + bichonPageSize - 1) ~/ bichonPageSize,
        totalItems: total,
        totalIsEstimate: false,
      );
    });
  }

  MailSummary _summary(Object? value, int account, int? mailbox) {
    final json = _object(value, 'message list');
    final id = json['id'];
    if (id is! String ||
        !_envelopeId.hasMatch(id) ||
        json['account_id'] != account ||
        (mailbox != null && json['mailbox_id'] != mailbox)) {
      throw const FormatException('Invalid Bichon message list');
    }
    final regular = json['regular_attachment_count'];
    return MailSummary(
      id: '$account:$id',
      subject: _text(json, 'subject'),
      from: _sender(_text(json, 'from_name'), _text(json, 'from')),
      sentDate: _date(json['date']),
      hasAttachments:
          _count(regular ?? json['attachment_count'], 'attachment count') > 0,
    );
  }

  @override
  Future<MailMessage> message(String id) async {
    final message = _messageId(id);
    return _contract(() async {
      final path =
          '${message.account}/${Uri.encodeComponent(message.envelope)}';
      final envelope = _object(await get('envelope/$path'), 'message');
      MessageLoad.current?.throwIfCancelled();
      if (envelope['id'] != message.envelope ||
          envelope['account_id'] != message.account) {
        throw const FormatException('Invalid Bichon message');
      }
      final content = _object(
        await send(
          'message-content/$path',
          {'block_remote_content': 'true'},
          (body, length) => decodeArchiveJson(body, contentLength: length),
          timeout: bichonMessageReadTimeout,
        ),
        'message content',
      );
      MessageLoad.current?.throwIfCancelled();
      final attachments = content['attachments'];
      if (attachments != null && attachments is! List) {
        throw const FormatException('Invalid Bichon attachments');
      }
      final files = <MailAttachment>[];
      for (final item in attachments as List? ?? const []) {
        final file = _object(item, 'attachment');
        final inline = file['inline'];
        if (inline is! bool) throw const FormatException('Invalid attachment');
        // Inline parts are rendered through cid: references, which the app
        // does not display; they are neither listed nor downloaded.
        if (inline) continue;
        final hash = file['content_hash'];
        if (hash is! String) throw const FormatException('Invalid attachment');
        final size = _count(file['size'], 'attachment size');
        final name = _text(file, 'filename')?.trim() ?? '';
        _hash(hash);
        files.add(
          MailAttachment(
            hash,
            name.isEmpty ? 'attachment' : name,
            size,
            _text(file, 'file_type') ?? 'application/octet-stream',
          ),
        );
      }
      final result = MailMessage(
        subject: _text(envelope, 'subject'),
        from: _sender(_text(envelope, 'from_name'), _text(envelope, 'from')),
        sentDate: _date(envelope['date']),
        folderName: _text(envelope, 'mailbox_name'),
        htmlBody: _text(content, 'html') ?? '',
        textBody: _text(content, 'text') ?? '',
        attachments: files,
      );
      // Publish handles only after all message fields validate and the reader
      // remains active. Reopening replaces this message's previous handles.
      MessageLoad.current?.throwIfCancelled();
      _attachmentSizes.removeWhere((key, _) => key.startsWith('$id/'));
      if (_attachmentSizes.length > 2000) _attachmentSizes.clear();
      for (final file in files) {
        _attachmentSizes['$id/${file.id}'] = file.size;
      }
      return result;
    });
  }

  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) async {
    final message = _messageId(emailId);
    final hash = _hash(attachmentId);
    final expected = _attachmentSizes['$emailId/$hash'];
    if (expected == null) {
      throw const ArchiveMessageRefused(
        'Open the message again to save this attachment.',
      );
    }
    await downloadTo(
      server.replace(
        path:
            '${server.path}/api/v1/download-attachment/${message.account}/'
            '${Uri.encodeComponent(message.envelope)}',
        queryParameters: {'content_hash': hash},
      ),
      destination,
      transfer: transfer,
      onProgress: onProgress,
      expectedBytes: expected,
    );
  }
}
