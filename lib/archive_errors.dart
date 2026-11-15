import 'dart:async';
import 'dart:io';

class ArchiveResponseTooLarge implements Exception {
  const ArchiveResponseTooLarge();
}

/// A message the app declines to open; [reason] is shown to the user.
class ArchiveMessageRefused implements Exception {
  const ArchiveMessageRefused(this.reason);
  final String reason;
}

/// A search the app declines to send; [reason] is shown to the user.
class ArchiveSearchRefused implements Exception {
  const ArchiveSearchRefused(this.reason);
  final String reason;
}

/// A response that does not match the contract a backend was tested
/// against, such as a newer server version. [server] names the server type
/// and [testedVersion] the version MailBurrow is tested with.
class ArchiveUnsupportedResponse implements Exception {
  const ArchiveUnsupportedResponse(this.server, this.testedVersion);
  final String server, testedVersion;
}

/// A known folder-list state that can recover without changing versions.
class ArchiveFoldersUnavailable implements Exception {
  const ArchiveFoldersUnavailable({this.loading = false});
  final bool loading;
}

class ArchiveFailure implements Exception {
  const ArchiveFailure(this.status, {this.credential = 'API key'});
  final int status;

  /// What the failing server calls its credential, for 401 and 403 wording.
  final String credential;
}

String readableError(Object error) {
  if (error is ArchiveResponseTooLarge) {
    return 'This server response is too large for the app preview. Open your archive website to view it.';
  }
  if (error is ArchiveMessageRefused) return error.reason;
  if (error is ArchiveSearchRefused) return error.reason;
  if (error is ArchiveUnsupportedResponse) {
    return "${error.server} returned a response MailBurrow doesn't recognize. MailBurrow was tested with ${error.server} ${error.testedVersion}. Check the server type, address and ${error.server} version, then retry.";
  }
  if (error is ArchiveFoldersUnavailable) {
    return error.loading
        ? 'The archive is still loading its folders. Wait a moment and retry.'
        : 'The archive could not load its folders. Retry or check the server.';
  }
  if (error is ArchiveFailure) {
    return switch (error.status) {
      401 => 'Your ${error.credential} was not accepted.',
      403 =>
        'Your ${error.credential} does not have permission for this request.',
      404 => 'Archive API or message unavailable.',
      429 => 'Too many requests. Wait and retry.',
      _ => 'The server could not complete the request.',
    };
  }
  if (error is HandshakeException) {
    return 'The server certificate could not be verified. Check the HTTPS server configuration.';
  }
  if (error is TimeoutException) {
    return 'The server took too long to respond. Check your connection and retry.';
  }
  if (error is FormatException || error is TypeError) {
    return 'The server returned an unexpected response. Check that it runs a supported version of its archive software.';
  }
  return 'Unable to connect. Check your HTTPS address and private network.';
}
