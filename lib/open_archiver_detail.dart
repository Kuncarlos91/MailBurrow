import 'dart:convert';
import 'dart:typed_data';

import 'archive_errors.dart';

/// Reads an Open Archiver message response (`GET /archived-emails/:id`) as it
/// streams in, without building the whole JSON tree.
///
/// Open Archiver v0.6.2 sends the stored `.eml` as `raw`, a Node Buffer
/// serialized as `{"type":"Buffer","data":[...]}`: one decimal number per
/// byte, about 3.4 times the message on the wire. Every other field is
/// built normally. Limits are enforced while reading, before memory is
/// committed: [maxRawBytes] bounds the decoded message and [maxOtherBytes]
/// bounds all other JSON text. Exceeding either throws
/// [ArchiveResponseTooLarge]; malformed JSON throws [FormatException].
class OpenArchiverDetailReader {
  OpenArchiverDetailReader({
    required this.maxRawBytes,
    required this.maxOtherBytes,
  }) {
    if (maxRawBytes < 1 || maxOtherBytes < 1) {
      throw ArgumentError('Invalid detail limits');
    }
  }

  final int maxRawBytes, maxOtherBytes;

  // Containers being built (Map or List), and for maps the pending key.
  final _stack = <Object>[];
  final _keys = <String?>[];
  Object? _root;
  var _state = _State.value;
  var _otherBytes = 0;
  var _values = 0;

  // String state. Raw UTF-8 bytes are kept, escapes included, and decoded
  // once at the closing quote.
  final _string = BytesBuilder(copy: false);
  var _escape = false;
  var _stringIsKey = false;

  // Number and literal state.
  final _number = StringBuffer();
  String _literal = '';
  var _literalAt = 0;

  // `raw.data` bytes.
  Uint8List _raw = Uint8List(64 * 1024);
  var _rawLength = 0;
  var _rawValue = -1;
  var _rawNumberEnded = false;
  var _sawRaw = false;

  static const _whitespace = {0x20, 0x09, 0x0a, 0x0d};

  Never _fail() => throw const FormatException('Invalid message response');

  void add(List<int> chunk) {
    var i = 0;
    while (i < chunk.length) {
      final b = chunk[i];
      if (_state == _State.rawArray) {
        _rawByte(b);
        i++;
        continue;
      }
      if (++_otherBytes > maxOtherBytes) throw const ArchiveResponseTooLarge();
      switch (_state) {
        case _State.value:
        case _State.valueOrEnd:
          if (_whitespace.contains(b)) break;
          if (b == 0x5d && _state == _State.valueOrEnd) {
            _closeContainer(isList: true);
            break;
          }
          _startValue(b);
        case _State.keyOrEnd:
        case _State.key:
          if (_whitespace.contains(b)) break;
          if (b == 0x7d && _state == _State.keyOrEnd) {
            _closeContainer(isList: false);
            break;
          }
          if (b != 0x22) _fail();
          _stringIsKey = true;
          _state = _State.string;
        case _State.colon:
          if (_whitespace.contains(b)) break;
          if (b != 0x3a) _fail();
          _state = _State.value;
        case _State.afterValue:
          if (_whitespace.contains(b)) break;
          final top = _stack.isEmpty ? null : _stack.last;
          if (b == 0x2c && top != null) {
            _state = top is Map ? _State.key : _State.value;
          } else if (b == 0x7d && top is Map) {
            _closeContainer(isList: false);
          } else if (b == 0x5d && top is List) {
            _closeContainer(isList: true);
          } else {
            _fail();
          }
        case _State.string:
          if (_escape) {
            _escape = false;
            _string.addByte(b);
          } else if (b == 0x22) {
            _finishString();
          } else if (b == 0x5c) {
            _escape = true;
            _string.addByte(b);
          } else if (b < 0x20) {
            _fail();
          } else {
            _string.addByte(b);
          }
        case _State.number:
          if ((b >= 0x30 && b <= 0x39) ||
              b == 0x2d ||
              b == 0x2b ||
              b == 0x2e ||
              b == 0x65 ||
              b == 0x45) {
            _number.writeCharCode(b);
          } else {
            _finishNumber();
            // Reprocess this byte as the character after the number.
            _otherBytes--;
            continue;
          }
        case _State.literal:
          if (b != _literal.codeUnitAt(_literalAt)) _fail();
          if (++_literalAt == _literal.length) {
            _emit(switch (_literal) {
              'true' => true,
              'false' => false,
              _ => null,
            });
          }
        case _State.done:
          if (!_whitespace.contains(b)) _fail();
        case _State.rawArray:
          break;
      }
      i++;
    }
  }

  bool get _atRawData =>
      _stack.length == 2 &&
      _stack[0] is Map &&
      _stack[1] is Map &&
      _keys[0] == 'raw' &&
      _keys[1] == 'data';

