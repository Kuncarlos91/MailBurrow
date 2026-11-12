import 'search_filters.dart';

/// What one archive backend can do, declared by the backend itself.
///
/// The list is fixed per backend and never detected by probing a server.
/// Screens use it to hide controls the server cannot honour (Phase 2 of the
/// Open Archiver plan); until then every backend reports [full] and nothing
/// changes on screen.
class ArchiveCapabilities {
  const ArchiveCapabilities({
    required this.folders,
    required this.dateRangeFilter,
    required this.directionFilter,
    required this.sortFields,
    required this.sortOrders,
    required this.estimatedTotals,
    required this.archiveStats,
  });

  /// Everything the current screens offer: Mail-Archiver and the demo.
  static final full = ArchiveCapabilities(
    folders: true,
    dateRangeFilter: true,
    directionFilter: true,
    sortFields: searchSortFields.keys.toSet(),
    sortOrders: searchSortOrders.keys.toSet(),
    estimatedTotals: false,
    archiveStats: true,
  );

  /// Accounts have folders to browse.
  final bool folders;

  /// Searches can be limited to a sent-date range.
  final bool dateRangeFilter;

  /// Searches can be limited to incoming or outgoing mail.
  final bool directionFilter;

  /// Accepted [SearchFilters.sortBy] values; a subset of [searchSortFields]
  /// that includes the default, `sentDate`.
  final Set<String> sortFields;

  /// Accepted [SearchFilters.sortOrder] values; a subset of
  /// [searchSortOrders] that includes the default, `desc`.
  final Set<String> sortOrders;

  /// Reported match totals are estimates rather than exact counts.
  final bool estimatedTotals;

  /// `stats()` reports totals limited to what the key can read. A backend
  /// whose server only offers server-wide totals reports false.
  final bool archiveStats;

  /// Whether a search with [filters] uses only what this backend supports.
  bool allows(SearchFilters filters) =>
      (dateRangeFilter || (filters.from == null && filters.to == null)) &&
      (directionFilter || filters.direction.isEmpty) &&
      sortFields.contains(filters.sortBy) &&
      sortOrders.contains(filters.sortOrder);
}
