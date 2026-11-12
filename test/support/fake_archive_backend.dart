import 'dart:io';

import 'package:mailburrow/archive_backend.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/attachment_download.dart';
import 'package:mailburrow/search_filters.dart';

/// Test-only backend with no Mail-Archiver transport inheritance.
/// Unexpected calls fail rather than silently invoking a real network client.
class FakeArchiveBackend implements ArchiveBackend {
  FakeArchiveBackend(this.server, this.key);
  @override
  final Uri server;
  @override
  final String key;
  @override
  Future<List<ArchiveAccount>> accounts() => throw UnimplementedError('accounts');
  @override
  Future<List<ArchiveFolder>> folders(String accountId) =>
      throw UnimplementedError('folders');
  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) => throw UnimplementedError('emails');
  @override
  Future<MailMessage> message(String id) =>
      throw UnimplementedError('message');
  @override
  Future<void> downloadAttachment(
    String emailId,
    String attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) => throw UnimplementedError('downloadAttachment');
  @override
  Future<ArchiveStats> stats() => throw UnimplementedError('stats');
  @override
  void cancelEmailRequests() {}
  @override
  void close() {}
}
