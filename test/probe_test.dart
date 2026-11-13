// PROBE BRANCH ONLY: correctness checks for the phone probe's helpers.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/probe/buffer_decoder.dart';
import 'package:mailburrow/probe/mime_walk.dart';
import 'package:mailburrow/probe/probe_inputs.dart';
import 'package:mailburrow/probe/probe_runner.dart';

const scale = 0.002;

Uint8List build(String name) =>
    probeCases.firstWhere((item) => item.name == name).build(scale);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('wire encoding matches the Buffer JSON shape', () {
    final eml = Uint8List.fromList([0, 9, 10, 99, 100, 255]);
    final wire = encodeWire(eml);
    final json = jsonDecode(utf8.decode(wire)) as Map<String, dynamic>;
    expect(json['raw'], {'type': 'Buffer', 'data': eml.toList()});
    expect(naiveDecode(wire), eml);
  });

  test('streaming decode matches naive decode at any chunk size', () {
    for (final probe in probeCases) {
      final eml = probe.build(scale);
      final wire = encodeWire(eml);
      for (final size in [1, 7, 4096]) {
        expect(
          streamDecode(wire, maxBytes: streamCap, chunkSize: size),
          eml,
          reason: '${probe.name} at $size',
        );
      }
    }
  });

  test('streaming decode enforces its cap and rejects bad input', () {
    final wire = encodeWire(Uint8List(1000));
    expect(
      () => streamDecode(wire, maxBytes: 999),
      throwsA(isA<ProbeLimitExceeded>()),
    );
    expect(streamDecode(wire, maxBytes: 1000), hasLength(1000));
    for (final bad in [
      '{"raw":{"type":"Buffer","data":[256]}}',
      '{"raw":{"type":"Buffer","data":[1,x]}}',
      '{"raw":{"type":"Buffer","data":[1,]}}',
      '{"raw":{"type":"Buffer","data":[1,2',
    ]) {
      expect(
        () => streamDecode(Uint8List.fromList(latin1.encode(bad)), maxBytes: 9),
        throwsFormatException,
        reason: bad,
      );
    }
    expect(
      streamDecode(
        Uint8List.fromList(latin1.encode('{"a":"\\"","data":[]}')),
        maxBytes: 9,
      ),
      isEmpty,
    );
  });

  test('the MIME walker finds bodies and inline resources', () {
    final text = walkMime(build('text-100k'));
    expect(text.text, contains('quick brown fox'));
    expect(text.problems, isEmpty);

    final qp = walkMime(build('html-qp-1m'));
    expect(qp.html, contains('Café crème'));
    expect(qp.html, contains('a=b;'));
    expect(qp.problems, isEmpty);

    final latin = walkMime(build('latin1-qp-200k'));
    expect(latin.text, contains('brûlée'));

    final inline = walkMime(build('inline-2m'));
    expect(inline.html, contains('cid:img0@probe.example'));
    expect(inline.inlineParts, 4);
    expect(inline.inlineBytes, greaterThan(4000));
    expect(inline.problems, isEmpty);

    final parts = walkMime(build('parts-1000'));
    expect(parts.parts, 3);
    expect(parts.text, contains('Part 0.'));
  });

  test('the MIME walker records limits and malformed input', () {
    final full = walkMime(
      probeCases.firstWhere((item) => item.name == 'parts-1000').build(1),
    );
    expect(full.problems, contains('part-limit'));

    final nested = walkMime(build('nested-60'));
    expect(nested.problems, contains('depth-limit'));
    expect(nested.maxDepth, 33);

    final unclosed = walkMime(build('malformed-unclosed'));
    expect(unclosed.problems, containsAll(['unclosed-multipart', 'bad-base64']));
    expect(unclosed.text, isNotNull);

    final header = walkMime(
      probeCases
          .firstWhere((item) => item.name == 'malformed-header-1m')
          .build(1),
    );
    expect(header.problems, containsAll(['no-header-end', 'header-limit']));

    final small = walkMime(build('malformed-header-1m'));
    expect(small.problems, contains('no-header-end'));
    expect(small.problems, contains('bad-header-line'));

    final capped = walkMime(
      build('inline-2m'),
      limits: const MimeLimits(maxDecodedBytes: 100),
    );
    expect(capped.problems, contains('decoded-limit'));
  });

  test('a scaled-down run reports every section', () async {
    final result = await measureCase(0, scale: scale);
    expect(result['case'], 'text-100k');
    expect(result['streamMatches'], isTrue);
    expect(result['naiveMatches'], isTrue);
    expect(result['mime'], isA<Map<String, Object?>>());
    final cap = await measureCase(
      probeCases.indexWhere((item) => item.name == capCase),
      scale: 0.5,
      capOnly: true,
    );
    expect(cap['capRejected'], isTrue);
    // The test binding answers every HttpClient request with a mock 400;
    // the cancellation check needs real loopback sockets.
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    for (final variant in cancelVariants) {
      final cancel = await measureCancel(variant, scale: 0.05);
      expect(cancel['error'], isNull, reason: variant);
      expect(cancel['clientCancelMs'], isA<int>(), reason: variant);
      expect(cancel['contentLengthSeen'], isTrue, reason: variant);
    }
  });
}
