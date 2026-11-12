import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_capabilities.dart';
import 'package:mailburrow/demo/demo_archive.dart';
import 'package:mailburrow/search_filters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full capabilities cover every control the screens offer', () {
    final full = ArchiveCapabilities.full;
    expect(full.folders, isTrue);
    expect(full.dateRangeFilter, isTrue);
    expect(full.directionFilter, isTrue);
    expect(full.sortFields, searchSortFields.keys.toSet());
    expect(full.sortOrders, searchSortOrders.keys.toSet());
    expect(full.estimatedTotals, isFalse);
    expect(full.archiveStats, isTrue);
    expect(full.allows(const SearchFilters()), isTrue);
    for (final field in searchSortFields.keys) {
      for (final order in searchSortOrders.keys) {
        expect(
          full.allows(
            SearchFilters(
              from: DateTime(2024),
              to: DateTime(2024, 2),
              direction: 'outgoing',
              sortBy: field,
              sortOrder: order,
            ),
          ),
          isTrue,
        );
      }
    }
  });

  test('Mail-Archiver and the demo keep everything they support today', () async {
    final api = ArchiveApi(Uri.parse('https://archive.example'), 'test-only');
    final demo = await DemoArchive.load(latency: Duration.zero);
    addTearDown(api.close);
    addTearDown(demo.close);
    expect(api.capabilities, same(ArchiveCapabilities.full));
    expect(demo.capabilities, same(ArchiveCapabilities.full));
  });

  test('a reduced backend rejects filters it cannot honour', () {
    const reduced = ArchiveCapabilities(
      folders: false,
      dateRangeFilter: true,
      directionFilter: false,
      sortFields: {'sentDate'},
      sortOrders: {'desc', 'asc'},
      estimatedTotals: true,
      archiveStats: false,
    );
    expect(reduced.allows(const SearchFilters()), isTrue);
    expect(
      reduced.allows(SearchFilters(from: DateTime(2024), sortOrder: 'asc')),
      isTrue,
    );
    expect(
      reduced.allows(const SearchFilters(direction: 'incoming')),
      isFalse,
    );
    expect(reduced.allows(const SearchFilters(sortBy: 'subject')), isFalse);
    expect(
      ArchiveCapabilities(
        folders: true,
        dateRangeFilter: false,
        directionFilter: true,
        sortFields: searchSortFields.keys.toSet(),
        sortOrders: searchSortOrders.keys.toSet(),
        estimatedTotals: false,
        archiveStats: true,
      ).allows(SearchFilters(to: DateTime(2024))),
      isFalse,
    );
  });
}
