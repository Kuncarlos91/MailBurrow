import 'dart:async';

const maxAttachmentDownloadBytes = 50 * 1024 * 1024;
const attachmentDownloadDeadline = Duration(minutes: 2);
const attachmentDownloadIdleTimeout = Duration(seconds: 30);

class AttachmentTooLarge implements Exception {
  const AttachmentTooLarge();
}

class AttachmentDownloadCancelled implements Exception {
  const AttachmentDownloadCancelled();
}

// A controller belongs to one transfer, never the shared archive connection.
class AttachmentDownload {
  final _listeners = <void Function()>{};
  Exception? _failure;

  bool get isStopped => _failure != null;

  void cancel() => _stop(const AttachmentDownloadCancelled());

  void expire() => _stop(TimeoutException('Attachment download deadline'));

  void _stop(Exception failure) {
    if (isStopped) return;
    _failure = failure;
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void throwIfStopped() {
    if (_failure case final failure?) throw failure;
  }

  void addStopListener(void Function() listener) {
    _listeners.add(listener);
    if (isStopped) listener();
  }

  void removeStopListener(void Function() listener) =>
      _listeners.remove(listener);

  // Observe both futures, including a late network error after cancellation.
  Future<T> wait<T>(Future<T> operation) async {
    final interrupted = Completer<T>();
    void stop() => interrupted.completeError(_failure!);
    final resultFuture = Future.any<T>([operation, interrupted.future]);
    addStopListener(stop);
    try {
      final result = await resultFuture;
      throwIfStopped();
      return result;
    } catch (_) {
      throwIfStopped();
      rethrow;
    } finally {
      removeStopListener(stop);
    }
  }
}
