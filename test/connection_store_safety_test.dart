import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/state/connection_store.dart';

class MemoryEntries extends SecureEntries {
  final values = <String, String>{};
  Completer<void>? staged, resume;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (key.startsWith('connection.key.') && staged != null) {
      final ready = staged!;
      staged = null;
      ready.complete();
      await resume!.future;
    }
  }
}

Future<void> save(ConnectionStore store, String key) => store.write(
  serverType: ArchiveServerType.mailArchiver,
  server: 'https://archive.example',
  key: key,
  accountId: '1',
);

void main() {
  test('reads across store instances wait for a staged replacement', () async {
    final entries = MemoryEntries();
    final store = ConnectionStore(entries: entries);
    await save(store, 'old');
    final staged = entries.staged = Completer<void>();
    entries.resume = Completer<void>();
    final writing = save(store, 'new');
    await staged.future;
    var readFinished = false;
    final reading = ConnectionStore(entries: entries).read().then((value) {
      readFinished = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readFinished, isFalse);
    entries.resume!.complete();
    await writing;
    expect((await reading)?.key, 'new');
    expect(
      entries.values.keys.where((k) => k.startsWith('connection.key.')),
      hasLength(1),
    );
  });

  test('overlapping replacements retain the last committed key', () async {
    final entries = MemoryEntries();
    final store = ConnectionStore(entries: entries);
    await save(store, 'old');
    final staged = entries.staged = Completer<void>();
    entries.resume = Completer<void>();
    final first = save(store, 'first');
    await staged.future;
    final second = save(ConnectionStore(entries: entries), 'second');
    entries.resume!.complete();
    await Future.wait([first, second]);
    expect((await store.read())?.key, 'second');
    expect(
      entries.values.keys.where((k) => k.startsWith('connection.key.')),
      hasLength(1),
    );
  });

  test('unknown index blocks writes without deleting unrelated keys', () async {
    final entries = MemoryEntries();
    const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    entries.values['connections'] = jsonEncode({
      'version': 4,
      'profiles': [
        {'id': id},
      ],
    });
    entries.values['connection.key.$id'] = 'existing';
    final store = ConnectionStore(entries: entries);
    final before = Map.of(entries.values);
    await expectLater(save(store, 'replacement'), throwsFormatException);
    await expectLater(store.read(), throwsFormatException);
    expect(entries.values, before);
  });

  test('duplicate active ids are all rejected regardless of order', () async {
    final entries = MemoryEntries();
    const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final profile = {
      'id': id,
      'label': 'Archive',
      'serverType': 'mail-archiver',
      'server': 'https://first.example',
      'accountId': '1',
    };
    entries.values['connections'] = jsonEncode({
      'version': 3,
      'active': id,
      'profiles': [
        profile,
        {...profile, 'server': 'https://second.example'},
      ],
    });
    entries.values['connection.key.$id'] = 'shared';
    final store = ConnectionStore(entries: entries);
    for (final profiles in [
      [
        profile,
        {...profile, 'server': 'https://second.example'},
      ],
      [
        {...profile, 'server': 'https://second.example'},
        profile,
      ],
    ]) {
      entries.values['connections'] = jsonEncode({
        'version': 3,
        'active': id,
        'profiles': profiles,
      });
      await expectLater(store.read(), throwsFormatException);
      expect(await store.profiles(), isEmpty);
      expect(entries.values['connection.key.$id'], 'shared');
    }
  });
  test(
    'cleanup failures do not report a committed replacement as failed',
    () async {
      final entries = CleanupFailureEntries();
      final store = ConnectionStore(entries: entries);
      await save(store, 'old');
      entries.values['connection'] = 'leftover';
      entries.failCleanup = true;
      await save(store, 'new');
      expect((await store.read())?.key, 'new');
      entries.failCleanup = false;
      expect((await store.read())?.key, 'new');
      expect(entries.values.containsKey('connection'), isFalse);
      expect(
        entries.values.keys.where((k) => k.startsWith('connection.key.')),
        hasLength(1),
      );
    },
  );

  test(
    'interrupted staging and post-commit snapshots recover safely',
    () async {
      for (final committed in [false, true]) {
        final entries = MemoryEntries();
        const oldId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const newId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final active = committed ? newId : oldId;
        entries.values.addAll({
          'connections': jsonEncode({
            'version': 3,
            'active': active,
            'profiles': [
              {
                'id': active,
                'label': 'Archive',
                'serverType': 'mail-archiver',
                'server': 'https://archive.example',
                'accountId': '1',
              },
            ],
          }),
          'connection.key.$oldId': 'old',
          'connection.key.$newId': 'new',
          if (committed)
            'connection': ConnectionStore.encode(
              serverType: ArchiveServerType.mailArchiver,
              server: 'https://archive.example',
              key: 'old',
              accountId: '1',
            ),
        });
        expect(
          (await ConnectionStore(entries: entries).read())?.key,
          committed ? 'new' : 'old',
        );
        expect(
          entries.values.keys.where((k) => k.startsWith('connection.key.')),
          ['connection.key.$active'],
        );
        expect(entries.values.containsKey('connection'), isFalse);
      }
    },
  );

  test('unreadable profiles count toward the profile cap', () async {
    final entries = MemoryEntries();
    final profiles = [
      for (var i = 0; i < 20; i++)
        {'id': ConnectionStore.newProfileId(), 'serverType': 'future'},
    ];
    entries.values['connections'] = jsonEncode({
      'version': 3,
      'active': null,
      'profiles': profiles,
    });
    final before = Map.of(entries.values);
    await expectLater(
      save(ConnectionStore(entries: entries), 'new'),
      throwsStateError,
    );
    expect(entries.values, before);
  });
}

class CleanupFailureEntries extends MemoryEntries {
  bool failCleanup = false;
  @override
  Future<void> delete({required String key}) async {
    if (failCleanup) throw StateError('cleanup failed');
    return super.delete(key: key);
  }
}
