import 'dart:convert';
import 'dart:typed_data';

/// Limits for [readMimeBodies], each checked before the work it bounds.
class MimeBodyLimits {
  const MimeBodyLimits({
    this.maxDepth = 32,
    this.maxParts = 500,
    this.maxHeaderBytes = 256 * 1024,
    this.maxDecodedBytes = 10 * 1024 * 1024,
  });
  final int maxDepth, maxParts, maxHeaderBytes, maxDecodedBytes;
}

/// The readable parts of one message: its first text and HTML bodies.
class MimeBodies {
  MimeBodies({
    this.text = '',
    this.html = '',
    this.parts = 0,
    this.inlineParts = 0,
    Set<String>? problems,
  }) : problems = problems ?? {};
  String text, html;
  int parts, inlineParts;

  /// Structural problems or limits met, such as `depth-limit`.
  final Set<String> problems;
}

/// Finds the first non-attachment `text/plain` and `text/html` bodies in a
/// MIME message. Only those two are decoded; inline resources are counted
/// and attachments skipped without decoding. Part, depth and header limits
/// are checked before a part is visited, and the decoded-byte limit before
/// a body is decoded. Problems are recorded, never thrown.
MimeBodies readMimeBodies(
  Uint8List message, {
  MimeBodyLimits limits = const MimeBodyLimits(),
}) {
  final result = MimeBodies();
  final state = _Walk(limits, result);
  try {
    state.visit(message, 0);
  } on _Stop {
    // The limit is recorded in result.problems.
  }
  return result;
}

class _Stop implements Exception {
  const _Stop();
}

class _Walk {
  _Walk(this.limits, this.result);
  final MimeBodyLimits limits;
  final MimeBodies result;
  var decoded = 0;
  bool? textFound, htmlFound;

  Never stop(String problem) {
    result.problems.add(problem);
    throw const _Stop();
  }

  void visit(Uint8List part, int depth) {
    if (depth > limits.maxDepth) stop('depth-limit');
    if (result.parts >= limits.maxParts) stop('part-limit');
    result.parts++;
    final split = _headerEnd(part, limits.maxHeaderBytes);
    if (split == null) {
      result.problems.add('header-limit');
      return;
    }
    if (split.end < 0) result.problems.add('no-header-end');
    final headerBytes = Uint8List.sublistView(
      part,
      0,
      split.end < 0 ? part.length : split.end,
    );
    final headers = _headers(latin1.decode(headerBytes), result);
    final body = split.end < 0
        ? Uint8List(0)
        : Uint8List.sublistView(part, split.bodyStart);
    final type = _contentType(headers['content-type'] ?? 'text/plain');
    final disposition = (headers['content-disposition'] ?? '').toLowerCase();
    if (disposition.startsWith('attachment')) return;
    if (type.value.startsWith('multipart/')) {
      final boundary = type.params['boundary'];
      if (boundary == null || boundary.isEmpty || boundary.length > 200) {
        result.problems.add('missing-boundary');
        return;
      }
      _eachChild(body, boundary, (child) => visit(child, depth + 1));
      return;
    }
    final encoding = (headers['content-transfer-encoding'] ?? '')
        .trim()
        .toLowerCase();
    final wantText = type.value == 'text/plain' && textFound == null;
    final wantHtml = type.value == 'text/html' && htmlFound == null;
    if (!wantText && !wantHtml) {
      if (headers.containsKey('content-id') ||
          disposition.startsWith('inline')) {
        result.inlineParts++;
      }
      return;
    }
    // Upper bound of the decoded size, checked before allocating.
    final bound = encoding == 'base64' ? body.length * 3 ~/ 4 + 3 : body.length;
    if (decoded + bound > limits.maxDecodedBytes) {
      result.problems.add('decoded-limit');
      return;
    }
    final bytes = switch (encoding) {
      'base64' => _base64(body, result),
      'quoted-printable' => _quotedPrintable(body),
      _ => body,
    };
    decoded += bytes.length;
    final text = _charset(bytes, type.params['charset'], result);
    if (wantText) {
      textFound = true;
      result.text = text;
    } else {
      htmlFound = true;
      result.html = text;
    }
  }

