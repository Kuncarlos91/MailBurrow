import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/archive_trust.dart';
import 'package:mailburrow/bichon_api.dart';
import 'package:mailburrow/open_archiver_api.dart';
import 'package:mailburrow/state/archive_session.dart';

import 'support/lab_certs.dart';

/// Decodes the single certificate in a PEM string to DER bytes.
List<int> derOf(LabCert cert) {
  final body = cert.pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return base64.decode(body);
}

/// A local HTTPS server presenting [server]'s certificate. It counts every
/// HTTP request it receives. A zero count on a refused handshake records no
/// HTTP/auth receipt at this fixture, not an absence of TLS network traffic.
class LabServer {
  LabServer._(this._server);
  final HttpServer _server;
  int requests = 0;
  bool holdResponses = false;
  final received = Completer<void>();

  static Future<LabServer> start(
    LabCert server, {
    List<LabCert> intermediates = const [],
  }) async {
    final context = SecurityContext()
      ..useCertificateChainBytes([
        ...server.pemBytes,
        for (final c in intermediates) ...c.pemBytes,
      ])
      ..usePrivateKeyBytes(server.keyBytes);
    final http = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final lab = LabServer._(http);
    http.listen((request) {
      lab.requests++;
      if (!lab.received.isCompleted) lab.received.complete();
      if (lab.holdResponses) return;
      final response = request.response;
      if (request.uri.path.endsWith('/accounts')) {
        response.headers.contentType = ContentType.json;
        response.write('[]');
      } else {
        response.add(List.filled(5, 65));
      }
      response.close();
    }, onError: (_) {});
    return lab;
  }

  Uri get address => Uri.parse('https://localhost:${_server.port}');
  Future<void> close() => _server.close(force: true);
}

