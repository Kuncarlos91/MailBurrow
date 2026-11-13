/// Runs the phone probe and returns numbers only. PROBE ONLY.
///
/// Each case runs in its own isolate while this isolate samples process RSS,
/// so a phase's peak memory growth is visible even during synchronous work.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../message_body.dart';
import 'buffer_decoder.dart';
import 'mime_walk.dart';
import 'probe_inputs.dart';

/// Above this wire size the naive decoder is skipped, so one run cannot be
/// killed for memory before the other cases are measured.
const naiveWireLimit = 48 * 1024 * 1024;

/// Cap used by the streaming decoder for the normal cases.
const streamCap = 64 * 1024 * 1024;

/// The cap-rejection case: the 20 MB inline message against an 8 MiB cap.
const capCase = 'inline-20m';
const capBytes = 8 * 1024 * 1024;

const _mib = 1024 * 1024;

double _mb(int bytes) => (bytes / _mib * 10).round() / 10;

void _caseWorker(List<Object> args) {
  final port = args[0] as SendPort;
  final index = args[1] as int;
  final scale = args[2] as double;
  final capOnly = args[3] as bool;
  final probe = probeCases[index];
  final result = <String, Object?>{'case': probe.name};
  try {
    final eml = probe.build(scale);
    final wire = encodeWire(eml);
    result
      ..['emlBytes'] = eml.length
      ..['wireBytes'] = wire.length
      ..['wireRatio'] = (wire.length / eml.length * 100).round() / 100;
    final watch = Stopwatch();
    if (capOnly) {
      result['case'] = 'cap-${capBytes ~/ _mib}m-on-${probe.name}';
      port.send({'phase': 'cap'});
      watch.start();
      final decoder = BufferArrayDecoder(maxBytes: capBytes);
      try {
        for (var at = 0; at < wire.length; at += 64 * 1024) {
          final end = at + 64 * 1024 < wire.length ? at + 64 * 1024 : wire.length;
          decoder.add(Uint8List.sublistView(wire, at, end));
        }
        result['capRejected'] = false;
      } on ProbeLimitExceeded {
        result['capRejected'] = true;
      }
      result
        ..['capMs'] = watch.elapsedMilliseconds
        ..['capWireConsumed'] = decoder.consumed;
      port.send({'result': result});
      return;
    }
    if (wire.length <= naiveWireLimit) {
      port.send({'phase': 'naive'});
      watch.start();
      final bytes = naiveDecode(wire);
      result
        ..['naiveMs'] = watch.elapsedMilliseconds
        ..['naiveMatches'] = bytes.length == eml.length;
    } else {
      result['naiveMs'] = 'skipped: wire over ${naiveWireLimit ~/ _mib} MiB';
    }
    port.send({'phase': 'stream'});
    watch
      ..reset()
      ..start();
    final bytes = streamDecode(wire, maxBytes: streamCap);
    result
      ..['streamMs'] = watch.elapsedMilliseconds
      ..['streamMatches'] = bytes.length == eml.length;
    port.send({'phase': 'mime'});
    watch
      ..reset()
      ..start();
    final summary = walkMime(bytes);
    result
      ..['mimeMs'] = watch.elapsedMilliseconds
      ..['mime'] = summary.toJson();
    port.send({'result': result, 'html': summary.html, 'text': summary.text});
  } catch (error) {
    result['error'] = error.runtimeType.toString();
    port.send({'result': result});
  }
}

/// Runs one case; [capOnly] runs the cap-rejection variant instead.
Future<Map<String, Object?>> measureCase(
  int index, {
  double scale = 1,
  bool capOnly = false,
}) async {
  final port = ReceivePort();
  final peaks = <String, int>{};
  final starts = <String, int>{};
  String? phase;
  final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final current = phase;
    if (current == null) return;
    final growth = ProcessInfo.currentRss - starts[current]!;
    if (growth > (peaks[current] ?? 0)) peaks[current] = growth;
  });
  final done = Completer<Map<Object?, Object?>>();
  port.listen((message) {
    final map = message as Map<Object?, Object?>;
    final next = map['phase'] as String?;
    if (next != null) {
      starts[next] = ProcessInfo.currentRss;
      phase = next;
    } else if (!done.isCompleted) {
      done.complete(map);
    }
  });
  await Isolate.spawn(_caseWorker, <Object>[port.sendPort, index, scale, capOnly]);
  final message = await done.future;
  sampler.cancel();
  port.close();
  final result = Map<String, Object?>.of(
    (message['result'] as Map<Object?, Object?>).cast<String, Object?>(),
  );
  for (final entry in peaks.entries) {
    result['${entry.key}PeakRssMb'] = _mb(entry.value);
  }
  final html = message['html'] as String? ?? '';
  final text = message['text'] as String? ?? '';
  if (!capOnly && result['error'] == null) {
    final watch = Stopwatch()..start();
    try {
      final prepared = await prepareEmailBodyAsync(html, text);
      result
        ..['prepMs'] = watch.elapsedMilliseconds
        ..['prepNotice'] = prepared.notice != null
        ..['prepTextLimited'] = prepared.textLimited;
    } on TimeoutException {
      result['prepMs'] = 'timeout after ${watch.elapsedMilliseconds}';
    } catch (error) {
      result['prepMs'] = 'error ${error.runtimeType}';
    }
  }
  return result;
}

