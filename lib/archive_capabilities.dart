import 'search_filters.dart';

/// What one archive backend can do, declared by the backend itself.
///
/// The list is fixed per backend and never detected by probing a server.
/// Screens use it to hide controls the server cannot honour: the folder
/// picker, filter and sort choices, archive totals in Settings, and exact
/// match counts. Mail-Archiver and the demo report [full].
class ArchiveCapabilities {
  ArchiveCapabilities({
    required this.folders,
    required this.dateRangeFilter,
    required this.directionFilter,
    required Set<String> sortFields,
    required Set<String> sortOrders,
    required this.estimatedTotals,
    required this.archiveStats,
  }) : sortFields = Set.unmodifiable(sortFields),
       sortOrders = Set.unmodifiable(sortOrders) {
    if (!this.sortFields.contains('sentDate') ||
        !this.sortFields.every(searchSortFields.containsKey)) {
      throw ArgumentError('Sort fields must be known and include sentDate.');
    }
    if (!this.sortOrders.contains('desc') ||
        !this.sortOrders.every(searchSortOrders.containsKey)) {
      throw ArgumentError('Sort orders must be known and include desc.');
    }
  }

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

  /// Whether [filters] are valid and use only what this backend supports.
  bool allows(SearchFilters filters) =>
      filters.validationError == null &&
      searchDirections.containsKey(filters.direction) &&
      (dateRangeFilter || (filters.from == null && filters.to == null)) &&
      (directionFilter || filters.direction.isEmpty) &&
      sortFields.contains(filters.sortBy) &&
      sortOrders.contains(filters.sortOrder);

  /// [filters] with every unsupported choice returned to its default. Used
  /// when filters are applied, so a backend never receives an option it
  /// cannot honour.
  SearchFilters supported(SearchFilters filters) => SearchFilters(
    from: dateRangeFilter ? filters.from : null,
    to: dateRangeFilter ? filters.to : null,
    direction:
        directionFilter && searchDirections.containsKey(filters.direction)
        ? filters.direction
        : '',
    sortBy: sortFields.contains(filters.sortBy) ? filters.sortBy : 'sentDate',
    sortOrder: sortOrders.contains(filters.sortOrder)
        ? filters.sortOrder
        : 'desc',
  );
}
