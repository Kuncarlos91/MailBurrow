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
/// HTTP request it receives, so tests can prove a refused handshake sent
/// nothing (no API key) to the server.
class LabServer {
  LabServer._(this._server);
  final HttpServer _server;
  int requests = 0;

  static Future<LabServer> start(LabCert server) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(server.pemBytes)
      ..usePrivateKeyBytes(server.keyBytes);
    final http = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final lab = LabServer._(http);
    http.listen((request) {
      lab.requests++;
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
}
