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
  Map<String, dynamic> folder(int i, {List<dynamic>? children}) => {
    'name': 'Folder $i',
    'fullPath': 'path/$i',
    'totalCount': i,
    'children': ?children,
  };
  List<dynamic> chain(int length) {
    List<dynamic> nodes = [];
    for (var i = length - 1; i >= 0; i--) {
      nodes = [folder(i, children: nodes)];
    }
    return nodes;
  }

  test('accepts exact count and depth limits and preserves preorder', () {
    expect(
      flattenFolders(List.generate(maxArchiveFolders, folder)).length,
      maxArchiveFolders,
    );
    final nested = flattenFolders(chain(maxArchiveFolderDepth + 1));
    expect(nested.last.depth, maxArchiveFolderDepth);
    expect(
      nested.map((f) => f.path),
      List.generate(maxArchiveFolderDepth + 1, (i) => 'path/$i'),
    );
    final mixed = flattenFolders([
      folder(0, children: [folder(1)]),
      folder(2),
    ]);
    expect(mixed.map((f) => f.path), ['path/0', 'path/1', 'path/2']);
  });
  test('rejects excessive width, total nodes and adversarial nesting', () {
    expect(
      () => flattenFolders(List.generate(maxArchiveFolders + 1, folder)),
      throwsFormatException,
    );
    expect(
      () => flattenFolders([
        {...folder(2001), 'children': List.generate(maxArchiveFolders, folder)},
      ]),
      throwsFormatException,
    );
    expect(
      () => flattenFolders(chain(maxArchiveFolderDepth + 2)),
      throwsFormatException,
    );
    expect(() => flattenFolders(chain(20000)), throwsFormatException);
  });
  test('rejects malformed fields, negative counts and duplicate paths', () {
    for (final change in <Map<String, dynamic>>[
      {'name': null},
      {'name': ''},
      {'name': 'x' * (maxArchiveFolderTextLength + 1)},
      {'fullPath': 1},
      {'fullPath': ''},
      {'fullPath': 'x' * (maxArchiveFolderTextLength + 1)},
      {'totalCount': -1},
      {'totalCount': 1.5},
      {'children': {}},
    ]) {
      expect(
        () => flattenFolders([
          {...folder(0), ...change},
        ]),
        throwsFormatException,
      );
    }
    expect(() => flattenFolders([null]), throwsFormatException);
    expect(() => flattenFolders([folder(0), folder(0)]), throwsFormatException);
    expect(
      flattenFolders([
        {...folder(0), 'children': null},
      ]).single.count,
      0,
    );
  });
}
