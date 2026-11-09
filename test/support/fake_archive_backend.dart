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
  Future<List<dynamic>> accounts() => throw UnimplementedError('accounts');
  @override
  Future<List<ArchiveFolder>> folders(int accountId) =>
      throw UnimplementedError('folders');
  @override
  Future<Map<String, dynamic>> emails(
    int accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) => throw UnimplementedError('emails');
  @override
  Future<Map<String, dynamic>> message(int id) =>
      throw UnimplementedError('message');
  @override
  Future<void> downloadAttachment(
    int emailId,
    int attachmentId,
    File destination, {
    AttachmentDownload? transfer,
    void Function(int receivedBytes)? onProgress,
  }) => throw UnimplementedError('downloadAttachment');
  @override
  Future<Map<String, dynamic>> stats() => throw UnimplementedError('stats');
  @override
  void cancelEmailRequests() {}
  @override
  void close() {}
}
