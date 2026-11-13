/// Synthetic worst-case inputs for the Open Archiver phone probe.
///
/// PROBE ONLY: never merged into the app. Every message is generated here
/// from fixed seeds; no real mail, server or key is involved.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One synthetic message shape. [scale] multiplies every size so host tests
/// can run the same shapes in milliseconds.
class ProbeCase {
  const ProbeCase(this.name, this.build);
  final String name;
  final Uint8List Function(double scale) build;
}

const _crlf = '\r\n';

int _bytes(double scale, int full) => (full * scale).ceil().clamp(1, full);

/// Deterministic pseudo-random bytes (linear congruential generator).
Uint8List noise(int length, int seed) {
  final out = Uint8List(length);
  var state = seed & 0x7fffffff;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    out[i] = state >> 16 & 0xff;
  }
  return out;
}

String _wrap(String value, int width) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i += width) {
    final end = i + width < value.length ? i + width : value.length;
    buffer
      ..write(value.substring(i, end))
      ..write(_crlf);
  }
  return buffer.toString();
}

String _headers(String contentType, {String extra = ''}) =>
    'From: Probe Sender <sender@probe.example>$_crlf'
    'To: Probe Reader <reader@probe.example>$_crlf'
    'Subject: Synthetic probe message$_crlf'
    'Date: Mon, 02 Mar 2026 10:00:00 +0000$_crlf'
    'Message-ID: <probe@mailburrow.example>$_crlf'
    'MIME-Version: 1.0$_crlf'
    'Content-Type: $contentType$_crlf'
    '$extra$_crlf';

const _sentence =
    'The quick brown fox jumps over the lazy dog near the riverbank. ';
const _accented = 'Café crème brûlée à la française, naïve façade. ';

String _repeat(String unit, int length) {
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(unit);
  }
  return buffer.toString().substring(0, length);
}

String _html(int length) {
  final buffer = StringBuffer('<html><body>');
  var row = 0;
  while (buffer.length < length) {
    buffer.write(
      '<p style="margin:0;color:#333">Row ${row++}: $_sentence</p>\n',
    );
  }
  buffer.write('</body></html>');
  return buffer.toString();
}

