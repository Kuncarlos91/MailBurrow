import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha384.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/ecc/curves/secp384r1.dart';
import 'package:pointycastle/ecc/curves/secp521r1.dart';
import 'package:pointycastle/api.dart' show Digest, PublicKeyParameter;
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

/// Largest certificate file MailBurrow reads, in bytes.
const certificateImportByteLimit = 64 * 1024;

/// A self-signed server certificate this close to expiry, or with a total
/// lifetime this short, gets the short-lifetime warning.
const shortLivedRemaining = Duration(days: 7);
const shortLivedTotal = Duration(days: 31);

/// Why a file can't be trusted. Each has a plain message and fix in the UI.
enum CertificateRejection {
  /// Larger than [certificateImportByteLimit].
  tooLarge,

  /// Contains a private key, alone or with a certificate.
  privateKey,

  /// More than one certificate.
  multipleCertificates,

  /// Not a certificate MailBurrow can read: other PEM types, encrypted or
  /// PKCS#7/PKCS#12 files, malformed or trailing data.
  notACertificate,

  /// A server certificate issued by a CA. Choose the CA's root instead.
  caIssuedServerCertificate,

  /// Its validity period has ended.
  expired,

  /// Its validity period hasn't started.
  notYetValid,

  /// Signed with MD5 or SHA-1.
  weakSignature,

  /// RSA key shorter than 2048 bits.
  weakKey,

  /// A key type, curve or signature algorithm MailBurrow doesn't accept.
  unsupportedAlgorithm,

  /// A critical extension MailBurrow doesn't understand.
  unsupportedCriticalExtension,

  /// Marked as a CA but not allowed to sign certificates.
  caCannotSignCertificates,

  /// The TLS engine refused it.
  rejectedByTls,
}

/// What kind of certificate was imported.
enum CertificateKind {
  /// A self-signed certificate authority (a root).
  rootCa,

  /// A certificate authority issued by another CA.
  intermediateCa,

  /// A self-signed server certificate.
  selfSignedServer,
}

/// Details shown on the confirmation screen and in archive settings.
class CertificateDetails {
  CertificateDetails._({
    required this.der,
    required this.kind,
    required this.subject,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
    required this.sha256,
    required this.dnsNames,
    required this.ipAddresses,
    required this.keyDescription,
    required this.signatureAlgorithm,
  });

  /// The certificate's canonical DER bytes: what is trusted and stored.
  final Uint8List der;
  final CertificateKind kind;

  /// Display names, with control and bidi-override characters removed.
  final String subject, issuer;
  final DateTime notBefore, notAfter;

  /// SHA-256 of [der], 32 bytes.
  final Uint8List sha256;
  final List<String> dnsNames, ipAddresses;

  /// For example "EC P-256" or "RSA 4096".
  final String keyDescription;

  /// For example "ECDSA with SHA-256".
  final String signatureAlgorithm;

  bool get isCa => kind != CertificateKind.selfSignedServer;

  /// Fingerprint as upper-case hex pairs joined by colons.
  String get fingerprint => sha256
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  /// True when the PC05 short-lifetime warning applies at [now].
  bool isShortLived(DateTime now) =>
      kind == CertificateKind.selfSignedServer &&
      (notAfter.difference(now.toUtc()) <= shortLivedRemaining ||
          notAfter.difference(notBefore) <= shortLivedTotal);

  /// True when settings should warn that the certificate expires soon.
  bool expiresWithin(Duration window, DateTime now) =>
      notAfter.difference(now.toUtc()) <= window;
}

/// The outcome of reading a picked file.
sealed class CertificateImportResult {
  const CertificateImportResult();
}

class CertificateAccepted extends CertificateImportResult {
  const CertificateAccepted(this.details);
  final CertificateDetails details;
}

class CertificateRejected extends CertificateImportResult {
  const CertificateRejected(this.reason);
  final CertificateRejection reason;
  @override
  String toString() => 'CertificateRejected($reason)';
}

