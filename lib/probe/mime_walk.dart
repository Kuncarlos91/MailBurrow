/// A small, bounded MIME walker for the phone probe. PROBE ONLY.
///
/// It finds the first readable text and HTML bodies, counts inline
/// resources and records structural problems instead of throwing. It shows
/// what a dependency-free reader would cost; it is not the backend parser.
library;

import 'dart:convert';
import 'dart:typed_data';

class MimeLimits {
  const MimeLimits({
    this.maxDepth = 32,
    this.maxParts = 500,
    this.maxHeaderBytes = 256 * 1024,
    this.maxDecodedBytes = 64 * 1024 * 1024,
  });
  final int maxDepth, maxParts, maxHeaderBytes, maxDecodedBytes;
}

class MimeSummary {
  int parts = 0;
  int maxDepth = 0;
  int inlineParts = 0;
  int inlineBytes = 0;
  int decodedBytes = 0;
  String? text;
  String? html;
  final problems = <String>{};

  Map<String, Object?> toJson() => {
    'parts': parts,
    'depth': maxDepth,
    'inlineParts': inlineParts,
    'inlineBytes': inlineBytes,
    'decodedBytes': decodedBytes,
    'textChars': text?.length ?? 0,
    'htmlChars': html?.length ?? 0,
    'problems': problems.toList()..sort(),
  };
}

class _Stop implements Exception {
  const _Stop();
}

MimeSummary walkMime(Uint8List message, {MimeLimits limits = const MimeLimits()}) {
  final summary = MimeSummary();
  try {
    _walk(message, 0, summary, limits);
  } on _Stop {
    // A limit was recorded in summary.problems.
  }
  return summary;
}

