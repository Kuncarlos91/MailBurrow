// Test support: fictional lab certificates generated in memory for TLS
// tests, so no key material is ever stored in Git or on disk. Uses
// pointycastle, a dev dependency that is not part of the app.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

final _rng = () {
  final r = FortunaRandom();
  final s = Random.secure();
  r.seed(
    KeyParameter(Uint8List.fromList(List.generate(32, (_) => s.nextInt(256)))),
  );
  return r;
}();

// ---- Minimal DER encoder ----------------------------------------------------

Uint8List _tlv(int tag, List<int> content) {
  final len = content.length;
  final List<int> l;
  if (len < 0x80) {
    l = [len];
  } else {
    final b = <int>[];
    var n = len;
    while (n > 0) {
      b.insert(0, n & 0xff);
      n >>= 8;
    }
    l = [0x80 | b.length, ...b];
  }
  return Uint8List.fromList([tag, ...l, ...content]);
}

Uint8List _seq(List<List<int>> items) =>
    _tlv(0x30, items.expand((e) => e).toList());
Uint8List _set(List<List<int>> items) =>
    _tlv(0x31, items.expand((e) => e).toList());
Uint8List _ctx(int n, List<int> content, {bool constructed = true}) =>
    _tlv((constructed ? 0xa0 : 0x80) | n, content);

Uint8List _bigBytes(BigInt v, [int? width]) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  var bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  if (width != null) {
    while (bytes.length < width) {
      bytes = [0, ...bytes];
    }
  }
  return Uint8List.fromList(bytes);
}

Uint8List _int(BigInt v) {
  var b = _bigBytes(v);
  if (b.isEmpty) b = Uint8List.fromList([0]);
  if (b[0] & 0x80 != 0) b = Uint8List.fromList([0, ...b]);
  return _tlv(0x02, b);
}

Uint8List _oid(String dotted) {
  final p = dotted.split('.').map(int.parse).toList();
  final out = <int>[40 * p[0] + p[1]];
  for (final v in p.skip(2)) {
    final chunk = <int>[v & 0x7f];
    var n = v >> 7;
    while (n > 0) {
      chunk.insert(0, 0x80 | (n & 0x7f));
      n >>= 7;
    }
    out.addAll(chunk);
  }
  return _tlv(0x06, out);
}

Uint8List _bits(List<int> b, [int unused = 0]) => _tlv(0x03, [unused, ...b]);
Uint8List _octets(List<int> b) => _tlv(0x04, b);
final _null = Uint8List.fromList([0x05, 0x00]);
final _true = Uint8List.fromList([0x01, 0x01, 0xff]);

Uint8List _time(DateTime t) {
  t = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final body =
      '${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  return t.year < 2050
      ? _tlv(0x17, ascii.encode('${two(t.year % 100)}$body'))
      : _tlv(0x18, ascii.encode('${t.year}$body'));
}

Uint8List _name(String cn) => _seq([
  _set([
    _seq([_oid('2.5.4.3'), _tlv(0x0c, utf8.encode(cn))]),
  ]),
]);

Uint8List _ext(String oid, List<int> value, {bool critical = false}) =>
    _seq([_oid(oid), if (critical) _true, _octets(value)]);

String _pem(String label, List<int> der) {
  final b = base64.encode(der);
  final lines = [
    for (var i = 0; i < b.length; i += 64)
      b.substring(i, min(i + 64, b.length)),
  ];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

// ---- Keys --------------------------------------------------------------------

/// A generated key pair with its PEM private key and DER public key info.
class LabKey {
  LabKey._(this.pair, this.spki, this.privatePem);
  final AsymmetricKeyPair<PublicKey, PrivateKey> pair;
  final Uint8List spki;
  final String privatePem;

  static LabKey ec() {
    final gen = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          _rng,
        ),
      );
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;
    final point = pub.Q!.getEncoded(false);
    final spki = _seq([
      _seq([_oid('1.2.840.10045.2.1'), _oid('1.2.840.10045.3.1.7')]),
      _bits(point),
    ]);
    final sec1 = _seq([
      _int(BigInt.one),
      _octets(_bigBytes(priv.d!, 32)),
      _ctx(0, _oid('1.2.840.10045.3.1.7')),
      _ctx(1, _bits(point)),
    ]);
    return LabKey._(pair, spki, _pem('EC PRIVATE KEY', sec1));
  }

  static LabKey rsa(int bits, {BigInt? publicExponentOverride}) {
    final gen = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          _rng,
        ),
      );
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;
    final spki = _seq([
      _seq([_oid('1.2.840.113549.1.1.1'), _null]),
      _bits(
        _seq([
          _int(pub.modulus!),
          _int(publicExponentOverride ?? pub.exponent!),
        ]),
      ),
    ]);
    final p = priv.p!, q = priv.q!, d = priv.privateExponent!;
    final pkcs1 = _seq([
      _int(BigInt.zero),
      _int(pub.modulus!),
      _int(pub.exponent!),
      _int(d),
      _int(p),
      _int(q),
      _int(d % (p - BigInt.one)),
      _int(d % (q - BigInt.one)),
      _int(q.modInverse(p)),
    ]);
    return LabKey._(pair, spki, _pem('RSA PRIVATE KEY', pkcs1));
  }
}