/// Reads one picked certificate file (PEM or DER) and applies every import
/// rule: one X.509 v3 certificate, no private key, a CA (Basic Constraints
/// and key usage checked) or a server certificate whose own signature
/// verifies, accepted algorithms only, within its validity dates at [now],
/// no unknown critical extensions, and accepted by the TLS engine.
///
/// This classifies and screens input; it does not decide whether a server is
/// trusted. Chain, hostname and validity checks at connection time stay with
/// the TLS engine. Never throws for bad input.
///
/// [checkValidity] false is for showing an already saved certificate in
/// settings, where an expired one must still be described; imports always
/// check validity.
CertificateImportResult readCertificateFile(
  List<int> bytes, {
  DateTime? now,
  bool checkValidity = true,
}) {
  if (bytes.length > certificateImportByteLimit) {
    return const CertificateRejected(CertificateRejection.tooLarge);
  }
  try {
    final der = _extractDer(Uint8List.fromList(bytes));
    final details = _parse(
      der,
      (now ?? DateTime.now()).toUtc(),
      checkValidity: checkValidity,
    );
    try {
      SecurityContext(
        withTrustedRoots: false,
      ).setTrustedCertificatesBytes(utf8.encode(_pem(details.der)));
    } on TlsException {
      return const CertificateRejected(CertificateRejection.rejectedByTls);
    }
    return CertificateAccepted(details);
  } on _Reject catch (r) {
    return CertificateRejected(r.reason);
  } on Object {
    // Any parser fault on hostile input is a refusal, never a crash.
    return const CertificateRejected(CertificateRejection.notACertificate);
  }
}

class _Reject implements Exception {
  const _Reject(this.reason);
  final CertificateRejection reason;
}

const _bad = _Reject(CertificateRejection.notACertificate);

// ---- PEM / DER input -----------------------------------------------------------

final _pemBlock = RegExp(
  r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END ([A-Z0-9 ]+)-----',
);

Uint8List _extractDer(Uint8List bytes) {
  if (bytes.isEmpty) throw _bad;
  if (bytes[0] == 0x30) return bytes; // DER; exact length checked by parser.
  String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw _bad;
  }
  if (text.startsWith('\ufeff')) text = text.substring(1);
  if (text.contains('PRIVATE KEY')) {
    throw const _Reject(CertificateRejection.privateKey);
  }
  final blocks = _pemBlock.allMatches(text).toList();
  if (blocks.isEmpty) throw _bad;
  // Nothing but whitespace may sit outside the blocks.
  var outside = text;
  for (final b in blocks.reversed) {
    outside = outside.replaceRange(b.start, b.end, '');
  }
  if (outside.trim().isNotEmpty) throw _bad;
  for (final b in blocks) {
    if (b.group(1) != b.group(3)) throw _bad;
    if (b.group(1) != 'CERTIFICATE') throw _bad;
  }
  if (blocks.length > 1) {
    throw const _Reject(CertificateRejection.multipleCertificates);
  }
  final body = blocks.single.group(2)!;
  if (body.contains(':')) throw _bad; // PEM headers mean encrypted/legacy.
  final b64 = body.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(b64) || b64.length % 4 != 0) {
    throw _bad;
  }
  return base64.decode(b64);
}

String _pem(Uint8List der) {
  final b = base64.encode(der);
  final lines = [
    for (var i = 0; i < b.length; i += 64)
      b.substring(i, i + 64 > b.length ? b.length : i + 64),
  ];
  return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
      '-----END CERTIFICATE-----\n';
}

// ---- Strict DER reader -------------------------------------------------------------

class _Tlv {
  _Tlv(this.bytes, this.tag, this.start, this.end, this.headerStart);
  final Uint8List bytes;
  final int tag, start, end, headerStart;
  Uint8List get content => Uint8List.sublistView(bytes, start, end);
  Uint8List get raw => Uint8List.sublistView(bytes, headerStart, end);
  bool get constructed => tag & 0x20 != 0;

