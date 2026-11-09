import 'dart:async';
import 'dart:io';

class ArchiveResponseTooLarge implements Exception {
  const ArchiveResponseTooLarge();
}

class ArchiveFailure implements Exception {
  const ArchiveFailure(this.status);
  final int status;
}

String readableError(Object error) {
  if (error is ArchiveResponseTooLarge) {
    return 'This server response is too large for the app preview. Open your archive website to view it.';
  }
  if (error is ArchiveFailure) {
    return switch (error.status) {
      401 => 'Your API key was not accepted.',
      403 => 'Your API key does not have permission for this request.',
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
    return 'The server returned an unexpected response. Check that it supports the Mail-Archiver API.';
  }
  return 'Unable to connect. Check your HTTPS address and private network.';
}
