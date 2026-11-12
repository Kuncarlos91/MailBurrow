import 'dart:io';

import 'archive_models.dart';
import 'attachment_download.dart';
import 'search_filters.dart';

/// A read-only connection to a self-hosted mail archive.
///
/// The app talks to its server only through this interface. `ArchiveApi`
/// implements it for Mail-Archiver, currently the only supported backend.
///
/// Results use Mail-Archiver's JSON shapes, described in the Playbook's API
/// contract. Another backend would adapt its responses to those shapes until
/// typed models and capability flags replace them; see the completion plan's
/// note on other archive backends.
/// Method parameters use opaque text IDs for accounts, messages and attachments.
/// Callers must not parse them as integers. During the result-model transition,
/// numeric IDs in legacy JSON maps are normalized with `archiveId`; adapters
/// own their wire-format constraints (Mail-Archiver requires numeric wire IDs).
///
/// Every implementation must keep MailBurrow's safety rules: HTTPS with
/// certificate validation, no redirects, read-only requests, bounded
/// responses and downloads, and no on-device mail cache.
/// Failures use the shared types in `archive_errors.dart`; implementations
/// must not expose raw server responses or credentials in user-facing errors.
abstract interface class ArchiveBackend {
  /// The validated HTTPS address the user connected to.
  Uri get server;

  /// The credential sent with each request, saved in secure storage.
  String get key;

  /// Mail accounts the key can read.
  Future<List<dynamic>> accounts();

  /// The folders of one account, flattened for display.
  Future<List<ArchiveFolder>> folders(String accountId);

  /// One page of an account's messages matching [query], [folder] and
  /// [filters], newest first unless the filters say otherwise.
  Future<Map<String, dynamic>> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  });

  /// One full message, including bodies and attachment details.
  Future<Map<String, dynamic>> message(String id);

  /// Streams one attachment to [destination], within the app's size and time
  /// limits, only when the user asks for it.
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  });

  /// Archive totals for the accounts the key can read.
  Future<Map<String, dynamic>> stats();

  /// Stops mail list and search requests that are still running; other
  /// requests continue.
  void cancelEmailRequests();

  /// Stops every request and releases the connection.
  void close();
}
