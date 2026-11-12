/// Typed results shared by every archive backend.
///
/// Screens and the session read only these classes. Each backend converts its
/// own wire format into them; the `fromJson` factories read the JSON shape
/// used by Mail-Archiver and by the built-in demo, which mirrors it. Optional
/// fields a backend does not report stay null, and the screens show them as
/// "not reported" rather than inventing values.
library;

/// Converts a JSON result's ID to the backend's opaque text form.
/// Numeric JSON IDs are accepted because Mail-Archiver uses them.
/// Never stringify null, booleans or containers into an apparent identifier.
String archiveId(Object? value) {
  if (value is int) return value.toString();
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('Invalid archive identifier.');
}

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Invalid $what response');
}

String? _text(Object? value) => value is String ? value : null;

int _count(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! int || value < 0) {
    throw const FormatException('Invalid archive count');
  }
  return value;
}

/// One mail account (or archive source) the key can read.
class ArchiveAccount {
  const ArchiveAccount({
    required this.id,
    this.emailAddress,
    this.lastSync,
    this.archivingEnabled,
  });

  factory ArchiveAccount.fromJson(Object? value) {
    final json = _object(value, 'account');
    final enabled = json['isEnabled'];
    return ArchiveAccount(
      id: archiveId(json['id']),
      emailAddress: _text(json['emailAddress']),
      lastSync: _text(json['lastSync']),
      archivingEnabled: enabled is bool ? enabled : null,
    );
  }

  final String id;
  final String? emailAddress;

  /// The server's last sync time as reported (ISO 8601), or null.
  final String? lastSync;

  /// Whether the server is still archiving this account, or null when the
  /// server does not report it.
  final bool? archivingEnabled;

  /// The address to show, or a neutral label when none was reported.
  String get address {
    final value = emailAddress?.trim() ?? '';
    return value.isEmpty ? 'Email address not reported' : value;
  }
}

/// One message in a mail list or search result. Only the fields the list
/// shows; opening the message fetches the rest.
class MailSummary {
  const MailSummary({
    required this.id,
    this.subject,
    this.from,
    this.sentDate,
    this.hasAttachments = false,
  });

  factory MailSummary.fromJson(Object? value) {
    final json = _object(value, 'message list');
    return MailSummary(
      id: archiveId(json['id']),
      subject: _text(json['subject']),
      from: _text(json['from']),
      sentDate: _text(json['sentDate']),
      hasAttachments: json['hasAttachments'] == true,
    );
  }

  final String id;
  final String? subject, from;

  /// The sent date as reported (ISO 8601); `MessageDate` parses it.
  final String? sentDate;
  final bool hasAttachments;
}

/// One page of a mail list or search.
class MailPage {
  const MailPage({
    required this.items,
    this.page = 1,
    this.totalPages = 1,
    this.totalItems,
  });

  factory MailPage.fromJson(Object? value) {
    final json = _object(value, 'message list');
    final items = json['items'];
    final page = json['page'];
    final pages = json['totalPages'];
    final total = json['totalItems'];
    if (items is! List<dynamic> ||
        (page != null && page is! int) ||
        pages is! int ||
        (total != null && (total is! int || total < 0))) {
      throw const FormatException('Invalid message list response');
    }
    return MailPage(
      items: [for (final item in items) MailSummary.fromJson(item)],
      page: page as int? ?? 1,
      totalPages: pages,
      totalItems: total as int?,
    );
  }

  final List<MailSummary> items;
  final int page;

  /// As reported; the session clamps it for paging.
  final int totalPages;

  /// Total matches, or null when the server does not report them.
  final int? totalItems;
}

/// Metadata for one attachment of an open message.
class MailAttachment {
  const MailAttachment(
    this.id,
    this.name,
    this.size, [
    this.contentType = 'application/octet-stream',
  ]);
  factory MailAttachment.fromJson(Map<String, dynamic> value) => MailAttachment(
    archiveId(value['id']),
    value['fileName'] as String? ?? 'attachment',
    (value['size'] as num?)?.toInt() ?? 0,
    value['contentType'] as String? ?? 'application/octet-stream',
  );
  final String id;
  final int size;
  final String name;
  final String contentType;
}

/// One full message: headers, bodies and attachment details. It carries no
/// ID of its own: callers already hold the ID they asked for.
class MailMessage {
  const MailMessage({
    this.subject,
    this.from,
    this.sentDate,
    this.folderName,
    this.htmlBody = '',
    this.textBody = '',
    this.attachments = const [],
  });

  factory MailMessage.fromJson(Object? value) {
    final json = _object(value, 'message');
    final attachments = json['attachments'];
    if (attachments != null && attachments is! List<dynamic>) {
      throw const FormatException('Invalid message response');
    }
    return MailMessage(
      subject: _text(json['subject']),
      from: _text(json['from']),
      sentDate: _text(json['sentDate']),
      folderName: _text(json['folderName']),
      htmlBody: _text(json['htmlBody']) ?? '',
      textBody: _text(json['textBody']) ?? '',
      attachments: [
        for (final file in attachments as List<dynamic>? ?? const [])
          MailAttachment.fromJson(_object(file, 'attachment')),
      ],
    );
  }

  final String? subject, from;
  final String? sentDate, folderName;
  final String htmlBody, textBody;
  final List<MailAttachment> attachments;
}

/// Archive totals for the accounts the key can read.
class ArchiveStats {
  const ArchiveStats(this.emails, this.accounts, this.attachments);
  final int emails, accounts, attachments;
  factory ArchiveStats.fromJson(Object? value) {
    final json = _object(value, 'archive statistics');
    return ArchiveStats(
      _count(json, 'emails'),
      _count(json, 'accounts'),
      _count(json, 'attachments'),
    );
  }
}

/// Shared folder metadata supplied by an archive backend.
class ArchiveFolder {
  const ArchiveFolder(this.name, this.path, this.count, this.depth);
  final String name, path;
  final int count, depth;
}
