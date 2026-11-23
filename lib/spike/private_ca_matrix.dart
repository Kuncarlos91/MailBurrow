// SPIKE ONLY (branch spike/private-ca-device, not for merge).
//
// Runs TLS trust cases against a local HTTPS server inside the app, using
// fictional certificates generated in memory. No archive, key or user data
// is involved; the only outside connection is an optional check against a
// public HTTPS site to see whether public roots still work.
import 'dart:async';
import 'dart:io';

import 'lab_certs.dart';

/// One line of the matrix.
class MatrixRow {
  MatrixRow(this.id, this.name, this.result, this.requests);
  final String id, name, result;
  final int? requests;
  @override
  String toString() =>
      '$id ${name.padRight(52)} | $result${requests == null ? '' : ' | requests: $requests'}';
}

Future<(String, int)> _run(
  LabCert server,
  List<LabCert> anchors, {
  String host = 'localhost',
  bool roots = true,
  List<LabCert>? chain,
}) async {
  final sctx = SecurityContext()
    ..useCertificateChainBytes(
      (chain ?? [server]).expand((c) => c.pemBytes).toList(),
    )
    ..usePrivateKeyBytes(server.keyBytes);
  final srv = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    sctx,
  );
  var hits = 0;
  srv.listen((r) {
    hits++;
    r.response
      ..write('ok')
      ..close();
  }, onError: (_) {});
  String result;
  try {
    final cctx = SecurityContext(withTrustedRoots: roots);
    for (final a in anchors) {
      cctx.setTrustedCertificatesBytes(a.pemBytes);
    }
    final client = HttpClient(context: cctx)
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse('https://$host:${srv.port}/'));
      req.headers.set('x-api-key', 'synthetic-test-only');
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      result = 'OK ${res.statusCode}';
    } on HandshakeException catch (e) {
      result =
          'FAIL ${(e.osError?.message ?? e.message).trim().split('(').first}';
    } on Object catch (e) {
      result = 'FAIL ${e.runtimeType}';
    } finally {
      client.close(force: true);
    }
  } on Object catch (e) {
    result = 'IMPORT ERROR ${e.runtimeType}';
  }
  await srv.close(force: true);
  return (result, hits);
}

