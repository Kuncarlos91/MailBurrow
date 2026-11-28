import 'dart:convert';
import 'dart:io';

import 'archive_api.dart' show archiveConnectTimeout;
import 'certificate_import.dart';

/// An extra certificate one saved archive trusts for HTTPS, in addition to
/// the platform's public certificate authorities.
///
/// The certificate is a trust anchor, not a pin: the server's chain, validity
/// dates and hostname are still checked by the TLS engine, and publicly
/// trusted certificates keep working. It applies only to the archive whose
/// connection is created with it; nothing changes the default context or the
/// device's trust store.
///
/// Instances hold one certificate in canonical DER form. Checking what may
/// be imported (one certificate, no private key, accepted types and
/// algorithms) happens before an [ArchiveTrust] is created.
class ArchiveTrust {
  ArchiveTrust(List<int> der, {DateTime Function()? clock})
    : der = List.unmodifiable(der),
      _clock = clock ?? DateTime.now {
    if (der.isEmpty) throw ArgumentError('Empty certificate');
  }

  /// The certificate's DER bytes.
  final List<int> der;
  final DateTime Function() _clock;
  Duration get remainingValidity => notAfter.difference(_clock().toUtc());

  String get _pem {
    final b64 = base64.encode(der);
    final lines = [
      for (var i = 0; i < b64.length; i += 64)
        b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
    ];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
        '-----END CERTIFICATE-----\n';
  }

  late final CertificateDetails _details = switch (readCertificateFile(
    der,
    checkValidity: false,
  )) {
    CertificateAccepted(:final details) => details,
    CertificateRejected() => throw const HandshakeException(
      'Configured certificate cannot be used.',
    ),
  };

  DateTime get notAfter => _details.notAfter;

  /// Enforce the imported anchor's dates even when a TLS engine treats
  /// trust-anchor validity differently, including on pooled connections.
  void validateForRequest({DateTime? now}) {
    final instant = (now ?? _clock()).toUtc();
    if (instant.isBefore(_details.notBefore) ||
        !instant.isBefore(_details.notAfter)) {
      throw const HandshakeException(
        'Configured certificate is outside its validity period.',
      );
    }
  }

  /// A new TLS context: the public roots plus this certificate.
  SecurityContext createContext() {
    validateForRequest();
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(utf8.encode(_pem));
  }
}

/// Creates every HTTPS client MailBurrow uses to reach an archive.
///
/// With no [context] the client uses the platform's default trust. Pass the
/// context from [ArchiveTrust.createContext] for an archive with its own
/// certificate. This is the only place archive clients are created. A source
/// guard detects additional constructors; TLS regressions separately check
/// that callers supply the correct context and do not share trust between
/// profiles.
HttpClient createArchiveHttpClient(SecurityContext? context) =>
    HttpClient(context: context)..connectionTimeout = archiveConnectTimeout;