  void _startValue(int b) {
    // Bound heap amplification from many tiny values and nested containers.
    if (++_values > 100000 || _stack.length >= 64) {
      throw const ArchiveResponseTooLarge();
    }
    if (b == 0x7b) {
      _stack.add(<String, dynamic>{});
      _keys.add(null);
      _state = _State.keyOrEnd;
    } else if (b == 0x5b) {
      if (_atRawData) {
        if (_sawRaw) _fail();
        _sawRaw = true;
        _state = _State.rawArray;
      } else {
        _stack.add(<dynamic>[]);
        _keys.add(null);
        _state = _State.valueOrEnd;
      }
    } else if (b == 0x22) {
      _stringIsKey = false;
      _state = _State.string;
    } else if (b == 0x2d || (b >= 0x30 && b <= 0x39)) {
      _number
        ..clear()
        ..writeCharCode(b);
      _state = _State.number;
    } else if (b == 0x74 || b == 0x66 || b == 0x6e) {
      _literal = b == 0x74
          ? 'true'
          : b == 0x66
          ? 'false'
          : 'null';
      _literalAt = 1;
      _state = _State.literal;
    } else {
      _fail();
    }
  }

  void _closeContainer({required bool isList}) {
    final top = _stack.removeLast();
    _keys.removeLast();
    if ((top is List) != isList) _fail();
    _emit(top);
  }

  void _emit(Object? value) {
    if (_stack.isEmpty) {
      if (_root != null) _fail();
      _root = value;
      _state = _State.done;
      return;
    }
    final top = _stack.last;
    if (top is Map<String, dynamic>) {
      top[_keys.last!] = value;
    } else {
      (top as List<dynamic>).add(value);
    }
    _state = _State.afterValue;
  }

  void _finishString() {
    final text = _unescape(utf8.decode(_string.takeBytes()));
    if (_stringIsKey) {
      if ((_stack.last as Map).containsKey(text)) _fail();
      _keys[_keys.length - 1] = text;
      _state = _State.colon;
    } else {
      _emit(text);
    }
  }

  void _finishNumber() {
    final text = _number.toString();
    final value = int.tryParse(text) ?? double.tryParse(text);
    if (value == null ||
        !RegExp(r'^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$').hasMatch(text)) {
      _fail();
    }
    _emit(value);
  }

  void _rawByte(int b) {
    if (b >= 0x30 && b <= 0x39) {
      if (_rawNumberEnded || _rawValue == 0) _fail();
      _rawValue = (_rawValue < 0 ? 0 : _rawValue * 10) + b - 0x30;
      if (_rawValue > 255) _fail();
    } else if (b == 0x2c) {
      _pushRaw();
    } else if (b == 0x5d) {
      if (_rawValue >= 0 || _rawLength > 0) _pushRaw();
      // A placeholder: the bytes are returned separately.
      _emit(true);
    } else if (_whitespace.contains(b)) {
      if (_rawValue >= 0) _rawNumberEnded = true;
    } else {
      _fail();
    }
  }

  void _pushRaw() {
    if (_rawValue < 0) _fail();
    if (_rawLength >= maxRawBytes) throw const ArchiveResponseTooLarge();
    if (_rawLength == _raw.length) {
      var next = _raw.length * 2;
      if (next > maxRawBytes) next = maxRawBytes;
      _raw = Uint8List(next)..setRange(0, _rawLength, _raw);
    }
    _raw[_rawLength++] = _rawValue;
    _rawValue = -1;
    _rawNumberEnded = false;
  }

  /// Finishes reading. Returns every field except `raw`, and the raw bytes.
  ({Map<String, dynamic> fields, Uint8List raw}) close() {
    if (_state != _State.done) _fail();
    final root = _root;
    if (root is! Map<String, dynamic>) _fail();
    final fields = root;
    final raw = fields.remove('raw');
    if (!_sawRaw || raw is! Map<String, dynamic> || raw['type'] != 'Buffer') {
      _fail();
    }
    return (fields: fields, raw: Uint8List.sublistView(_raw, 0, _rawLength));
  }
}

enum _State {
  value,
  valueOrEnd,
  key,
  keyOrEnd,
  colon,
  afterValue,
  string,
  number,
  literal,
  rawArray,
  done,
}

String _unescape(String text) {
  if (!text.contains(r'\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c != 0x5c) {
      out.writeCharCode(c);
      continue;
    }
    if (++i >= text.length) {
      throw const FormatException('Invalid message response');
    }
    switch (text[i]) {
      case '"':
        out.write('"');
      case r'\':
        out.write(r'\');
      case '/':
        out.write('/');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'u':
        if (i + 4 >= text.length) {
          throw const FormatException('Invalid message response');
        }
        final hex = text.substring(i + 1, i + 5);
        final unit = int.tryParse(hex, radix: 16);
        if (unit == null || !RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
          throw const FormatException('Invalid message response');
        }
        out.writeCharCode(unit);
        i += 4;
      default:
        throw const FormatException('Invalid message response');
    }
  }
  return out.toString();
}