// ---- Certificates ------------------------------------------------------------

/// A generated certificate: PEM text, its subject name and the signing key.
class LabCert {
  LabCert._(this.cn, this.pem, this.key);
  final String cn;
  final String pem;
  final LabKey key;

  List<int> get pemBytes => utf8.encode(pem);
  List<int> get keyBytes => utf8.encode(key.privatePem);
}

/// Builds and signs a certificate with an EC (ECDSA) or RSA (PKCS#1 v1.5,
/// SHA-256) issuer key. [keyUsageByte] overrides a CA's key usage bits;
/// [extraExtensions] are (oid, DER value, critical) triples added as-is.
LabCert labCert({
  required String cn,
  required LabKey key,
  String? issuerCn,
  LabKey? issuerKey,
  bool? ca,
  bool keyUsage = true,
  List<String> dns = const ['localhost'],
  List<List<int>> ips = const [
    [127, 0, 0, 1],
  ],
  bool? san,
  Duration notBefore = const Duration(days: -1),
  Duration notAfter = const Duration(days: 365),
  bool sha1 = false,
  int keyUsageByte = 0x06,
  List<(String, List<int>, bool)> extraExtensions = const [],
}) {
  final signer = issuerKey ?? key;
  final now = DateTime.now().toUtc();
  final rsaSigner = signer.pair.privateKey is RSAPrivateKey;
  final sigAlg = rsaSigner
      ? _seq([_oid('1.2.840.113549.1.1.11'), _null])
      : _seq([_oid(sha1 ? '1.2.840.10045.4.1' : '1.2.840.10045.4.3.2')]);
  final exts = <Uint8List>[
    if (ca != null)
      _ext(
        '2.5.29.19',
        _seq([if (ca) _true, if (ca) _int(BigInt.zero)]),
        critical: true,
      ),
    if (ca == true && keyUsage)
      _ext('2.5.29.15', _bits([keyUsageByte], 1), critical: true),
    if (san ?? ca != true)
      _ext(
        '2.5.29.17',
        _seq([
          for (final d in dns) _ctx(2, ascii.encode(d), constructed: false),
          for (final ip in ips) _ctx(7, ip, constructed: false),
        ]),
      ),
    if (ca == false) _ext('2.5.29.37', _seq([_oid('1.3.6.1.5.5.7.3.1')])),
    for (final (oid, value, critical) in extraExtensions)
      _ext(oid, value, critical: critical),
  ];
  final serial = BigInt.parse(
    List.generate(
      16,
      (_) => (_rng.nextUint8() & 0x7f).toRadixString(16).padLeft(2, '0'),
    ).join(),
    radix: 16,
  );
  final tbs = _seq([
    _ctx(0, _int(BigInt.two)),
    _int(serial == BigInt.zero ? BigInt.one : serial),
    sigAlg,
    _name(issuerCn ?? cn),
    _seq([_time(now.add(notBefore)), _time(now.add(notAfter))]),
    _name(cn),
    key.spki,
    if (exts.isNotEmpty) _ctx(3, _seq(exts)),
  ]);
  if (rsaSigner) {
    final rsa = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        true,
        PrivateKeyParameter<RSAPrivateKey>(
          signer.pair.privateKey as RSAPrivateKey,
        ),
      );
    final sig = rsa.generateSignature(tbs);
    return LabCert._(
      cn,
      _pem('CERTIFICATE', _seq([tbs, sigAlg, _bits(sig.bytes)])),
      key,
    );
  }
  final ecdsa = ECDSASigner(sha1 ? SHA1Digest() : SHA256Digest())
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(
          signer.pair.privateKey as ECPrivateKey,
        ),
        _rng,
      ),
    );
  final sig = ecdsa.generateSignature(tbs) as ECSignature;
  final cert = _seq([
    tbs,
    sigAlg,
    _bits(_seq([_int(sig.r), _int(sig.s)])),
  ]);
  return LabCert._(cn, _pem('CERTIFICATE', cert), key);
}

/// DER helpers for tests that build extension values or malformed input.
Uint8List derSequence(List<List<int>> items) => _seq(items);
Uint8List derOid(String dotted) => _oid(dotted);

/// The single certificate in [cert]'s PEM, as DER bytes.
Uint8List labDer(LabCert cert) => base64.decode(
  cert.pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join(),
);
