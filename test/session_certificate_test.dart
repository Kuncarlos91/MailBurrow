import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException;

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/archive_trust.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';

/// In-memory secure storage.
class Entries extends SecureEntries {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> delete({required String key}) async => values.remove(key);
  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;
}

/// A backend that records the trust it was created with.
class TrustBackend extends FakeArchiveBackend {
  TrustBackend(super.server, super.key, this.trust, {this.handshake = false});
  final ArchiveTrust? trust;
  final bool handshake;
  bool closed = false;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (handshake) {
      throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
    }
    return [const ArchiveAccount(id: '1', name: 'One')];
  }

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => const MailPage(items: []);

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => const [];

  @override
  void close() {
    closed = true;
  }
}

const server = 'https://archive.example';
const other = 'https://other.example';
final certA = List<int>.generate(300, (i) => i % 251);
final certB = List<int>.generate(320, (i) => (i * 7) % 253);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Entries entries;
  late ConnectionStore store;
  late List<TrustBackend> created;
  var handshakeFails = false;

  ArchiveSession session() => ArchiveSession(
    store: store,
    backendFactory: (type, uri, key, {trust}) {
      final backend = TrustBackend(uri, key, trust, handshake: handshakeFails);
      created.add(backend);
      return backend;
    },
  )..busy = false;

  List<int>? lastTrust() => created.last.trust?.der;

  Future<String> saved(String srv, List<int>? der) => store.add(
    serverType: ArchiveServerType.mailArchiver,
    server: srv,
    key: 'saved-key',
    accountId: '1',
    certificate: der == null
        ? const CertificateChange.keep()
        : CertificateChange.set(der),
  );

  setUp(() {
    entries = Entries();
    store = ConnectionStore(entries: entries);
    created = [];
    handshakeFails = false;
  });

  group('setup', () {
    test(
      'invalid pending input clears prior trust and cannot exceed the cap',
      () {
        final s = session();
        addTearDown(s.dispose);
        s.server.text = server;
        expect(s.setPendingCertificate(certA), isTrue);
        s.server.text = 'http://invalid.example';
        expect(s.setPendingCertificate(certB), isFalse);
        expect(s.pendingCertificate, isNull);
        s.server.text = server;
        expect(s.setPendingCertificate(List.filled(65537, 1)), isFalse);
        expect(s.pendingCertificate, isNull);
      },
    );

    test(
      'a confirmed certificate is used and saved with the archive',
      () async {
        final s = session();
        s.server.text = 'archive.example';
        expect(s.setPendingCertificate(certA), isTrue);
        expect(s.pendingCertificate, certA);
        s.keyInput.text = 'new-key';
        await s.connect();
        expect(s.error, isNull);
        expect(lastTrust(), certA);
        expect((await store.read())!.certificate, certA);
        expect(s.pendingCertificate, isNull);
      },
    );

    test('an invalid address keeps no certificate', () {
      final s = session();
      s.server.text = 'http://archive.example';
      expect(s.setPendingCertificate(certA), isFalse);
      expect(s.pendingCertificate, isNull);
    });

    test('a certificate confirmed for another address is not used', () async {
      final s = session();
      s.server.text = 'archive.example';
      s.setPendingCertificate(certA);
      s.server.text = 'other.example';
      s.keyInput.text = 'new-key';
      await s.connect();
      expect(lastTrust(), isNull);
      expect((await store.read())!.certificate, isNull);
      expect(s.pendingCertificate, isNull);
    });

    test('changing the server type clears it', () {
      final s = session();
      s.server.text = 'archive.example';
      s.setPendingCertificate(certA);
      s.chooseServerType(ArchiveServerType.openArchiver);
      expect(s.pendingCertificate, isNull);
    });

    test('a certificate failure is reported so setup can offer help', () async {
      handshakeFails = true;
      final s = session();
      s.server.text = 'archive.example';
      s.keyInput.text = 'new-key';
      await s.connect();
      expect(s.certificateNotVerified, isTrue);
      expect(s.error, isNotNull);
      expect(await store.read(), isNull);
    });
  });

  group('saved archives', () {
    test('restore uses the saved certificate', () async {
      await saved(server, certA);
      final s = session();
      await s.restore();
      expect(s.error, isNull);
      expect(lastTrust(), certA);
    });

    test('switching uses each archive\'s own certificate only', () async {
      final withCert = await saved(server, certA);
      final plain = await saved(other, null);
      final s = session();
      await s.restore();
      expect(lastTrust(), isNull, reason: 'the plain archive is active');
      expect(s.activeArchiveId, plain);
      await s.switchArchive(withCert);
      expect(lastTrust(), certA);
      await s.switchArchive(plain);
      expect(lastTrust(), isNull);
    });

    test('a damaged saved certificate stops the connection', () async {
      final id = await saved(server, certA);
      entries.values['connection.trust.$id'] = 'damaged';
      final before = Map.of(entries.values);
      final s = session();
      await s.restore();
      expect(created, isEmpty, reason: 'no connection without it');
      expect(s.error, contains("own certificate can't be used"));
      expect(entries.values, before);
    });

    test('a damaged certificate also stops a switch', () async {
      final damaged = await saved(server, certA);
      await saved(other, null);
      entries.values['connection.trust.$damaged'] = 'damaged';
      final s = session();
      await s.restore();
      final before = created.length;
      await s.switchArchive(damaged);
      expect(created.length, before);
      expect(s.error, contains("own certificate can't be used"));
    });

    test('a new key for the same address keeps the certificate', () async {
      final id = await saved(server, certA);
      final s = session();
      await s.restore();
      s.openReconfigure(id);
      s.keyInput.text = 'rotated-key';
      await s.connect();
      expect(s.error, isNull);
      expect(lastTrust(), certA);
      final now = await store.read();
      expect(now!.key, 'rotated-key');
      expect(now.certificate, certA);
    });

    test('a new address does not inherit the certificate', () async {
      final id = await saved(server, certA);
      final s = session();
      await s.restore();
      s.openReconfigure(id);
      s.server.text = 'other.example';
      s.keyInput.text = 'k2';
      await s.connect();
      expect(lastTrust(), isNull);
      expect((await store.read())!.certificate, isNull);
    });

    test('an account switch keeps the certificate', () async {
      await saved(server, certA);
      final s = session();
      await s.restore();
      await s.switchAccount(const ArchiveAccount(id: '2', name: 'Two'));
      expect((await store.read())!.certificate, certA);
    });
  });

  group('replace and remove from settings', () {
    test('Retry follows the new profile ID after a failed opening', () async {
      final id = await saved(server, certA);
      await saved(other, null);
      final s = session();
      addTearDown(s.dispose);
      await s.restore();
      handshakeFails = true;
      await s.switchArchive(id);
      expect(s.api, isNull);
      expect(await s.setArchiveCertificate(id, certB), isTrue);
      handshakeFails = false;
      await s.retrySaved();
      expect(s.api!.server.toString(), server);
      expect(lastTrust(), certB);
    });

    test(
      'old trust closes before storage and navigation waits for the change',
      () async {
        final id = await saved(server, certA);
        final otherId = await saved(other, null);
        final held = HeldCertificateStore(entries);
        store = held;
        final s = session();
        addTearDown(s.dispose);
        await s.restore();
        await s.switchArchive(id);
        final previous = created.last;
        final changing = s.setArchiveCertificate(id, certB);
        await held.started.future;
        expect(previous.closed, isTrue);
        expect(s.api, isNull);
        expect(s.canSwitchArchive, isFalse);
        expect(s.canSwitchAccount, isFalse);
        await s.switchArchive(otherId);
        await s.startDemo();
        expect(s.demo, isFalse);
        held.finish.complete();
        expect(await changing, isTrue);
        expect(lastTrust(), certB);
        expect(s.api!.server.toString(), server);
      },
    );

    test(
      'failed replacement keeps saved trust but requires reconnect',
      () async {
        final id = await saved(server, certA);
        final held = HeldCertificateStore(entries)..refuse = true;
        store = held;
        final s = session();
        addTearDown(s.dispose);
        await s.restore();
        final before = Map.of(entries.values);
        final previous = created.last;
        final changing = s.setArchiveCertificate(id, certB);
        await held.started.future;
        held.finish.complete();
        expect(await changing, isFalse);
        expect(previous.closed, isTrue);
        expect(s.api, isNull);
        expect(entries.values, before);
        await s.retrySaved();
        expect(lastTrust(), certA);
        expect(s.api, isNotNull);
      },
    );

    test(
      'inactive trust update does not reconnect the current archive',
      () async {
        final id = await saved(server, certA);
        await saved(other, null);
        final held = HeldCertificateStore(entries);
        store = held;
        final s = session();
        addTearDown(s.dispose);
        await s.restore();
        final previous = created.last;
        final changing = s.setArchiveCertificate(id, certB);
        await held.started.future;
        expect(await s.setArchiveCertificate(id, null), isFalse);
        held.finish.complete();
        expect(await changing, isTrue);
        expect(s.api, same(previous));
        expect(previous.closed, isFalse);
        expect(s.api!.server.toString(), other);
      },
    );

    test('replacing the open archive\'s certificate reopens it', () async {
      await saved(server, certA);
      final s = session();
      await s.restore();
      final oldId = s.activeArchiveId!;
      expect(await s.setArchiveCertificate(oldId, certB), isTrue);
      expect(lastTrust(), certB);
      expect(s.activeArchiveId, isNot(oldId));
      expect(s.api, isNotNull);
      expect((await store.read())!.certificate, certB);
    });

    test('removing it from another archive does not reconnect', () async {
      final withCert = await saved(server, certA);
      await saved(other, null);
      final s = session();
      await s.restore();
      final count = created.length;
      expect(await s.setArchiveCertificate(withCert, null), isTrue);
      expect(created.length, count);
      expect(
        s.archives.where((a) => a.server == server).single.ownCertificate,
        isFalse,
      );
      expect(
        entries.values.keys.where((k) => k.startsWith('connection.trust.')),
        isEmpty,
      );
    });

    test('nothing changes in the demo', () async {
      final s = session();
      s.demo = true;
      expect(await s.setArchiveCertificate('0' * 32, certA), isFalse);
      expect(entries.values, isEmpty);
    });
  });

  test('saved index stays version 3 without certificates', () async {
    final s = session();
    s.server.text = 'archive.example';
    s.keyInput.text = 'k';
    await s.connect();
    final index = jsonDecode(entries.values['connections']!) as Map;
    expect(index['version'], 3);
  });
}

class HeldCertificateStore extends ConnectionStore {
  HeldCertificateStore(Entries entries) : super(entries: entries);
  final started = Completer<void>();
  final finish = Completer<void>();
  bool refuse = false;
  @override
  Future<String> setCertificate(String id, List<int>? der) async {
    started.complete();
    await finish.future;
    if (refuse) throw StateError('synthetic storage refusal');
    return super.setCertificate(id, der);
  }
}