  /// The elements inside this one, which must fill it exactly.
  List<_Tlv> children() {
    if (!constructed) throw _bad;
    final out = <_Tlv>[];
    var p = start;
    while (p < end) {
      final t = _readTlv(bytes, p, end);
      out.add(t);
      p = t.end;
    }
    return out;
  }
}

_Tlv _readTlv(Uint8List b, int p, int limit) {
  if (p + 2 > limit) throw _bad;
  final tag = b[p];
  if (tag & 0x1f == 0x1f) throw _bad; // High tag numbers aren't used here.
  var i = p + 1;
  var len = b[i++];
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    if (n == 0 || n > 3 || i + n > limit) throw _bad; // No indefinite length.
    if (b[i] == 0) throw _bad; // Not minimal.
    len = 0;
    for (var k = 0; k < n; k++) {
      len = (len << 8) | b[i++];
    }
    if (len < 0x80) throw _bad; // Long form only when needed.
  }
  if (i + len > limit) throw _bad;
  return _Tlv(b, tag, i, i + len, p);
}

_Tlv _expect(_Tlv t, int tag) => t.tag == tag ? t : throw _bad;

String _oid(_Tlv t) {
  _expect(t, 0x06);
  final c = t.content;
  if (c.isEmpty || c.last & 0x80 != 0) throw _bad;
  final parts = <int>[];
  var v = 0;
  for (final byte in c) {
    if (v == 0 && byte == 0x80) throw _bad; // Not minimal.
    v = (v << 7) | (byte & 0x7f);
    if (v > 0xffffffff) throw _bad;
    if (byte & 0x80 == 0) {
      parts.add(v);
      v = 0;
    }
  }
  final first = parts.first;
  final head = first < 40
      ? [0, first]
      : first < 80
      ? [1, first - 40]
      : [2, first - 80];
  return [...head, ...parts.skip(1)].join('.');
}

BigInt _uint(_Tlv t, {int maxBytes = 1025}) {
  _expect(t, 0x02);
  final c = t.content;
  if (c.isEmpty || c.length > maxBytes) throw _bad;
  if (c.length > 1 && c[0] == 0 && c[1] & 0x80 == 0) throw _bad;
  if (c[0] & 0x80 != 0) throw _bad; // Negative.
  var v = BigInt.zero;
  for (final byte in c) {
    v = (v << 8) | BigInt.from(byte);
  }
  return v;
}

bool _bool(_Tlv t) {
  _expect(t, 0x01);
  if (t.content.length != 1) throw _bad;
  final v = t.content[0];
  if (v != 0 && v != 0xff) throw _bad;
  return v == 0xff;
}

Uint8List _bitString(_Tlv t, {bool whole = true}) {
  _expect(t, 0x03);
  final c = t.content;
  if (c.isEmpty || c[0] > 7) throw _bad;
  if (whole && c[0] != 0) throw _bad;
  if ((c.length == 1 && c[0] != 0) ||
      (c.length > 1 && c[0] != 0 && c.last & ((1 << c[0]) - 1) != 0)) {
    throw _bad; // DER padding bits must be zero.
  }
  return Uint8List.sublistView(c, 1);
}

DateTime _time(_Tlv t) {
  final s = ascii.decode(t.content, allowInvalid: false);
  final RegExpMatch? m;
  int year;
  if (t.tag == 0x17) {
    m = RegExp(r'^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$').firstMatch(s);
    if (m == null) throw _bad;
    final yy = int.parse(m.group(1)!);
    year = yy < 50 ? 2000 + yy : 1900 + yy;
  } else if (t.tag == 0x18) {
    m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$').firstMatch(s);
    if (m == null) throw _bad;
    year = int.parse(m.group(1)!);
  } else {
    throw _bad;
  }
  final parts = [for (var i = 2; i <= 6; i++) int.parse(m.group(i)!)];
  final d = DateTime.utc(
    year,
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
  );
  if (d.month != parts[0] ||
      d.day != parts[1] ||
      parts[2] > 23 ||
      parts[3] > 59 ||
      parts[4] > 59) {
    throw _bad;
  }
  return d;
}