Future<String> _publicCheck(bool roots, LabCert? imported) async {
  final ctx = SecurityContext(withTrustedRoots: roots);
  if (imported != null) ctx.setTrustedCertificatesBytes(imported.pemBytes);
  final client = HttpClient(context: ctx)
    ..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.headUrl(Uri.parse('https://www.example.com/'));
    final res = await req.close().timeout(const Duration(seconds: 10));
    await res.drain<void>();
    return 'OK ${res.statusCode}';
  } on HandshakeException catch (e) {
    return 'FAIL ${(e.osError?.message ?? e.message).trim().split('(').first}';
  } on Object catch (e) {
    return 'NO NETWORK? ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

/// Generates the fictional certificates and runs every case.
Stream<MatrixRow> runPrivateCaMatrix() async* {
  final caKey = LabKey.ec();
  final ca = labCert(
    cn: 'Lab Root CA',
    key: caKey,
    ca: true,
    notBefore: const Duration(days: -30),
    notAfter: const Duration(days: 3650),
  );
  final other = labCert(cn: 'Other Lab CA', key: LabKey.ec(), ca: true);
  final expiredCaKey = LabKey.ec();
  final expiredCa = labCert(
    cn: 'Expired Lab CA',
    key: expiredCaKey,
    ca: true,
    notBefore: const Duration(days: -400),
    notAfter: const Duration(days: -1),
  );
  LabCert leaf({
    LabKey? key,
    LabCert? by,
    LabKey? byKey,
    List<String> dns = const ['localhost'],
    bool sha1 = false,
    Duration nb = const Duration(days: -1),
    Duration na = const Duration(days: 365),
  }) => labCert(
    cn: 'lab server',
    key: key ?? LabKey.ec(),
    issuerCn: (by ?? ca).cn,
    issuerKey: byKey ?? caKey,
    ca: false,
    dns: dns,
    sha1: sha1,
    notBefore: nb,
    notAfter: na,
  );
  LabCert self({bool? ca}) => labCert(
    cn: 'lab server',
    key: LabKey.ec(),
    ca: ca,
    keyUsage: false,
    san: true,
    notAfter: const Duration(days: 90),
  );

  final good = leaf();
  final selfNoCa = self(ca: false);
  final cases = <(String, String, Future<(String, int)> Function())>[
    ('01', 'private-CA leaf, public roots only', () => _run(good, [])),
    ('02', 'private-CA leaf, CA imported', () => _run(good, [ca])),
    (
      '03',
      'private-CA leaf, CA imported, IP SAN',
      () => _run(good, [ca], host: '127.0.0.1'),
    ),
    ('04', 'private-CA leaf, different CA imported', () => _run(good, [other])),
    (
      '05',
      'wrong hostname, CA imported',
      () => _run(leaf(dns: ['other.test']), [ca]),
    ),
    (
      '06',
      'expired leaf, CA imported',
      () => _run(
        leaf(nb: const Duration(days: -30), na: const Duration(days: -1)),
        [ca],
      ),
    ),
    (
      '07',
      'not-yet-valid leaf, CA imported',
      () => _run(
        leaf(nb: const Duration(days: 5), na: const Duration(days: 30)),
        [ca],
      ),
    ),
    (
      '08',
      'SHA-1 signed leaf, CA imported',
      () => _run(leaf(sha1: true), [ca]),
    ),
    (
      '09',
      'RSA-1024 leaf, CA imported',
      () => _run(leaf(key: LabKey.rsa(1024)), [ca]),
    ),
    (
      '10',
      'valid leaf under EXPIRED imported CA',
      () => _run(
        leaf(by: expiredCa, byKey: expiredCaKey, na: const Duration(days: 30)),
        [expiredCa],
      ),
    ),
    (
      '11',
      'CA-issued leaf imported as anchor',
      () {
        final l = leaf(na: const Duration(days: 1));
        return _run(l, [l]);
      },
    ),
    ('12', 'self-signed CA:FALSE imported', () => _run(selfNoCa, [selfNoCa])),
    (
      '13',
      'self-signed, no basicConstraints',
      () {
        final s = self();
        return _run(s, [s]);
      },
    ),
    (
      '14',
      'self-signed CA:TRUE imported',
      () {
        final s = self(ca: true);
        return _run(s, [s]);
      },
    ),
    (
      '15',
      'self-signed renewed (new key), old imported',
      () => _run(self(ca: false), [selfNoCa]),
    ),
    (
      '16',
      'self-signed CA:FALSE, IP SAN',
      () => _run(selfNoCa, [selfNoCa], host: '127.0.0.1'),
    ),
    (
      '17',
      'server sends leaf+CA, nothing imported',
      () => _run(good, [], chain: [good, ca]),
    ),
    (
      '18',
      'CA imported, withTrustedRoots:false',
      () => _run(good, [ca], roots: false),
    ),
    ('19', 'two CAs imported (other + correct)', () => _run(good, [other, ca])),
  ];
  for (final (id, name, fn) in cases) {
    final (r, hits) = await fn();
    yield MatrixRow(id, name, r, hits);
  }
  yield MatrixRow(
    '20',
    'public site, roots:true + lab CA imported',
    await _publicCheck(true, ca),
    null,
  );
  yield MatrixRow(
    '21',
    'public site, roots:true, nothing imported',
    await _publicCheck(true, null),
    null,
  );
  yield MatrixRow(
    '22',
    'public site, roots:false + lab CA imported',
    await _publicCheck(false, ca),
    null,
  );
  final inputs = <String, List<int>>{
    'private key only': caKey.privatePem.codeUnits,
    'key + certificate': [...good.keyBytes, ...good.pemBytes],
    'not a certificate': 'not a certificate'.codeUnits,
    'two certificates': [...ca.pemBytes, ...other.pemBytes],
  };
  for (final e in inputs.entries) {
    String r;
    try {
      SecurityContext(
        withTrustedRoots: true,
      ).setTrustedCertificatesBytes(e.value);
      r = 'accepted';
    } on Object catch (x) {
      r = 'rejected (${x.runtimeType})';
    }
    yield MatrixRow('I', 'import: ${e.key}', r, null);
  }
}