int indexOf(Uint8List hay, List<int> needle, int start) {
  if (needle.isEmpty) return start;
  final first = needle[0];
  final last = hay.length - needle.length;
  outer:
  for (var i = start; i <= last; i++) {
    if (hay[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

final _crlfcrlf = latin1.encode('\r\n\r\n');
final _lflf = latin1.encode('\n\n');

void _walk(Uint8List part, int depth, MimeSummary summary, MimeLimits limits) {
  if (depth > summary.maxDepth) summary.maxDepth = depth;
  if (depth > limits.maxDepth) {
    summary.problems.add('depth-limit');
    throw const _Stop();
  }
  if (++summary.parts > limits.maxParts) {
    summary.problems.add('part-limit');
    throw const _Stop();
  }
  var split = indexOf(part, _crlfcrlf, 0);
  var bodyStart = split + 4;
  final lf = indexOf(part, _lflf, 0);
  if (lf >= 0 && (split < 0 || lf < split)) {
    split = lf;
    bodyStart = lf + 2;
  }
  if (split < 0) {
    summary.problems.add('no-header-end');
    split = part.length;
    bodyStart = part.length;
  }
  if (split > limits.maxHeaderBytes) {
    summary.problems.add('header-limit');
    return;
  }
  final headers = _headers(
    latin1.decode(Uint8List.sublistView(part, 0, split)),
    summary,
  );
  final body = Uint8List.sublistView(part, bodyStart);
  final type = _contentType(headers['content-type'] ?? 'text/plain');
  final mime = type.value;
  if (mime.startsWith('multipart/')) {
    final boundary = type.params['boundary'];
    if (boundary == null || boundary.isEmpty) {
      summary.problems.add('missing-boundary');
      return;
    }
    for (final child in _children(body, boundary, summary)) {
      _walk(child, depth + 1, summary, limits);
    }
    return;
  }
  final decoded = _decode(
    body,
    (headers['content-transfer-encoding'] ?? '').trim().toLowerCase(),
    summary,
  );
  summary.decodedBytes += decoded.length;
  if (summary.decodedBytes > limits.maxDecodedBytes) {
    summary.problems.add('decoded-limit');
    throw const _Stop();
  }
  final disposition = (headers['content-disposition'] ?? '').toLowerCase();
  final attachment = disposition.startsWith('attachment');
  if (!attachment && mime == 'text/plain' && summary.text == null) {
    summary.text = _charset(decoded, type.params['charset'], summary);
  } else if (!attachment && mime == 'text/html' && summary.html == null) {
    summary.html = _charset(decoded, type.params['charset'], summary);
  } else if (!attachment &&
      (headers.containsKey('content-id') || disposition.startsWith('inline'))) {
    summary
      ..inlineParts += 1
      ..inlineBytes += decoded.length;
  }
}

Map<String, String> _headers(String block, MimeSummary summary) {
  final out = <String, String>{};
  String? name;
  final value = StringBuffer();
  void flush() {
    if (name != null) out.putIfAbsent(name!, () => value.toString().trim());
    name = null;
    value.clear();
  }

  for (final line in const LineSplitter().convert(block)) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && name != null) {
      value
        ..write(' ')
        ..write(line.trim());
      continue;
    }
    flush();
    final colon = line.indexOf(':');
    if (colon <= 0) {
      summary.problems.add('bad-header-line');
      continue;
    }
    name = line.substring(0, colon).trim().toLowerCase();
    value.write(line.substring(colon + 1));
  }
  flush();
  return out;
}

class _Type {
  const _Type(this.value, this.params);
  final String value;
  final Map<String, String> params;
}

_Type _contentType(String header) {
  final pieces = header.split(';');
  final params = <String, String>{};
  for (final piece in pieces.skip(1)) {
    final eq = piece.indexOf('=');
    if (eq <= 0) continue;
    var value = piece.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    params[piece.substring(0, eq).trim().toLowerCase()] = value;
  }
  return _Type(pieces.first.trim().toLowerCase(), params);
}

/// Splits a multipart body at `--boundary` lines.
List<Uint8List> _children(Uint8List body, String boundary, MimeSummary summary) {
  final delimiter = latin1.encode('--$boundary');
  final children = <Uint8List>[];
  var at = 0;
  int? partStart;
  var closed = false;
  while (true) {
    final hit = indexOf(body, delimiter, at);
    if (hit < 0) break;
    final lineStart = hit == 0 || body[hit - 1] == 0x0a;
    final next = hit + delimiter.length;
    if (!lineStart) {
      at = next;
      continue;
    }
    if (partStart != null) {
      var end = hit;
      if (end > partStart && body[end - 1] == 0x0a) end--;
      if (end > partStart && body[end - 1] == 0x0d) end--;
      children.add(Uint8List.sublistView(body, partStart, end));
    }
    if (next + 1 < body.length && body[next] == 0x2d && body[next + 1] == 0x2d) {
      closed = true;
      break;
    }
    var start = next;
    while (start < body.length && body[start] != 0x0a) {
      start++;
    }
    partStart = start + 1 > body.length ? body.length : start + 1;
    at = partStart;
  }
  if (!closed) {
    summary.problems.add('unclosed-multipart');
    if (partStart != null && partStart < body.length) {
      children.add(Uint8List.sublistView(body, partStart));
    }
  }
  return children;
}

Uint8List _decode(Uint8List body, String encoding, MimeSummary summary) {
  if (encoding == 'base64') return _base64(body, summary);
  if (encoding == 'quoted-printable') return _quotedPrintable(body);
  return body;
}

int _base64Value(int c) {
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26;
  if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52;
  if (c == 0x2b) return 62;
  if (c == 0x2f) return 63;
  return -1;
}

Uint8List _base64(Uint8List body, MimeSummary summary) {
  final out = Uint8List(body.length * 3 ~/ 4 + 3);
  var length = 0;
  var bits = 0;
  var count = 0;
  var invalid = false;
  for (final c in body) {
    if (c == 0x3d) break;
    final value = _base64Value(c);
    if (value < 0) {
      if (c != 0x0d && c != 0x0a && c != 0x20 && c != 9) invalid = true;
      continue;
    }
    bits = bits << 6 | value;
    if (++count == 4) {
      out[length++] = bits >> 16 & 0xff;
      out[length++] = bits >> 8 & 0xff;
      out[length++] = bits & 0xff;
      bits = 0;
      count = 0;
    }
  }
  if (count == 2) {
    out[length++] = bits >> 4 & 0xff;
  } else if (count == 3) {
    out[length++] = bits >> 10 & 0xff;
    out[length++] = bits >> 2 & 0xff;
  } else if (count == 1) {
    invalid = true;
  }
  if (invalid) summary.problems.add('bad-base64');
  return Uint8List.sublistView(out, 0, length);
}

int _hex(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

Uint8List _quotedPrintable(Uint8List body) {
  final out = Uint8List(body.length);
  var length = 0;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c != 0x3d) {
      out[length++] = c;
      continue;
    }
    if (i + 1 < body.length && body[i + 1] == 0x0a) {
      i += 1;
      continue;
    }
    if (i + 2 < body.length && body[i + 1] == 0x0d && body[i + 2] == 0x0a) {
      i += 2;
      continue;
    }
    final high = i + 1 < body.length ? _hex(body[i + 1]) : -1;
    final low = i + 2 < body.length ? _hex(body[i + 2]) : -1;
    if (high >= 0 && low >= 0) {
      out[length++] = high << 4 | low;
      i += 2;
    } else {
      out[length++] = c;
    }
  }
  return Uint8List.sublistView(out, 0, length);
}

String _charset(Uint8List bytes, String? charset, MimeSummary summary) {
  switch ((charset ?? 'us-ascii').toLowerCase()) {
    case 'utf-8':
    case 'utf8':
      return utf8.decode(bytes, allowMalformed: true);
    case 'us-ascii':
    case 'iso-8859-1':
    case 'latin1':
    case 'windows-1252':
      return latin1.decode(bytes);
    default:
      summary.problems.add('unknown-charset');
      return utf8.decode(bytes, allowMalformed: true);
  }
}