// ---- Names ---------------------------------------------------------------------------

const _nameLabels = {
  '2.5.4.3': 'CN',
  '2.5.4.10': 'O',
  '2.5.4.11': 'OU',
  '2.5.4.6': 'C',
  '2.5.4.8': 'ST',
  '2.5.4.7': 'L',
};

final _unsafeChars = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e'
  r'\u2060-\u2069\ufeff]',
  unicode: true,
);

/// Removes control, zero-width and bidi-override characters so a name
/// can't disguise itself on screen, and caps its length.
String safeDisplayText(String s) {
  final clean = s.replaceAll(_unsafeChars, '').trim();
  return clean.length > 200 ? '${clean.substring(0, 200)}…' : clean;
}

String _string(_Tlv t) {
  final c = t.content;
  switch (t.tag) {
    case 0x0c: // UTF8String
      return utf8.decode(c);
    case 0x13 || 0x16 || 0x14: // Printable, IA5, Teletex (read as Latin-1)
      return latin1.decode(c);
    case 0x1e: // BMPString
      if (c.length.isOdd) throw _bad;
      return String.fromCharCodes([
        for (var i = 0; i < c.length; i += 2) (c[i] << 8) | c[i + 1],
      ]);
    default:
      throw _bad;
  }
}

String _displayName(_Tlv name) {
  _expect(name, 0x30);
  final parts = <String>[];
  String? cn;
  for (final rdn in name.children()) {
    _expect(rdn, 0x31);
    for (final atv in rdn.children()) {
      final f = _expect(atv, 0x30).children();
      if (f.length != 2) throw _bad;
      final oid = _oid(f[0]);
      final label = _nameLabels[oid];
      if (label == null) continue;
      final value = safeDisplayText(_string(f[1]));
      if (label == 'CN') cn ??= value;
      parts.add('$label=$value');
    }
  }
  return cn ?? (parts.isEmpty ? '(no name)' : parts.join(', '));
}

// ---- Algorithms --------------------------------------------------------------------

const _weakSignatures = {
  '1.2.840.113549.1.1.2', // md2WithRSA
  '1.2.840.113549.1.1.4', // md5WithRSA
  '1.2.840.113549.1.1.5', // sha1WithRSA
  '1.2.840.10045.4.1', // ecdsa-with-SHA1
  '1.2.840.10040.4.3', // dsa-with-sha1
  '1.3.14.3.2.29', // sha1WithRSA (OIW)
};

class _SigAlg {
  const _SigAlg(this.name, this.rsa, this.digest);
  final String name;
  final bool rsa;
  final String digest;
}

const _signatures = {
  '1.2.840.113549.1.1.11': _SigAlg('RSA with SHA-256', true, 'SHA-256'),
  '1.2.840.113549.1.1.12': _SigAlg('RSA with SHA-384', true, 'SHA-384'),
  '1.2.840.113549.1.1.13': _SigAlg('RSA with SHA-512', true, 'SHA-512'),
  '1.2.840.10045.4.3.2': _SigAlg('ECDSA with SHA-256', false, 'SHA-256'),
  '1.2.840.10045.4.3.3': _SigAlg('ECDSA with SHA-384', false, 'SHA-384'),
  '1.2.840.10045.4.3.4': _SigAlg('ECDSA with SHA-512', false, 'SHA-512'),
};

Digest _digest(String name) => switch (name) {
  'SHA-256' => SHA256Digest(),
  'SHA-384' => SHA384Digest(),
  _ => SHA512Digest(),
};