/// Quoted-printable encoding with soft line breaks, as mail clients send it.
String quotedPrintable(List<int> bytes) {
  final buffer = StringBuffer();
  var line = 0;
  void put(String value) {
    if (line + value.length > 75) {
      buffer.write('=$_crlf');
      line = 0;
    }
    buffer.write(value);
    line += value.length;
  }

  for (final byte in bytes) {
    if (byte == 0x0a) {
      buffer.write(_crlf);
      line = 0;
    } else if (byte == 0x0d) {
      continue;
    } else if (byte == 0x3d || byte > 0x7e || (byte < 0x20 && byte != 9)) {
      put('=${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      put(String.fromCharCode(byte));
    }
  }
  return buffer.toString();
}

Uint8List _ascii(String value) => Uint8List.fromList(latin1.encode(value));

Uint8List plainText(double scale) {
  final body = _repeat(_sentence, _bytes(scale, 100 * 1024));
  return _ascii(
    _headers('text/plain; charset=utf-8',
            extra: 'Content-Transfer-Encoding: 7bit$_crlf') +
        _wrap(body, 76),
  );
}

Uint8List largeHtml(double scale) => _ascii(
  _headers('text/html; charset=utf-8',
          extra: 'Content-Transfer-Encoding: 7bit$_crlf') +
      _html(_bytes(scale, 250 * 1024)),
);

Uint8List quotedPrintableHtml(double scale) {
  // Accented text and '=' signs make most characters expand to =XX.
  final html = _html(_bytes(scale, 1024 * 1024))
      .replaceAll(_sentence, '$_accented a=b; ');
  return _ascii(
    _headers('text/html; charset=utf-8',
            extra: 'Content-Transfer-Encoding: quoted-printable$_crlf') +
        quotedPrintable(utf8.encode(html)),
  );
}

/// HTML plus inline images totalling [fullInline] decoded bytes.
Uint8List Function(double) inlineImages(int fullInline) => (scale) {
  const images = 4;
  final each = _bytes(scale, fullInline) ~/ images + 1;
  final buffer = StringBuffer(
    _headers('multipart/related; boundary="rel-1"; type="text/html"'),
  );
  buffer
    ..write('--rel-1$_crlf')
    ..write('Content-Type: text/html; charset=utf-8$_crlf')
    ..write('Content-Transfer-Encoding: 7bit$_crlf$_crlf');
  final html = StringBuffer('<html><body><p>Inline images below.</p>');
  for (var i = 0; i < images; i++) {
    html.write('<img src="cid:img$i@probe.example" alt="Image $i">');
  }
  html.write('</body></html>');
  buffer.write('$html$_crlf');
  for (var i = 0; i < images; i++) {
    buffer
      ..write('--rel-1$_crlf')
      ..write('Content-Type: image/png; name="img$i.png"$_crlf')
      ..write('Content-Transfer-Encoding: base64$_crlf')
      ..write('Content-ID: <img$i@probe.example>$_crlf')
      ..write('Content-Disposition: inline; filename="img$i.png"$_crlf$_crlf')
      ..write(_wrap(base64Encode(noise(each, 17 + i)), 76));
  }
  buffer.write('--rel-1--$_crlf');
  return _ascii(buffer.toString());
};

Uint8List manyParts(double scale) {
  final count = (1000 * scale).ceil().clamp(2, 1000);
  final buffer = StringBuffer(_headers('multipart/mixed; boundary="mix"'));
  for (var i = 0; i < count; i++) {
    buffer
      ..write('--mix$_crlf')
      ..write('Content-Type: text/plain; charset=us-ascii$_crlf$_crlf')
      ..write('Part $i. $_sentence$_crlf');
  }
  buffer.write('--mix--$_crlf');
  return _ascii(buffer.toString());
}

Uint8List deepNesting(double scale) {
  const depth = 60;
  final buffer = StringBuffer(_headers('multipart/mixed; boundary="n0"'));
  for (var i = 0; i < depth; i++) {
    buffer
      ..write('--n$i$_crlf')
      ..write('Content-Type: multipart/mixed; boundary="n${i + 1}"$_crlf$_crlf');
  }
  buffer
    ..write('--n$depth$_crlf')
    ..write('Content-Type: text/plain$_crlf$_crlf')
    ..write('Innermost text.$_crlf')
    ..write('--n$depth--$_crlf');
  for (var i = depth - 1; i >= 0; i--) {
    buffer.write('--n$i--$_crlf');
  }
  return _ascii(buffer.toString());
}

Uint8List unclosedMultipart(double scale) {
  final buffer = StringBuffer(_headers('multipart/mixed; boundary="open"'));
  buffer
    ..write('--open$_crlf')
    ..write('Content-Type: text/plain$_crlf$_crlf')
    ..write(_wrap(_repeat(_sentence, _bytes(scale, 64 * 1024)), 76))
    ..write('--open$_crlf')
    ..write('Content-Type: image/png$_crlf')
    ..write('Content-Transfer-Encoding: base64$_crlf')
    ..write('Content-Disposition: inline$_crlf$_crlf')
    // Invalid characters mid-stream and a missing closing boundary.
    ..write(_wrap('!!**${base64Encode(noise(_bytes(scale, 256 * 1024), 5))}', 76));
  return _ascii(buffer.toString());
}

Uint8List hugeHeader(double scale) {
  // One unfolded header line and no blank line before the body.
  final value = _repeat('x', _bytes(scale, 1024 * 1024));
  return _ascii(
    'From: sender@probe.example$_crlf'
    'X-Probe-Long: $value$_crlf'
    'Subject: no header terminator$_crlf'
    'Body text without a separator.$_crlf',
  );
}

Uint8List latin1Text(double scale) {
  final body = _repeat(_accented, _bytes(scale, 200 * 1024));
  return _ascii(
    _headers('text/plain; charset=iso-8859-1',
            extra: 'Content-Transfer-Encoding: quoted-printable$_crlf') +
        quotedPrintable(latin1.encode(body)),
  );
}

/// The probe cases, smallest inline payload first.
final probeCases = <ProbeCase>[
  const ProbeCase('text-100k', plainText),
  const ProbeCase('html-250k', largeHtml),
  const ProbeCase('html-qp-1m', quotedPrintableHtml),
  const ProbeCase('latin1-qp-200k', latin1Text),
  const ProbeCase('parts-1000', manyParts),
  const ProbeCase('nested-60', deepNesting),
  const ProbeCase('malformed-unclosed', unclosedMultipart),
  const ProbeCase('malformed-header-1m', hugeHeader),
  ProbeCase('inline-2m', inlineImages(2 * 1024 * 1024)),
  ProbeCase('inline-8m', inlineImages(8 * 1024 * 1024)),
  ProbeCase('inline-20m', inlineImages(20 * 1024 * 1024)),
];

const _wirePrefix =
    '{"id":"00000000-0000-4000-8000-000000000001",'
    '"subject":"Synthetic probe message","raw":{"type":"Buffer","data":[';
const _wireSuffix = ']},"attachments":[],"thread":[]}';

/// Encodes [eml] the way Open Archiver v0.6.2 sends `raw`: a Node Buffer
/// serialized as a JSON array with one decimal number per byte.
Uint8List encodeWire(Uint8List eml) {
  final prefix = latin1.encode(_wirePrefix);
  final suffix = latin1.encode(_wireSuffix);
  final out = Uint8List(prefix.length + eml.length * 4 + suffix.length);
  out.setAll(0, prefix);
  var at = prefix.length;
  for (var i = 0; i < eml.length; i++) {
    if (i > 0) out[at++] = 0x2c;
    final value = eml[i];
    if (value >= 100) out[at++] = 0x30 + value ~/ 100;
    if (value >= 10) out[at++] = 0x30 + value ~/ 10 % 10;
    out[at++] = 0x30 + value % 10;
  }
  out.setAll(at, suffix);
  return Uint8List.sublistView(out, 0, at + suffix.length);
}
