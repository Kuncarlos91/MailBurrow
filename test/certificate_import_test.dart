import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/certificate_import.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'support/lab_certs.dart';

CertificateDetails accepted(List<int> bytes, {DateTime? now}) {
  final result = readCertificateFile(bytes, now: now);
  expect(result, isA<CertificateAccepted>(), reason: '$result');
  return (result as CertificateAccepted).details;
}

CertificateRejection rejected(List<int> bytes, {DateTime? now}) {
  final result = readCertificateFile(bytes, now: now);
  expect(result, isA<CertificateRejected>());
  return (result as CertificateRejected).reason;
}

void main() {
  late LabKey rootKey;
  late LabCert root;

  setUpAll(() {
    rootKey = LabKey.ec();
    root = labCert(
      cn: 'Lab Root CA',
      key: rootKey,
      ca: true,
      notBefore: const Duration(days: -30),
      notAfter: const Duration(days: 3650),
    );
  });

  LabCert issued({
    LabKey? key,
    bool? ca = false,
    String cn = 'lab server',
    bool sha1 = false,
  }) => labCert(
    cn: cn,
    key: key ?? LabKey.ec(),
    issuerCn: root.cn,
    issuerKey: rootKey,
    ca: ca,
    sha1: sha1,
  );

  group('accepted', () {
    test('an EC root CA in PEM, with its details', () {
      final d = accepted(root.pemBytes);
      expect(d.kind, CertificateKind.rootCa);
      expect(d.isCa, isTrue);
      expect(d.subject, 'Lab Root CA');
      expect(d.issuer, 'Lab Root CA');
      expect(d.keyDescription, 'EC P-256');
      expect(d.signatureAlgorithm, 'ECDSA with SHA-256');
      expect(d.der, labDer(root));
      expect(d.sha256, SHA256Digest().process(labDer(root)));
      expect(
        d.fingerprint,
        matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')),
      );
    });

    test('the same certificate as DER gives the same result', () {
      final pem = accepted(root.pemBytes);
      final der = accepted(labDer(root));
      expect(der.fingerprint, pem.fingerprint);
      expect(der.kind, CertificateKind.rootCa);
    });

    test('an RSA-2048 root signed with SHA-256', () {
      final key = LabKey.rsa(2048);
      final rsaRoot = labCert(cn: 'RSA Lab Root', key: key, ca: true);
      final d = accepted(rsaRoot.pemBytes);
      expect(d.kind, CertificateKind.rootCa);
      expect(d.keyDescription, 'RSA 2048');
      expect(d.signatureAlgorithm, 'RSA with SHA-256');
    });

    test('an intermediate CA', () {
      final d = accepted(issued(ca: true, cn: 'Lab Issuing CA').pemBytes);
      expect(d.kind, CertificateKind.intermediateCa);
      expect(d.issuer, 'Lab Root CA');
    });

    test('a self-signed server certificate, with its names', () {
      final cert = labCert(cn: 'lab server', key: LabKey.ec(), ca: false);
      final d = accepted(cert.pemBytes);
      expect(d.kind, CertificateKind.selfSignedServer);
      expect(d.isCa, isFalse);
      expect(d.dnsNames, ['localhost']);
      expect(d.ipAddresses, ['127.0.0.1']);
    });

    test('a self-signed server certificate without basicConstraints', () {
      final cert = labCert(cn: 'lab server', key: LabKey.ec(), san: true);
      expect(accepted(cert.pemBytes).kind, CertificateKind.selfSignedServer);
    });

    test('PEM with a BOM, CRLF line endings and surrounding whitespace', () {
      final text = '\uFEFF\r\n  ${root.pem.replaceAll('\n', '\r\n')}\r\n\r\n';
      expect(accepted(utf8.encode(text)).kind, CertificateKind.rootCa);
    });

    test('an unknown non-critical extension is ignored', () {
      final cert = labCert(
        cn: 'Lab Root CA',
        key: LabKey.ec(),
        ca: true,
        extraExtensions: [('1.3.6.1.4.1.99999.1', derSequence([]), false)],
      );
      expect(accepted(cert.pemBytes).kind, CertificateKind.rootCa);
    });

    test('non-critical name constraints are still accepted', () {
      final cert = labCert(
        cn: 'Lab Root CA',
        key: LabKey.ec(),
        ca: true,
        extraExtensions: [('2.5.29.30', derSequence([]), false)],
      );
      expect(accepted(cert.pemBytes).kind, CertificateKind.rootCa);
    });
  });

  test('accepted bytes and fingerprint cannot change after validation', () {
    final details = accepted(root.pemBytes);
    final der = List<int>.of(details.der);
    final fingerprint = details.fingerprint;
    expect(() => details.der[0] ^= 1, throwsUnsupportedError);
    expect(() => details.sha256[0] ^= 1, throwsUnsupportedError);
    expect(details.der, der);
    expect(details.fingerprint, fingerprint);
  });

  group('rejected', () {
    test('key usage cannot set an unused DER padding bit', () {
      final cert = labCert(
        cn: 'Lab CA',
        key: rootKey,
        ca: true,
        keyUsageByte: 7,
      );
      expect(rejected(cert.pemBytes), CertificateRejection.notACertificate);
    });

    test('RSA public exponents have a bounded supported size', () {
      final largeExponent = LabKey.rsa(
        2048,
        publicExponentOverride: (BigInt.one << 64) + BigInt.one,
      );
      final cert = labCert(
        cn: 'Intermediate',
        key: largeExponent,
        issuerCn: root.cn,
        issuerKey: rootKey,
        ca: true,
      );
      expect(
        rejected(cert.pemBytes),
        CertificateRejection.unsupportedAlgorithm,
      );
    });

    test('a server certificate issued by a CA', () {
      expect(
        rejected(issued().pemBytes),
        CertificateRejection.caIssuedServerCertificate,
      );
    });

    test('a name-matching certificate signed by a different key', () {
      // Issuer and subject names match, but the signature isn't its own.
      final forged = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: 'lab server',
        issuerKey: LabKey.ec(),
        ca: false,
      );
      expect(
        rejected(forged.pemBytes),
        CertificateRejection.caIssuedServerCertificate,
      );
    });

    test('SHA-1 signatures', () {
      expect(
        rejected(issued(sha1: true).pemBytes),
        CertificateRejection.weakSignature,
      );
    });

    test('RSA keys under 2048 bits', () {
      expect(
        rejected(issued(key: LabKey.rsa(1024)).pemBytes),
        CertificateRejection.weakKey,
      );
    });

    test('expired and not-yet-valid certificates', () {
      final now = DateTime.now().toUtc();
      expect(
        rejected(root.pemBytes, now: now.add(const Duration(days: 3700))),
        CertificateRejection.expired,
      );
      expect(
        rejected(root.pemBytes, now: now.subtract(const Duration(days: 40))),
        CertificateRejection.notYetValid,
      );
    });

    test('a CA that may not sign certificates', () {
      final cert = labCert(
        cn: 'Odd CA',
        key: LabKey.ec(),
        ca: true,
        keyUsageByte: 0x80, // digitalSignature only.
      );
      expect(
        rejected(cert.pemBytes),
        CertificateRejection.caCannotSignCertificates,
      );
    });

    test('an unknown critical extension', () {
      final cert = labCert(
        cn: 'Lab Root CA',
        key: LabKey.ec(),
        ca: true,
        extraExtensions: [('1.3.6.1.4.1.99999.1', derSequence([]), true)],
      );
      expect(
        rejected(cert.pemBytes),
        CertificateRejection.unsupportedCriticalExtension,
      );
    });

    for (final (oid, name) in [
      ('2.5.29.30', 'name constraints'),
      ('2.5.29.32', 'certificate policies'),
      ('2.5.29.36', 'policy constraints'),
      ('2.5.29.37', 'extended key usage'),
      ('2.5.29.54', 'inhibit any policy'),
    ]) {
      test('critical $name on an imported CA', () {
        final cert = labCert(
          cn: 'Lab Root CA',
          key: LabKey.ec(),
          ca: true,
          extraExtensions: [(oid, derSequence([]), true)],
        );
        expect(
          rejected(cert.pemBytes),
          CertificateRejection.unsupportedCriticalExtension,
        );
      });
    }

    test('critical extended key usage on a self-signed server', () {
      final cert = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        san: true,
        extraExtensions: [
          ('2.5.29.37', derSequence([derOid('1.3.6.1.5.5.7.3.1')]), true),
        ],
      );
      expect(
        rejected(cert.pemBytes),
        CertificateRejection.unsupportedCriticalExtension,
      );
    });

    test('private keys, alone or with a certificate', () {
      expect(rejected(root.keyBytes), CertificateRejection.privateKey);
      expect(
        rejected([...root.keyBytes, ...root.pemBytes]),
        CertificateRejection.privateKey,
      );
      expect(
        rejected([...root.pemBytes, ...root.keyBytes]),
        CertificateRejection.privateKey,
      );
      // The same key in binary (DER) form.
      final keyDer = base64.decode(
        root.key.privatePem
            .split('\n')
            .where((l) => l.isNotEmpty && !l.startsWith('-----'))
            .join(),
      );
      expect(rejected(keyDer), CertificateRejection.privateKey);
    });

    test('more than one certificate', () {
      final other = labCert(cn: 'Other', key: LabKey.ec(), ca: true);
      expect(
        rejected([...root.pemBytes, ...other.pemBytes]),
        CertificateRejection.multipleCertificates,
      );
    });

    test('files over the size limit', () {
      final big = [
        ...root.pemBytes,
        ...List.filled(certificateImportByteLimit, 0x20),
      ];
      expect(rejected(big), CertificateRejection.tooLarge);
    });

    test('anything that is not exactly one certificate', () {
      final der = labDer(root);
      final pem = root.pem;
      final cases = <String, List<int>>{
        'empty': [],
        'text': utf8.encode('hello'),
        'DER with a trailing byte': [...der, 0],
        'truncated DER': der.sublist(0, der.length - 1),
        'text after the PEM block': utf8.encode('${pem}trailing'),
        'text before the PEM block': utf8.encode('note\n$pem'),
        'other PEM type': utf8.encode(
          pem.replaceAll('CERTIFICATE', 'TRUSTED CERTIFICATE'),
        ),
        'PKCS7 PEM': utf8.encode(pem.replaceAll('CERTIFICATE', 'PKCS7')),
        'mismatched PEM labels': utf8.encode(
          pem.replaceFirst('END CERTIFICATE', 'END X509 CRL'),
        ),
        'PEM headers (encrypted)': utf8.encode(
          pem.replaceFirst('-----\n', '-----\nProc-Type: 4,ENCRYPTED\n\n'),
        ),
        'bad base64': utf8.encode(pem.replaceFirst('M', '*')),
        'not UTF-8': [0xff, 0xfe, 0x00],
      };
      for (final e in cases.entries) {
        expect(
          rejected(e.value),
          CertificateRejection.notACertificate,
          reason: e.key,
        );
      }
    });
  });

  group('display and warnings', () {
    test('names lose control and bidi-override characters', () {
      final cert = labCert(
        cn: 'Lab\u202E AC\u0007 Root\u2066',
        key: LabKey.ec(),
        ca: true,
      );
      expect(accepted(cert.pemBytes).subject, 'Lab AC Root');
      expect(safeDisplayText('a\u200Bb\u0000c'), 'abc');
      expect(safeDisplayText('x' * 300).length, 201);
    });

    test('the short-lifetime warning applies only to self-signed servers', () {
      final now = DateTime.now().toUtc();
      final shortTotal = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        ca: false,
        notBefore: const Duration(days: -1),
        notAfter: const Duration(days: 20),
      );
      final d = accepted(shortTotal.pemBytes, now: now);
      expect(d.isShortLived(now), isTrue);

      final longLived = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        ca: false,
        notBefore: const Duration(days: -1),
        notAfter: const Duration(days: 90),
      );
      final l = accepted(longLived.pemBytes, now: now);
      expect(l.isShortLived(now), isFalse);
      expect(l.isShortLived(now.add(const Duration(days: 85))), isTrue);

      final rootDetails = accepted(root.pemBytes, now: now);
      expect(
        rootDetails.isShortLived(now.add(const Duration(days: 3645))),
        isFalse,
      );
    });

    test('settings can tell when a certificate expires soon', () {
      final now = DateTime.now().toUtc();
      final d = accepted(root.pemBytes, now: now);
      expect(d.expiresWithin(const Duration(days: 30), now), isFalse);
      expect(
        d.expiresWithin(
          const Duration(days: 30),
          now.add(const Duration(days: 3630)),
        ),
        isTrue,
      );
    });
  });

  test('random corruption is always refused or read, never a crash', () {
    final rng = Random(20261124);
    final der = labDer(root);
    final self = labDer(labCert(cn: 'lab server', key: LabKey.ec(), ca: false));
    for (final source in [der, self]) {
      for (var i = 0; i < 400; i++) {
        final mutated = Uint8List.fromList(source);
        for (var k = 0; k < 1 + rng.nextInt(3); k++) {
          mutated[rng.nextInt(mutated.length)] = rng.nextInt(256);
        }
        final cut = rng.nextInt(8) == 0
            ? mutated.sublist(0, rng.nextInt(mutated.length))
            : mutated;
        expect(
          () => readCertificateFile(cut),
          returnsNormally,
          reason: 'mutation $i',
        );
      }
    }
  });
}