const _digestIds = {
  'SHA-256': '0609608648016503040201',
  'SHA-384': '0609608648016503040202',
  'SHA-512': '0609608648016503040203',
};

_SigAlg _sigAlg(_Tlv algId) {
  final f = _expect(algId, 0x30).children();
  if (f.isEmpty || f.length > 2) throw _bad;
  final oid = _oid(f[0]);
  if (_weakSignatures.contains(oid)) {
    throw const _Reject(CertificateRejection.weakSignature);
  }
  final alg = _signatures[oid];
  if (alg == null) {
    throw const _Reject(CertificateRejection.unsupportedAlgorithm);
  }
  // RSA PKCS#1 takes NULL or absent parameters; ECDSA takes none.
  if (f.length == 2) {
    if (!alg.rsa || f[1].tag != 0x05 || f[1].content.isNotEmpty) throw _bad;
  }
  return alg;
}

class _Key {
  _Key(this.description, this.rsa, this.ec);
  final String description;
  final RSAPublicKey? rsa;
  final ECPublicKey? ec;
}

_Key _publicKey(_Tlv spki) {
  final f = _expect(spki, 0x30).children();
  if (f.length != 2) throw _bad;
  final alg = _expect(f[0], 0x30).children();
  if (alg.isEmpty || alg.length > 2) throw _bad;
  final keyOid = _oid(alg[0]);
  final keyBits = _bitString(f[1]);
  if (keyOid == '1.2.840.113549.1.1.1') {
    if (alg.length == 2 && (alg[1].tag != 0x05 || alg[1].content.isNotEmpty)) {
      throw _bad;
    }
    final seq = _readTlv(keyBits, 0, keyBits.length);
    if (seq.end != keyBits.length) throw _bad;
    final parts = _expect(seq, 0x30).children();
    if (parts.length != 2) throw _bad;
    final n = _uint(parts[0]);
    // Bound public-exponent work before signature verification.
    if (parts[1].content.length > 5) {
      throw const _Reject(CertificateRejection.unsupportedAlgorithm);
    }
    final e = _uint(parts[1], maxBytes: 5);
    final bits = n.bitLength;
    if (bits < 2048) throw const _Reject(CertificateRejection.weakKey);
    if (bits > 8192 || e.bitLength > 32 || e < BigInt.from(3) || e.isEven) {
      throw const _Reject(CertificateRejection.unsupportedAlgorithm);
    }
    return _Key('RSA $bits', RSAPublicKey(n, e), null);
  }
  if (keyOid == '1.2.840.10045.2.1') {
    if (alg.length != 2) throw _bad;
    final curveOid = _oid(alg[1]);
    final (String label, ECDomainParameters curve) = switch (curveOid) {
      '1.2.840.10045.3.1.7' => ('EC P-256', ECCurve_secp256r1()),
      '1.3.132.0.34' => ('EC P-384', ECCurve_secp384r1()),
      '1.3.132.0.35' => ('EC P-521', ECCurve_secp521r1()),
      _ => throw const _Reject(CertificateRejection.unsupportedAlgorithm),
    };
    if (keyBits.isEmpty || keyBits[0] != 0x04) {
      throw const _Reject(CertificateRejection.unsupportedAlgorithm);
    }
    final point = curve.curve.decodePoint(keyBits);
    if (point == null || point.isInfinity) throw _bad;
    return _Key(label, null, ECPublicKey(point, curve));
  }
  throw const _Reject(CertificateRejection.unsupportedAlgorithm);
}

