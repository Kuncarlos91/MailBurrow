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

/// Streams a large response over loopback and cancels it part-way, timing
/// how quickly the client stops and the server sees the connection close.
Future<Map<String, Object?>> measureCancel({double scale = 1}) async {
  final index = probeCases.indexWhere((item) => item.name == 'inline-8m');
  final wire = encodeWire(probeCases[index].build(scale));
  final threshold = (wire.length ~/ 8).clamp(1, _mib);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverStopped = Completer<void>();
  final cancelClock = Stopwatch();
  var sentAfterCancel = 0;
  server.listen((request) async {
    final response = request.response;
    try {
      for (var at = 0; at < wire.length; at += 64 * 1024) {
        final end = at + 64 * 1024 < wire.length ? at + 64 * 1024 : wire.length;
        response.add(Uint8List.sublistView(wire, at, end));
        await response.flush();
        if (cancelClock.isRunning) sentAfterCancel += end - at;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await response.close();
    } catch (_) {
      // The client went away: the case this measures.
    } finally {
      if (!serverStopped.isCompleted) serverStopped.complete();
    }
  });
  final client = HttpClient();
  final result = <String, Object?>{'case': 'cancel-inline-8m'};
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final response = await request.close();
    final decoder = BufferArrayDecoder(maxBytes: streamCap);
    final reached = Completer<void>();
    final subscription = response.listen((chunk) {
      decoder.add(chunk);
      if (decoder.consumed >= threshold && !reached.isCompleted) {
        reached.complete();
      }
    }, onDone: () {
      if (!reached.isCompleted) reached.complete();
    });
    await reached.future.timeout(const Duration(seconds: 30));
    cancelClock.start();
    await subscription.cancel();
    client.close(force: true);
    result['clientCancelMs'] = cancelClock.elapsedMilliseconds;
    await serverStopped.future.timeout(const Duration(seconds: 10));
    result
      ..['serverStopMs'] = cancelClock.elapsedMilliseconds
      ..['wireBeforeCancel'] = decoder.consumed
      ..['sentAfterCancel'] = sentAfterCancel
      ..['wireTotal'] = wire.length;
  } on TimeoutException {
    result['error'] = 'timeout';
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
  onStatus?.call('Running the cancellation check');
  final cancel = await measureCancel(scale: scale);
  return {
    'probe': 'oa-phone-budgets',
    'version': 1,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'cases': cases,
    'cap': cap,
    'cancel': cancel,
  };
}