  /// Visits each child part of a multipart body in order, without first
  /// collecting them, so the part limit stops the scan early.
  void _eachChild(
    Uint8List body,
    String boundary,
    void Function(Uint8List child) visitChild,
  ) {
    final delimiter = latin1.encode('--$boundary');
    var at = 0;
    int? partStart;
    while (true) {
      final hit = _indexOf(body, delimiter, at);
      if (hit < 0) break;
      final next = hit + delimiter.length;
      // Match a complete delimiter line, not body text sharing its prefix.
      final closing =
          next + 1 < body.length &&
          body[next] == 0x2d &&
          body[next + 1] == 0x2d;
      var tail = next + (closing ? 2 : 0);
      while (tail < body.length && (body[tail] == 0x20 || body[tail] == 0x09)) {
        tail++;
      }
      if (tail < body.length && body[tail] == 0x0d) tail++;
      final lineEnded = tail == body.length || body[tail] == 0x0a;
      if ((hit != 0 && body[hit - 1] != 0x0a) || !lineEnded) {
        at = next;
        continue;
      }
      if (partStart != null) {
        var end = hit;
        if (end > partStart && body[end - 1] == 0x0a) end--;
        if (end > partStart && body[end - 1] == 0x0d) end--;
        visitChild(Uint8List.sublistView(body, partStart, end));
      }
      if (closing) {
        return;
      }
      var lineEnd = next;
      while (lineEnd < body.length && body[lineEnd] != 0x0a) {
        lineEnd++;
      }
      partStart = lineEnd + 1 > body.length ? body.length : lineEnd + 1;
      at = partStart;
    }
    result.problems.add('unclosed-multipart');
    if (partStart != null && partStart < body.length) {
      visitChild(Uint8List.sublistView(body, partStart));
    }
  }
}

/// The header block's end and the body's start; `end` is -1 when the part
/// has no blank line. Null when the header block exceeds [limit].
({int end, int bodyStart})? _headerEnd(Uint8List part, int limit) {
  // A part that starts with a blank line has no headers.
  if (part.isNotEmpty && part[0] == 0x0a) return (end: 0, bodyStart: 1);
  if (part.length > 1 && part[0] == 0x0d && part[1] == 0x0a) {
    return (end: 0, bodyStart: 2);
  }
  final scan = part.length < limit + 4 ? part.length : limit + 4;
  for (var i = 0; i < scan; i++) {
    if (part[i] != 0x0a) continue;
    if (i + 1 < part.length && part[i + 1] == 0x0a) {
      return i > limit ? null : (end: i, bodyStart: i + 2);
    }
    if (i + 2 < part.length && part[i + 1] == 0x0d && part[i + 2] == 0x0a) {
      final end = i > 0 && part[i - 1] == 0x0d ? i - 1 : i;
      return end > limit ? null : (end: end, bodyStart: i + 3);
    }
  }
  return part.length > limit ? null : (end: -1, bodyStart: part.length);
}

int _indexOf(Uint8List hay, List<int> needle, int start) {
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

Map<String, String> _headers(String block, MimeBodies result) {
  final out = <String, String>{};
  String? name;
  final value = StringBuffer();
  void flush() {
    final current = name;
    if (current != null) {
      out.putIfAbsent(current, () => value.toString().trim());
    }
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
      result.problems.add('bad-header-line');
      continue;
    }
    name = line.substring(0, colon).trim().toLowerCase();
    value.write(line.substring(colon + 1));
  }
  flush();
  return out;
}

({String value, Map<String, String> params}) _contentType(String header) {
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
  return (value: pieces.first.trim().toLowerCase(), params: params);
}

int _base64Value(int c) {
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26;
  if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52;
  if (c == 0x2b) return 62;
  if (c == 0x2f) return 63;
  return -1;
}

Uint8List _base64(Uint8List body, MimeBodies result) {
  final out = Uint8List(body.length * 3 ~/ 4 + 3);
  var length = 0, bits = 0, count = 0;
  var invalid = false;
  for (final c in body) {
    if (c == 0x3d) break;
    final value = _base64Value(c);
    if (value < 0) {
      if (c != 0x0d && c != 0x0a && c != 0x20 && c != 0x09) invalid = true;
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
  if (invalid) result.problems.add('bad-base64');
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

// Windows-1252 code points for bytes 0x80 to 0x9F; 0 marks undefined bytes.
const _windows1252 = [
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0, //
  0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178, //
];

String _charset(Uint8List bytes, String? charset, MimeBodies result) {
  switch ((charset ?? 'us-ascii').trim().toLowerCase()) {
    case 'utf-8' || 'utf8':
      return utf8.decode(bytes, allowMalformed: true);
    case 'us-ascii' || 'ascii' || 'iso-8859-1' || 'latin1' || 'iso8859-1':
      return latin1.decode(bytes);
    case 'windows-1252' || 'cp1252':
      final out = StringBuffer();
      for (final b in bytes) {
        final mapped = b >= 0x80 && b <= 0x9f ? _windows1252[b - 0x80] : b;
        out.writeCharCode(mapped == 0 ? 0xFFFD : mapped);
      }
      return out.toString();
    default:
      result.problems.add('unknown-charset');
      return utf8.decode(bytes, allowMalformed: true);
  }
}
