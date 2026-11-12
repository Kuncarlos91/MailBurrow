import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_errors.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/attachment_download.dart';
import 'package:mailburrow/demo/demo_archive.dart';
import 'package:mailburrow/search_filters.dart';

/// Fails the test if anything tries to open a network connection.
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Demo mode must not open network connections');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DemoArchive demo;

  setUp(() async {
    demo = await DemoArchive.load(latency: Duration.zero);
  });

  List<MailSummary> items(MailPage page) => page.items;

  // Demo account addresses, for checking sent mail by its sender.
  const addresses = {
    '1': 'alex.rivera@example.com',
    '2': 'hello@maple-street-bakery.example',
    '3': 'volunteers@riverside-garden-club.example',
  };

  test('identifies itself as a reserved, unreachable demo address', () {
    expect(demo.server.scheme, 'https');
    expect(demo.server.host, 'demo.mailburrow.invalid');
    expect(demo.server.host.endsWith('.invalid'), isTrue);
  });

  test('lists three fictional accounts on reserved domains', () async {
    final accounts = await demo.accounts();
    expect(accounts.map((item) => item.id), ['1', '2', '3']);
    for (final account in accounts) {
      final address = account.emailAddress!;
      expect(addresses[account.id], address);
      expect(
        address.endsWith('@example.com') || address.endsWith('.example'),
        isTrue,
        reason: address,
      );
    }
  });

  test('folders flatten with nesting and counts that match the mail', () async {
    final folders = await demo.folders('1');
    final family = folders.firstWhere((item) => item.path == 'INBOX/Family');
    expect(family.depth, 1);
    expect(family.name, 'Family');
    final total = folders.fold<int>(0, (sum, item) => sum + item.count);
    final all = await demo.emails('1', '', 1);
    expect(total, all.totalItems);
    await expectLater(demo.folders('99'), throwsA(isA<ArchiveFailure>()));
  });

  test('pages 25 results at a time, newest first by default', () async {
    final first = await demo.emails('1', '', 1);
    final second = await demo.emails('1', '', 2);
    expect(items(first), hasLength(25));
    expect(first.totalPages, 2);
    expect(items(second), hasLength(first.totalItems! - 25));
    expect(items(first).first.subject, 'Welcome to the MailBurrow demo');
    final dates = items(first)
        .map((mail) => mail.sentDate ?? '')
        .where((date) => date.isNotEmpty)
        .toList();
    expect(dates, [...dates]..sort((a, b) => b.compareTo(a)));
  });

  test('search is case-insensitive across subject, people and body', () async {
    final upper = items(await demo.emails('2', 'INVOICE', 1));
    final lower = items(await demo.emails('2', 'invoice', 1));
    expect(upper, isNotEmpty);
    expect(upper.map((m) => m.id), lower.map((m) => m.id));
    final byBody = items(await demo.emails('1', 'lemon cake', 1));
    expect(byBody.map((m) => m.subject), contains('Recipe you asked for'));
    final none = await demo.emails('1', 'no such words anywhere', 1);
    expect(items(none), isEmpty);
    expect(none.totalPages, 0);
  });

  test('filters by folder, direction and inclusive date range', () async {
    final receipts = items(await demo.emails('1', '', 1, folder: 'Receipts'));
    expect(receipts, isNotEmpty);
    for (final mail in receipts) {
      expect((await demo.message(mail.id)).folderName, 'Receipts');
    }

    final sent = items(
      await demo.emails(
        '1',
        '',
        1,
        filters: const SearchFilters(direction: 'outgoing'),
      ),
    );
    expect(sent, isNotEmpty);
    expect(
      sent.every((m) => m.from?.contains(addresses['1']!) ?? false),
      isTrue,
    );
    final received = items(
      await demo.emails(
        '1',
        '',
        1,
        filters: const SearchFilters(direction: 'incoming'),
      ),
    );
    expect(received, isNotEmpty);
    expect(
      received.any((m) => m.from?.contains(addresses['1']!) ?? false),
      isFalse,
    );

    final ranged = items(
      await demo.emails(
        '1',
        '',
        1,
        filters: SearchFilters(
          from: DateTime(2021, 1, 1),
          to: DateTime(2021, 12, 31),
        ),
      ),
    );
    expect(ranged, isNotEmpty);
    expect(
      ranged.every((m) => m.sentDate!.startsWith('2021-')),
      isTrue,
    );
  });

  test('sorts by subject in either order', () async {
    final ascending = items(
      await demo.emails(
        '3',
        '',
        1,
        filters: const SearchFilters(sortBy: 'subject', sortOrder: 'asc'),
      ),
    ).map((m) => m.subject!.toLowerCase()).toList();
    expect(ascending, [...ascending]..sort());
    final descending = items(
      await demo.emails(
        '3',
        '',
        1,
        filters: const SearchFilters(sortBy: 'subject'),
      ),
    ).map((m) => m.subject!.toLowerCase()).toList();
    expect(descending, ascending.reversed.toList());
  });

  test('opens full messages and rejects unknown ones', () async {
    final welcome = items(await demo.emails('1', 'welcome', 1)).first;
    final mail = await demo.message(welcome.id);
    expect(mail.textBody, contains('fictional sample mail'));
    expect(mail.attachments, isEmpty);
    await expectLater(demo.message('99999'), throwsA(isA<ArchiveFailure>()));
  });

  test('reports totals across all demo accounts', () async {
    final stats = await demo.stats();
    expect(stats.accounts, 3);
    expect(stats.emails, greaterThanOrEqualTo(50));
    expect(stats.attachments, greaterThanOrEqualTo(10));
  });

  group('attachments', () {
    late Directory folder;
    setUp(() async => folder = await Directory.systemTemp.createTemp('demo'));
    tearDown(() async => folder.delete(recursive: true));

    Future<(String, MailAttachment)> withAttachment() async {
      final mail = items(
        await demo.emails('1', 'photos', 1),
      ).firstWhere((m) => m.hasAttachments);
      final detail = await demo.message(mail.id);
      final file = detail.attachments.first;
      return (mail.id, file);
    }

    test('saves the exact bundled bytes with progress', () async {
      final (emailId, file) = await withAttachment();
      final target = File('${folder.path}/saved');
      final progress = <int>[];
      await demo.downloadAttachment(
        emailId,
        file.id,
        target,
        onProgress: progress.add,
      );
      final bundled = await rootBundle.load(
        '$demoAttachmentDirectory/${file.name}',
      );
      expect(
        await target.readAsBytes(),
        bundled.buffer.asUint8List(
          bundled.offsetInBytes,
          bundled.lengthInBytes,
        ),
      );
      expect(progress.last, file.size);
    });

    test('a cancelled save leaves no file', () async {
      final (emailId, file) = await withAttachment();
      final target = File('${folder.path}/cancelled');
      final transfer = AttachmentDownload()..cancel();
      await expectLater(
        demo.downloadAttachment(
          emailId,
          file.id,
          target,
          transfer: transfer,
        ),
        throwsA(isA<AttachmentDownloadCancelled>()),
      );
      expect(target.existsSync(), isFalse);
    });

    Future<(String, MailAttachment)> multiChunkAttachment() async {
      // The boarding pass PDF is larger than one 256-byte copy chunk.
      final mail = items(
        await demo.emails('1', 'Harbor City', 1),
      ).firstWhere((m) => m.hasAttachments);
      final detail = await demo.message(mail.id);
      final file = detail.attachments.first;
      expect(file.size, greaterThan(512));
      return (mail.id, file);
    }

    test(
      'cancelling during a copy stops writing and deletes the file',
      () async {
        final (emailId, file) = await multiChunkAttachment();
        final slow = await DemoArchive.load(
          latency: const Duration(milliseconds: 50),
        );
        final target = File('${folder.path}/cancelled-midway');
        final transfer = AttachmentDownload();
        final progress = <int>[];
        await expectLater(
          slow.downloadAttachment(
            emailId,
            file.id,
            target,
            transfer: transfer,
            onProgress: (received) {
              progress.add(received);
              transfer.cancel();
            },
          ),
          throwsA(isA<AttachmentDownloadCancelled>()),
        );
        expect(progress, hasLength(1));
        expect(target.existsSync(), isFalse);
      },
    );

    test('closing during a copy stops writing and deletes the file', () async {
      final (emailId, file) = await multiChunkAttachment();
      final slow = await DemoArchive.load(
        latency: const Duration(milliseconds: 50),
      );
      final target = File('${folder.path}/closed-midway');
      final progress = <int>[];
      await expectLater(
        slow.downloadAttachment(
          emailId,
          file.id,
          target,
          onProgress: (received) {
            progress.add(received);
            slow.close();
          },
        ),
        throwsA(anything),
      );
      expect(progress, hasLength(1));
      expect(target.existsSync(), isFalse);
      await expectLater(
        slow.downloadAttachment(emailId, file.id, target),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects an attachment from a different message', () async {
      final (_, file) = await withAttachment();
      final welcome = items(await demo.emails('1', 'welcome', 1)).first;
      await expectLater(
        demo.downloadAttachment(
          welcome.id,
          file.id,
          File('${folder.path}/wrong'),
        ),
        throwsA(isA<ArchiveFailure>()),
      );
    });
  });

  test('never opens a network connection', () async {
    await HttpOverrides.runZoned(() async {
      final local = await DemoArchive.load(latency: Duration.zero);
      final accounts = await local.accounts();
      await local.folders('1');
      final page = await local.emails('2', 'invoice', 1);
      await local.emails('2', '', 1, folder: 'INBOX/Orders');
      await local.stats();
      for (final mail in items(page)) {
        await local.message(mail.id);
      }
      final withFile = items(
        page,
      ).firstWhere((m) => m.hasAttachments);
      final detail = await local.message(withFile.id);
      final file = detail.attachments.first;
      final folder = await Directory.systemTemp.createTemp('demo-offline');
      try {
        final target = File('${folder.path}/saved');
        await local.downloadAttachment(
          withFile.id,
          file.id,
          target,
        );
        expect(await target.length(), file.size);
      } finally {
        await folder.delete(recursive: true);
      }
      expect(accounts, isNotEmpty);
    }, createHttpClient: _NoNetwork().createHttpClient);
  });

  test('refuses requests after closing', () async {
    demo.close();
    await expectLater(demo.accounts(), throwsA(isA<StateError>()));
    await expectLater(demo.emails('1', '', 1), throwsA(isA<StateError>()));
  });
}
