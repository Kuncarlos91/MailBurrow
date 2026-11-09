import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/search_filters.dart';

void main() {
  test('default filters keep documented sorting and omit optional values', () {
    const filters = SearchFilters();
    expect(filters.active, isFalse);
    expect(filters.parameters, {'sortBy': 'sentDate', 'sortOrder': 'desc'});
  });
  test(
    'date selections produce date-only parameters without timezone conversion',
    () {
      final filters = SearchFilters(
        from: DateTime(2025, 9, 1),
        to: DateTime(2025, 9, 30),
        direction: 'incoming',
        sortBy: 'subject',
        sortOrder: 'asc',
      );
      expect(filters.parameters, {
        'from': '2025-09-01',
        'to': '2025-09-30',
        'direction': 'incoming',
        'sortBy': 'subject',
        'sortOrder': 'asc',
      });
      expect(filters.active, isTrue);
      expect(filters.validationError, isNull);
    },
  );
  test('reversed ranges are rejected and same-day ranges accepted', () {
    expect(
      SearchFilters(
        from: DateTime(2025, 2, 2),
        to: DateTime(2025, 2, 1),
      ).validationError,
      isNotNull,
    );
    expect(
      SearchFilters(
        from: DateTime(2025, 2, 1),
        to: DateTime(2025, 2, 1),
      ).validationError,
      isNull,
    );
  });
}