bool _verify(_SigAlg alg, _Key key, Uint8List tbs, Uint8List sig) {
  try {
    if (alg.rsa) {
      if (key.rsa == null) return false;
      final s = RSASigner(_digest(alg.digest), _digestIds[alg.digest]!)
        ..init(false, PublicKeyParameter<RSAPublicKey>(key.rsa!));
      return s.verifySignature(tbs, RSASignature(sig));
    }
    if (key.ec == null) return false;
    final seq = _readTlv(sig, 0, sig.length);
    if (seq.end != sig.length) return false;
    final rs = _expect(seq, 0x30).children();
    if (rs.length != 2) return false;
    final s = ECDSASigner(_digest(alg.digest))
      ..init(false, PublicKeyParameter<ECPublicKey>(key.ec!));
    return s.verifySignature(tbs, ECSignature(_uint(rs[0]), _uint(rs[1])));
  } on Object {
    return false;
  }
}

// ---- Extensions --------------------------------------------------------------------

const _understoodExtensions = {
  '2.5.29.14', // subjectKeyIdentifier
  '2.5.29.15', // keyUsage
  '2.5.29.17', // subjectAltName
  '2.5.29.19', // basicConstraints
  '2.5.29.30', // nameConstraints (non-critical only)
  '2.5.29.31', // cRLDistributionPoints
  '2.5.29.32', // certificatePolicies
  '2.5.29.35', // authorityKeyIdentifier
  '2.5.29.36', // policyConstraints
  '2.5.29.37', // extKeyUsage
  '2.5.29.54', // inhibitAnyPolicy
  '1.3.6.1.5.5.7.1.1', // authorityInfoAccess
  '1.3.6.1.4.1.11129.2.4.2', // certificate transparency SCTs
};

// Refuse unproven critical anchor rules at import. Basic Constraints is
// parsed below. Path-length limits on intermediates below the imported CA
// anchor are enforced; the anchor's own limit (root or intermediate) is not
// applied on Android but is by Apple's trust evaluation. That is disclosed
// before trust and in
// the setup guide and pinned by test/archive_trust_test.dart.
const _criticalAllowed = {
  '2.5.29.15', // keyUsage
  '2.5.29.17', // subjectAltName
  '2.5.29.19', // basicConstraints
};

// ---- Certificate -------------------------------------------------------------------

