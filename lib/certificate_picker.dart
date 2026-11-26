import 'package:flutter/services.dart';

import 'certificate_import.dart' show certificateImportByteLimit;

/// The outcome of asking the user for a certificate file.
sealed class CertificatePick {
  const CertificatePick();
}

/// The chosen file's bytes, at most [certificateImportByteLimit].
class CertificateFile extends CertificatePick {
  const CertificateFile(this.bytes);
  final Uint8List bytes;
}

/// The user closed the picker without choosing a file.
class CertificatePickCancelled extends CertificatePick {
  const CertificatePickCancelled();
}

/// The chosen file is larger than [certificateImportByteLimit]; only that
/// much (plus one byte) was read.
class CertificateFileTooLarge extends CertificatePick {
  const CertificateFileTooLarge();
}

/// The picker couldn't be shown or the file couldn't be read.
class CertificatePickFailed extends CertificatePick {
  const CertificatePickFailed();
}

/// Shows a file picker and reads the chosen certificate file.
typedef CertificateFilePicker = Future<CertificatePick> Function();

const _channel = MethodChannel('mailburrow/certificate_picker');

/// The platform document picker. The native side reads the original file
/// directly, at most [certificateImportByteLimit] plus one byte, and keeps
/// no copy, no lasting permission and no record of the file or its name.
Future<CertificatePick> pickCertificateFile() async {
  try {
    final result = await _channel.invokeMapMethod<String, Object?>('pick', {
      'limit': certificateImportByteLimit,
    });
    switch (result?['status']) {
      case 'picked':
        final bytes = result?['bytes'];
        if (bytes is! Uint8List || bytes.isEmpty) {
          return const CertificatePickFailed();
        }
        return bytes.length > certificateImportByteLimit
            ? const CertificateFileTooLarge()
            : CertificateFile(bytes);
      case 'too_large':
        return const CertificateFileTooLarge();
      case 'cancelled':
        return const CertificatePickCancelled();
      default:
        return const CertificatePickFailed();
    }
  } on PlatformException {
    return const CertificatePickFailed();
  } on MissingPluginException {
    return const CertificatePickFailed();
  }
}
