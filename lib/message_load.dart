import 'dart:async';

class MessageLoadCancelled implements Exception {
  const MessageLoadCancelled();
}

/// Cancellation belongs to one reader, never to its shared connection.
class MessageLoad {
  static final _zoneKey = Object();
  static MessageLoad? get current => Zone.current[_zoneKey] as MessageLoad?;

  final _cancelled = Completer<void>();
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) throw const MessageLoadCancelled();
  }

  void addCancelListener(void Function() listener) {
    _listeners.add(listener);
    if (isCancelled) listener();
  }

  void removeCancelListener(void Function() listener) =>
      _listeners.remove(listener);

  Future<T> run<T>(Future<T> Function() operation) {
    throwIfCancelled();
    return runZoned(() => wait(operation()), zoneValues: {_zoneKey: this});
  }

  Future<T> wait<T>(Future<T> operation) async {
    try {
      final value = await Future.any<T>([
        operation,
        _cancelled.future.then<T>((_) => throw const MessageLoadCancelled()),
      ]);
      throwIfCancelled();
      return value;
    } catch (_) {
      throwIfCancelled();
      rethrow;
    }
  }
}
