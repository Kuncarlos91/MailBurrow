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
  void close() {}
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
