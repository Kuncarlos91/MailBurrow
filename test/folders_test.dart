import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';

void main() {
  test('preserves exact server paths and nested folder counts', () {
    final folders = flattenFolders([
      {
        'name': 'INBOX',
        'fullPath': 'INBOX',
        'totalCount': 10,
        'children': [
          {
            'name': 'R&D / 2026',
            'fullPath': 'INBOX/R&D / 2026',
            'totalCount': 3,
            'children': [],
          },
        ],
      },
    ]);
    expect(folders.map((folder) => folder.path), ['INBOX', 'INBOX/R&D / 2026']);
    expect(folders.map((folder) => folder.depth), [0, 1]);
    expect(folders.last.count, 3);
    final uri = Uri.https('example.com', '/api/v1/emails', {
      'folder': folders.last.path,
    });
    expect(uri.queryParameters['folder'], folders.last.path);
  });
  test('empty folder tree is supported', () {
    expect(flattenFolders([]), isEmpty);
  });
}
