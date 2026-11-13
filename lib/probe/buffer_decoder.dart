/// Decoders for Open Archiver's Buffer-as-JSON `raw` field. PROBE ONLY.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Thrown when decoded bytes would exceed the configured cap.
class ProbeLimitExceeded implements Exception {
  const ProbeLimitExceeded(this.limit);
  final int limit;
  @override
  String toString() => 'ProbeLimitExceeded($limit)';
}

/// The straightforward approach: decode the whole response, then copy
/// `raw.data` into bytes. Holds the response text, the parsed tree and the
/// boxed number list in memory at once.
Uint8List naiveDecode(Uint8List wire) {
  final json = jsonDecode(utf8.decode(wire)) as Map<String, dynamic>;
  final raw = json['raw'] as Map<String, dynamic>;
  final data = raw['data'] as List<dynamic>;
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final value = data[i];
    if (value is! int || value < 0 || value > 255) {
      throw const FormatException('Invalid Buffer byte');
    }
    out[i] = value;
  }
  return out;
}

/// Streams response chunks straight into bytes without building the JSON
/// tree. It finds the first `"data":[` and parses decimal bytes until `]`.
///
/// The probe controls the wire format; a backend would need a real
/// streaming JSON reader that also checks `raw.type` and key placement.
class BufferArrayDecoder {
  BufferArrayDecoder({required this.maxBytes});

  /// Decoded byte cap; adding past it throws [ProbeLimitExceeded].
  final int maxBytes;

  static final _marker = latin1.encode('"data":[');
  int _matched = 0;
  bool _inArray = false;
  bool _done = false;
  int _value = -1;
  Uint8List _out = Uint8List(64 * 1024);
  int _length = 0;

  /// Wire bytes consumed so far.
  int consumed = 0;

  bool get done => _done;

  void _emit() {
    if (_value < 0) throw const FormatException('Empty Buffer element');
    if (_length >= maxBytes) throw ProbeLimitExceeded(maxBytes);
    if (_length == _out.length) {
      var next = _out.length * 2;
      if (next > maxBytes) next = maxBytes;
      _out = Uint8List(next)..setRange(0, _length, _out);
    }
    _out[_length++] = _value;
    _value = -1;
  }

  void add(List<int> chunk) {
    for (var i = 0; i < chunk.length; i++) {
      if (_done) return;
      consumed++;
      final byte = chunk[i];
      if (!_inArray) {
        if (byte == _marker[_matched]) {
          if (++_matched == _marker.length) _inArray = true;
        } else {
          // Only '"' repeats inside the marker.
          _matched = byte == 0x22 ? 1 : 0;
        }
        continue;
      }
      if (byte >= 0x30 && byte <= 0x39) {
        _value = (_value < 0 ? 0 : _value * 10) + byte - 0x30;
        if (_value > 255) throw const FormatException('Invalid Buffer byte');
      } else if (byte == 0x2c) {
        _emit();
      } else if (byte == 0x5d) {
        if (_value >= 0 || _length > 0) _emit();
        _done = true;
      } else if (byte != 0x20 && byte != 0x0a && byte != 0x0d && byte != 9) {
        throw const FormatException('Unexpected Buffer character');
      }
    }
  }

  Uint8List finish() {
    if (!_done) throw const FormatException('Buffer array not closed');
    return Uint8List.sublistView(_out, 0, _length);
  }
}

/// Feeds [wire] to a [BufferArrayDecoder] in [chunkSize] slices, as a
/// network stream would.
Uint8List streamDecode(
  Uint8List wire, {
  required int maxBytes,
  int chunkSize = 64 * 1024,
}) {
  final decoder = BufferArrayDecoder(maxBytes: maxBytes);
  for (var at = 0; at < wire.length && !decoder.done; at += chunkSize) {
    final end = at + chunkSize < wire.length ? at + chunkSize : wire.length;
    decoder.add(Uint8List.sublistView(wire, at, end));
  }
  return decoder.finish();
}