void main() {
  group('ArchiveTrust', () {
    test('rejects an empty certificate', () {
      expect(() => ArchiveTrust(const []), throwsArgumentError);
    });

    test('keeps its own unmodifiable copy of the certificate', () {
      final source = [1, 2, 3];
      final trust = ArchiveTrust(source);
      source[0] = 9;
      expect(trust.der, [1, 2, 3]);
      expect(() => trust.der[0] = 7, throwsUnsupportedError);
    });
  });

  group('archive clients use the archive trust', () {
    late LabCert ca;
    late LabKey caKey;
    late LabCert leaf;

    setUpAll(() {
      caKey = LabKey.ec();
      ca = labCert(cn: 'Lab Root CA', key: caKey, ca: true);
      leaf = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: ca.cn,
        issuerKey: caKey,
        ca: false,
      );
    });

    test(
      'without the certificate, the handshake fails and nothing is sent',
      () async {
        final lab = await LabServer.start(leaf);
        final api = ArchiveApi(lab.address, 'synthetic-test-only');
        addTearDown(() async {
          api.close();
          await lab.close();
        });
        await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
        expect(lab.requests, 0);
      },
    );

    test('with the certificate, API calls and attachments connect', () async {
      final lab = await LabServer.start(leaf);
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(ca)),
      );
      final dir = await Directory.systemTemp.createTemp('trust-test');
      addTearDown(() async {
        api.close();
        await lab.close();
        await dir.delete(recursive: true);
      });
      expect(await api.accounts(), isEmpty);
      final file = File('${dir.path}/a.bin');
      await api.downloadAttachment('1', '2', file);
      expect(await file.length(), 5);
      expect(lab.requests, 2);
    });

    test('a different archive certificate is not trusted', () async {
      final otherKey = LabKey.ec();
      final other = labCert(cn: 'Other Lab CA', key: otherKey, ca: true);
      final lab = await LabServer.start(leaf);
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(other)),
      );
      addTearDown(() async {
        api.close();
        await lab.close();
      });
      await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
      expect(lab.requests, 0);
    });

    test('the hostname is still checked', () async {
      final wrongHost = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: ca.cn,
        issuerKey: caKey,
        ca: false,
        dns: const ['other.test'],
        ips: const [],
      );
      final lab = await LabServer.start(wrongHost);
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(ca)),
      );
      addTearDown(() async {
        api.close();
        await lab.close();
      });
      await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
      expect(lab.requests, 0);
    });

    test('an expired leaf is still refused', () async {
      final expired = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: ca.cn,
        issuerKey: caKey,
        ca: false,
        notBefore: const Duration(days: -30),
        notAfter: const Duration(days: -1),
      );
      final lab = await LabServer.start(expired);
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(ca)),
      );
      addTearDown(() async {
        api.close();
        await lab.close();
      });
      await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
      expect(lab.requests, 0);
    });

    test(
      'all backend transports use trust without leaking it to another profile',
      () async {
        final lab = await LabServer.start(leaf);
        final dir = await Directory.systemTemp.createTemp('backend-trust-test');
        final clients = <ArchiveApi>[];
        addTearDown(() async {
          for (final client in clients) {
            client.close();
          }
          await lab.close();
          await dir.delete(recursive: true);
        });
        for (final type in ArchiveServerType.values) {
          final trusted =
              createArchiveBackend(
                    type,
                    lab.address,
                    'synthetic-test-only',
                    trust: ArchiveTrust(derOf(ca)),
                  )
                  as ArchiveApi;
          final ordinary =
              createArchiveBackend(type, lab.address, 'synthetic-test-only')
                  as ArchiveApi;
          clients.addAll([trusted, ordinary]);
          expect(await trusted.get('accounts'), isEmpty);
          final url = lab.address.resolve('/synthetic-download');
          final file = File('${dir.path}/${type.name}.bin');
          await trusted.downloadTo(url, file);
          expect(await file.length(), 5);
          final before = lab.requests;
          await expectLater(
            ordinary.get('accounts'),
            throwsA(isA<HandshakeException>()),
          );
          await expectLater(
            ordinary.downloadTo(
              url,
              File('${dir.path}/refused-${type.name}.bin'),
            ),
            throwsA(isA<HandshakeException>()),
          );
          expect(
            lab.requests,
            before,
            reason: 'default-trust profile must not inherit ${type.name} trust',
          );
        }
        expect(lab.requests, ArchiveServerType.values.length * 2);
      },
    );

    test(
      'anchor expiry cancels a request waiting for response headers',
      () async {
        final lab = await LabServer.start(leaf);
        lab.holdResponses = true;
        final parsed = ArchiveTrust(derOf(ca));
        final nearExpiry = parsed.notAfter.subtract(const Duration(seconds: 1));
        final api = ArchiveApi(
          lab.address,
          'synthetic-test-only',
          trust: ArchiveTrust(derOf(ca), clock: () => nearExpiry),
        );
        addTearDown(() async {
          api.close();
          await lab.close();
        });
        final cancelled = expectLater(
          api.accounts().timeout(const Duration(seconds: 3)),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              'Request cancelled',
            ),
          ),
        );
        await lab.received.future.timeout(const Duration(seconds: 2));
        await cancelled;
        expect(lab.requests, 1);
        await expectLater(api.accounts(), throwsStateError);
      },
    );

    test(
      'an expired imported anchor cannot reuse the pooled API client',
      () async {
        final lab = await LabServer.start(leaf);
        var now = DateTime.now().toUtc();
        final trust = ArchiveTrust(derOf(ca), clock: () => now);
        final api = ArchiveApi(
          lab.address,
          'synthetic-test-only',
          trust: trust,
        );
        addTearDown(() async {
          api.close();
          await lab.close();
        });
        expect(await api.accounts(), isEmpty);
        now = trust.notAfter.add(const Duration(seconds: 1));
        await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
        expect(
          lab.requests,
          1,
          reason: 'no request/auth after imported-anchor expiry',
        );
      },
    );

    test('every backend passes its trust to its clients', () {
      final trust = ArchiveTrust(derOf(ca));
      final server = Uri.parse('https://archive.example');
      for (final type in ArchiveServerType.values) {
        final backend = createArchiveBackend(type, server, 'k', trust: trust);
        expect((backend as ArchiveApi).trust, same(trust), reason: '$type');
        backend.close();
      }
      expect(OpenArchiverApi(server, 'k', trust: trust).trust, same(trust));
      expect(BichonApi(server, 'k', trust: trust).trust, same(trust));
      expect(
        createArchiveBackend(ArchiveServerType.mailArchiver, server, 'k')
            is ArchiveApi,
        isTrue,
      );
    });
  });

  group('source guards', () {
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('archive HTTPS clients are created only by the trust factory', () {
      final offenders = [
        for (final f in sources)
          if (!f.path.endsWith('archive_trust.dart') &&
              RegExp(r'\bHttpClient\s*\(').hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(offenders, isEmpty);
    });

    test('no code bypasses certificate checks or changes global trust', () {
      final offenders = [
        for (final f in sources)
          if (RegExp(
            r'badCertificateCallback|SecurityContext\.defaultContext',
          ).hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(offenders, isEmpty);
    });
  });

  // Pins the engine's path-length behaviour, documented in the setup guide:
  // limits on intermediates are enforced; an imported root's own limit is
  // not (owner decision PC09, November 26, 2026). If the engine starts
  // enforcing the root's limit, update the docs and this test together.
  group('path-length limits', () {
    test("an intermediate's limit is enforced before any request", () async {
      final rootKey = LabKey.ec();
      final root = labCert(
        cn: 'Lab Root CA',
        key: rootKey,
        ca: true,
        pathLen: null,
      );
      final intKey = LabKey.ec();
      final intermediate = labCert(
        cn: 'Lab Intermediate CA',
        key: intKey,
        issuerCn: root.cn,
        issuerKey: rootKey,
        ca: true,
      );
      final subKey = LabKey.ec();
      final sub = labCert(
        cn: 'Lab Sub CA',
        key: subKey,
        issuerCn: intermediate.cn,
        issuerKey: intKey,
        ca: true,
        pathLen: null,
      );
      final leaf = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: sub.cn,
        issuerKey: subKey,
        ca: false,
      );
      final lab = await LabServer.start(
        leaf,
        intermediates: [sub, intermediate],
      );
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(root)),
      );
      addTearDown(() async {
        api.close();
        await lab.close();
      });
      await expectLater(api.accounts(), throwsA(isA<HandshakeException>()));
      expect(lab.requests, 0);
    });

    test("an imported root's own limit is not applied", () async {
      final rootKey = LabKey.ec();
      final root = labCert(cn: 'Lab Root CA', key: rootKey, ca: true);
      final intKey = LabKey.ec();
      final intermediate = labCert(
        cn: 'Lab Intermediate CA',
        key: intKey,
        issuerCn: root.cn,
        issuerKey: rootKey,
        ca: true,
        pathLen: null,
      );
      final leaf = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: intermediate.cn,
        issuerKey: intKey,
        ca: false,
      );
      final lab = await LabServer.start(leaf, intermediates: [intermediate]);
      final api = ArchiveApi(
        lab.address,
        'synthetic-test-only',
        trust: ArchiveTrust(derOf(root)),
      );
      addTearDown(() async {
        api.close();
        await lab.close();
      });
      expect(await api.accounts(), isEmpty);
    });
  });
}