/// Ways to stop a response body part-way, compared in probe run 2.
const cancelVariants = [
  // Run 1's method, also the pattern the Mail-Archiver client uses.
  'cancel-then-close',
  'close-then-cancel',
  'abort-then-cancel',
  // Detach the socket right after the headers, read the body from it, and
  // destroy it on cancel.
  'detach-destroy',
];

/// Streams a large response over loopback with a Content-Length (as Open
/// Archiver's JSON responses have) and stops it part-way using [variant].
/// It times how quickly the client stops, when the server sees the drop,
/// and how many bytes the server still delivered after the stop.
Future<Map<String, Object?>> measureCancel(
  String variant, {
  double scale = 1,
}) async {
  final index = probeCases.indexWhere((item) => item.name == 'inline-8m');
  final wire = encodeWire(probeCases[index].build(scale));
  final threshold = (wire.length ~/ 8).clamp(1, _mib);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverStopped = Completer<void>();
  final cancelClock = Stopwatch();
  var sentAfterCancel = 0;
  var serverCompleted = false;
  server.listen((request) async {
    final response = request.response..contentLength = wire.length;
    var gone = false;
    // A dropped client fails `done`; a pending flush may never complete.
    unawaited(
      response.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        gone = true;
        if (!serverStopped.isCompleted) serverStopped.complete();
      }),
    );
    try {
      for (var at = 0; at < wire.length && !gone; at += 64 * 1024) {
        final end = at + 64 * 1024 < wire.length ? at + 64 * 1024 : wire.length;
        response.add(Uint8List.sublistView(wire, at, end));
        await response.flush();
        if (cancelClock.isRunning) sentAfterCancel += end - at;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await response.close();
      serverCompleted = true;
    } catch (_) {
      // The client went away: the case this measures.
    } finally {
      if (!serverStopped.isCompleted) serverStopped.complete();
    }
  });
  final client = HttpClient();
  final result = <String, Object?>{'case': 'cancel-$variant'};
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      result['error'] = 'status ${response.statusCode}';
      return result;
    }
    result['contentLengthSeen'] = response.contentLength == wire.length;
    final decoder = BufferArrayDecoder(maxBytes: streamCap);
    final reached = Completer<void>();
    void onChunk(List<int> chunk) {
      if (reached.isCompleted) return;
      decoder.add(chunk);
      if (decoder.consumed >= threshold) reached.complete();
    }

    void onDone() {
      if (!reached.isCompleted) reached.complete();
    }

    Future<void> Function() stop;
    if (variant == 'detach-destroy') {
      final socket = await response.detachSocket();
      final subscription = socket.listen(onChunk, onDone: onDone);
      stop = () async {
        socket.destroy();
        await subscription.cancel();
      };
    } else {
      final subscription = response.listen(onChunk, onDone: onDone);
      stop = switch (variant) {
        'close-then-cancel' => () async {
          client.close(force: true);
          await subscription.cancel();
        },
        'abort-then-cancel' => () async {
          request.abort();
          await subscription.cancel();
        },
        _ => () async {
          await subscription.cancel();
          client.close(force: true);
        },
      };
    }
    await reached.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('first bytes'),
    );
    cancelClock.start();
    await stop();
    result['clientCancelMs'] = cancelClock.elapsedMilliseconds;
    // A server that never sees the drop is a result, not a probe error.
    var stopped = true;
    await serverStopped.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => stopped = false,
    );
    result
      ..['serverStopMs'] = stopped
          ? cancelClock.elapsedMilliseconds
          : 'not within 10 s'
      ..['serverCompleted'] = serverCompleted
      ..['wireBeforeCancel'] = decoder.consumed
      ..['sentAfterCancel'] = sentAfterCancel
      ..['wireTotal'] = wire.length;
  } on TimeoutException catch (error) {
    result['error'] = 'timeout waiting for ${error.message}';
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  return result;
}

/// Runs every case, then the cap and cancellation checks.
Future<Map<String, Object?>> runProbe({
  double scale = 1,
  void Function(String status)? onStatus,
}) async {
  final cases = <Map<String, Object?>>[];
  for (var i = 0; i < probeCases.length; i++) {
    onStatus?.call('Running ${probeCases[i].name} (${i + 1}/${probeCases.length})');
    cases.add(await measureCase(i, scale: scale));
  }
  onStatus?.call('Running the 8 MiB cap check');
  final cap = await measureCase(
    probeCases.indexWhere((item) => item.name == capCase),
    scale: scale,
    capOnly: true,
  );
  final cancel = <Map<String, Object?>>[];
  for (final variant in cancelVariants) {
    onStatus?.call('Running the cancellation check: $variant');
    cancel.add(await measureCancel(variant, scale: scale));
  }
  return {
    'probe': 'oa-phone-budgets',
    'version': 2,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'cases': cases,
    'cap': cap,
    'cancel': cancel,
  };
}