CertificateDetails _parse(
  Uint8List der,
  DateTime now, {
  bool checkValidity = true,
}) {
  final cert = _readTlv(der, 0, der.length);
  if (cert.headerStart != 0 || cert.end != der.length) throw _bad;
  final top = _expect(cert, 0x30).children();
  // PKCS#1, PKCS#8, SEC1 keys and PKCS#12 files start with a version
  // INTEGER where a certificate has its to-be-signed SEQUENCE.
  if (top.isNotEmpty && top[0].tag == 0x02) {
    throw const _Reject(CertificateRejection.privateKey);
  }
  if (top.length != 3) throw _bad;
  final tbs = _expect(top[0], 0x30);
  final outerAlg = top[1];
  final signature = _bitString(top[2]);

  final f = tbs.children();
  var i = 0;
  if (f.isEmpty || f[0].tag != 0xa0) throw _bad; // v3 only.
  final version = f[i++].children();
  if (version.length != 1 || _uint(version.single) != BigInt.two) throw _bad;
  if (f.length < i + 6) throw _bad;
  _uint(f[i++]); // Serial number: present and well formed.
  final innerAlg = f[i++];
  if (!_sameBytes(innerAlg.raw, outerAlg.raw)) throw _bad;
  final alg = _sigAlg(outerAlg);
  final issuerName = _expect(f[i++], 0x30);
  final validity = _expect(f[i++], 0x30).children();
  if (validity.length != 2) throw _bad;
  final notBefore = _time(validity[0]), notAfter = _time(validity[1]);
  if (!notAfter.isAfter(notBefore)) throw _bad;
  final subjectName = _expect(f[i++], 0x30);
  final key = _publicKey(f[i++]);
  while (i < f.length && (f[i].tag == 0x81 || f[i].tag == 0x82)) {
    i++; // Unique identifiers: ignored.
  }
  if (i >= f.length || f[i].tag != 0xa3) throw _bad; // Extensions required.
  final extWrapper = f[i++].children();
  if (i != f.length || extWrapper.length != 1) throw _bad;
  final extensions = _expect(extWrapper.single, 0x30).children();
  if (extensions.isEmpty) throw _bad;

  bool? caFlag;
  int? keyUsageBits;
  final dns = <String>[], ips = <String>[];
  final seen = <String>{};
  for (final ext in extensions) {
    final e = _expect(ext, 0x30).children();
    if (e.length < 2 || e.length > 3) throw _bad;
    final oid = _oid(e[0]);
    if (!seen.add(oid)) throw _bad; // Duplicate extension.
    var critical = false;
    if (e.length == 3) {
      critical = _bool(e[1]);
      if (!critical) throw _bad; // DER omits a FALSE default.
    }
    final value = _expect(e.last, 0x04).content;
    if (critical && !_criticalAllowed.contains(oid)) {
      throw const _Reject(CertificateRejection.unsupportedCriticalExtension);
    }
    if (!_understoodExtensions.contains(oid)) continue;
    final inner = _readTlv(value, 0, value.length);
    if (inner.end != value.length) throw _bad;
    switch (oid) {
      case '2.5.29.19':
        // SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLen INTEGER OPTIONAL }.
        final bc = _expect(inner, 0x30).children();
        var k = 0;
        caFlag = false;
        if (k < bc.length && bc[k].tag == 0x01) {
          if (!_bool(bc[k])) throw _bad; // DER omits a FALSE default.
          caFlag = true;
          k++;
        }
        if (k < bc.length) {
          if (!caFlag) throw _bad; // pathLen only on a CA.
          _uint(bc[k]);
          k++;
        }
        if (k != bc.length) throw _bad;
      case '2.5.29.15':
        final bits = _bitString(inner, whole: false);
        if (bits.isEmpty) throw _bad;
        keyUsageBits = bits[0];
      case '2.5.29.17':
        for (final gn in _expect(inner, 0x30).children()) {
          if (gn.tag == 0x82) {
            dns.add(safeDisplayText(ascii.decode(gn.content)));
          } else if (gn.tag == 0x87) {
            final c = gn.content;
            if (c.length == 4 || c.length == 16) {
              ips.add(InternetAddress.fromRawAddress(c).address);
            } else {
              throw _bad;
            }
          }
        }
    }
  }

  final selfIssued = _sameBytes(issuerName.raw, subjectName.raw);
  final selfSigned = selfIssued && _verify(alg, key, tbs.raw, signature);

  final CertificateKind kind;
  if (caFlag == true) {
    // keyCertSign is bit 5 (0x04 in the first byte).
    if (keyUsageBits != null && keyUsageBits & 0x04 == 0) {
      throw const _Reject(CertificateRejection.caCannotSignCertificates);
    }
    kind = selfSigned ? CertificateKind.rootCa : CertificateKind.intermediateCa;
  } else if (selfSigned) {
    kind = CertificateKind.selfSignedServer;
  } else {
    throw const _Reject(CertificateRejection.caIssuedServerCertificate);
  }

  if (checkValidity && now.isAfter(notAfter)) {
    throw const _Reject(CertificateRejection.expired);
  }
  if (checkValidity && now.isBefore(notBefore)) {
    throw const _Reject(CertificateRejection.notYetValid);
  }

  return CertificateDetails._(
    der: Uint8List.fromList(der).asUnmodifiableView(),
    kind: kind,
    subject: _displayName(subjectName),
    issuer: _displayName(issuerName),
    notBefore: notBefore,
    notAfter: notAfter,
    sha256: SHA256Digest().process(der).asUnmodifiableView(),
    dnsNames: List.unmodifiable(dns),
    ipAddresses: List.unmodifiable(ips),
    keyDescription: key.description,
    signatureAlgorithm: alg.name,
  );
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
