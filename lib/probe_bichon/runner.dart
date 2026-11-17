/// Runs the Bichon phone probe and returns numbers only. PROBE ONLY.
///
/// Diagnostic evidence for the D05 thresholds, measured with the real
/// [BichonApi] and transport against a fictional lab holding the
/// `tools/bichon_fixtures.py` messages. It is a separate profile build, so
/// it cannot close the release-APK gate on its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../archive_api.dart';
import '../attachment_download.dart';
import '../bichon_api.dart';
import '../message_load.dart';
import '../search_filters.dart';
import 'meter.dart';

const fixtureFolder = 'mailburrow-fixtures';
const largeSubject = 'MailBurrow fixture: large message';
const attachmentSubject = 'MailBurrow fixture: large attachment';
const mib = 1024 * 1024;

// D05 thresholds (owner approved November 15, 2026).
const memoryGrowthLimitMiB = 64;
const retentionLimitMiB = 2;
const cancelLimitMs = 250;
const cancelLimitBytes = 65536;

const _samplerInterval = Duration(milliseconds: 2);
const _settle = Duration(seconds: 5);
const _trailing = Duration(milliseconds: 500);
const _repeats = 3;

class _Overrides extends HttpOverrides {
  _Overrides(this.meter);
  final Meter meter;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      MeteredHttpClient(super.createHttpClient(context), meter);
}

/// Opens one message in a background isolate. Holds only sendable values,
/// so nothing from the probe's own connection crosses the isolate boundary.
class _IsolatedOpen {
  const _IsolatedOpen(this.server, this.token, this.id);
  final String server, token, id;

  Future<int> call() async {
    final api = BichonApi(Uri.parse(server), token);
    try {
      final m = await api.message(id);
      return m.htmlBody.length + m.textBody.length;
    } finally {
      api.close();
    }
  }
}

double _mib(int bytes) => (bytes / mib * 100).roundToDouble() / 100;

/// Samples process RSS while [work] runs and returns the peak.
/// RSS after the fixed settle window: the lowest of five samples 200 ms
/// apart, so a short-lived allocation does not count as kept.
Future<int> settledRss() async {
  await Future<void>.delayed(_settle);
  var low = ProcessInfo.currentRss;
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final now = ProcessInfo.currentRss;
    if (now < low) low = now;
  }
  return low;
}

Future<int> _peakWhile(Future<void> Function() work) async {
  var peak = ProcessInfo.currentRss;
  final timer = Timer.periodic(_samplerInterval, (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
  });
  try {
    await work();
  } finally {
    timer.cancel();
  }
  final rss = ProcessInfo.currentRss;
  return rss > peak ? rss : peak;
}

Future<Map<String, Object?>> runBichonProbe({
  required Uri server,
  required String token,
  required void Function(String) onStatus,
}) async {
  final meter = Meter();
  final result = <String, Object?>{};
  await HttpOverrides.runWithHttpOverrides(() async {
    final api = BichonApi(server, token);
    try {
      onStatus('Finding the fixtures…');
      final account = (await api.accounts()).first.id;
      final folders = await api.folders(account);
      if (!folders.any((f) => f.path == fixtureFolder)) {
        result['error'] = 'fixture folder not found';
        return;
      }
      // The two large fixtures are the oldest; list oldest first.
      final page = await api.emails(
        account,
        '',
        1,
        folder: fixtureFolder,
        filters: const SearchFilters(sortOrder: 'asc'),
      );
      final byPrefix = {for (final m in page.items) m.subject ?? '': m.id};
      final large = byPrefix[largeSubject];
      final withFile = byPrefix[attachmentSubject];
      if (large == null || withFile == null) {
        result['error'] = 'fixture messages not found';
        return;
      }

      // Memory: warm up, then the peak while a background isolate opens the
      // large message (so synchronous decoding cannot hide the peak from
      // this isolate's sampler).
      onStatus('Memory: warming up…');
      await api.message(large);
      await Future<void>.delayed(_settle);
      final baseline = ProcessInfo.currentRss;
      final highBefore = ProcessInfo.maxRss;
      onStatus('Memory: opening the large message…');
      final peak = await _peakWhile(() async {
        await Isolate.run(_IsolatedOpen(server.toString(), token, large).call);
      });
      final growth = peak - baseline;
      result['memory'] = {
        'responseBytes': meter.bytes('message-content'),
        'baselineMiB': _mib(baseline),
        'peakMiB': _mib(peak),
        'growthMiB': _mib(growth),
        'maxRssRiseMiB': _mib(ProcessInfo.maxRss - highBefore),
        'samplerMs': _samplerInterval.inMilliseconds,
        'limitMiB': memoryGrowthLimitMiB,
        'pass': growth <= memoryGrowthLimitMiB * mib,
      };

      // Retention: three open/close cycles in this isolate. Every reading,
      // the first included, follows the same settle window and is the lowest
      // of five samples, so a short-lived allocation does not count as kept.
      onStatus('Memory: three open/close cycles…');
      final readings = <int>[await settledRss()];
      for (var i = 0; i < 3; i++) {
        var message = await api.message(large);
        if (message.htmlBody.isEmpty && message.textBody.isEmpty) break;
        message = await api.message(withFile); // replace: "close" the large one
        readings.add(await settledRss());
      }
      final retained = readings.last - readings.first;
      result['retention'] = {
        'readingsMiB': [for (final r in readings) _mib(r)],
        'retainedMiB': _mib(retained),
        'settleSeconds': _settle.inSeconds,
        'samplesPerReading': 5,
        'limitMiB': retentionLimitMiB,
        'pass': retained <= retentionLimitMiB * mib,
      };

      // Cancellation: stop each still-streaming request through the app's
      // own path, and count what the client still read afterwards.
      Future<Map<String, Object?>> cancelRun(
        String kind,
        Future<void> Function(void Function() trigger) start,
        void Function() cancel, {
        int startAfterBytes = 1,
      }) async {
        meter.clear();
        var settled = false;
        int? cancelAt;
        // A transfer can also cancel itself from its own progress callback,
        // which matters when a fast link finishes before a timer could fire.
        void trigger() {
          if (cancelAt != null || settled) return;
          cancelAt = meter.now;
          cancel();
        }

        final running = start(
          trigger,
        ).then((_) {}, onError: (_) {}).whenComplete(() => settled = true);
        while (!settled &&
            cancelAt == null &&
            meter.bytes(kind) < startAfterBytes) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        if (cancelAt == null && settled) {
          return {'completedBeforeCancel': true};
        }
        trigger();
        await running;
        final stoppedAt = meter.now;
        await Future<void>.delayed(_trailing);
        final at = cancelAt!;
        final after = meter.bytes(kind, afterMicros: at);
        final last = meter.lastMicros(kind) ?? at;
        final readMs = last > at ? (last - at) / 1000 : 0.0;
        final stopMs = (stoppedAt - at) / 1000;
        return {
          'bytesBeforeCancel': meter.bytes(kind) - after,
          'bytesAfterCancel': after,
          'lastReadAfterCancelMs': readMs,
          'settledAfterCancelMs': stopMs,
          'pass':
              readMs <= cancelLimitMs &&
              stopMs <= cancelLimitMs &&
              after <= cancelLimitBytes,
        };
      }

      onStatus('Cancellation: message content…');
      result['cancelMessage'] = [
        for (var i = 0; i < _repeats; i++)
          await () {
            final load = MessageLoad();
            return cancelRun(
              'message-content',
              (_) => api.messageWithCancellation(large, load),
              load.cancel,
              startAfterBytes: 256 * 1024,
            );
          }(),
      ];

      onStatus('Cancellation: search…');
      result['cancelSearch'] = [
        for (var i = 0; i < _repeats; i++)
          await cancelRun(
            'search-messages',
            (_) => api.emails(account, 'MailBurrow fixture', 1),
            api.cancelEmailRequests,
          ),
      ];

      onStatus('Cancellation: attachment download…');
      final file = (await api.message(withFile)).attachments.single;
      final dir = await Directory.systemTemp.createTemp('bichon-probe');
      try {
        final runs = <Map<String, Object?>>[];
        for (var i = 0; i < _repeats; i++) {
          final target = File('${dir.path}/fixture-$i.bin');
          final transfer = AttachmentDownload();
          final run = await cancelRun(
            'download-attachment',
            (trigger) => api.downloadAttachment(
              withFile,
              file.id,
              target,
              transfer: transfer,
              onProgress: (received) {
                if (received >= mib) trigger();
              },
            ),
            transfer.cancel,
            startAfterBytes: mib,
          );
          run['partialFileRemoved'] = !target.existsSync();
          runs.add(run);
        }
        result['cancelAttachment'] = runs;
      } finally {
        await dir.delete(recursive: true);
      }

      result['limits'] = {
        'cancelMs': cancelLimitMs,
        'cancelBytes': cancelLimitBytes,
      };
    } on Object catch (error) {
      // Error type only: never server text, URLs or tokens.
      result['error'] = error.runtimeType.toString();
    } finally {
      api.close();
    }
  }, _Overrides(meter));
  return result;
}

/// DIAGNOSIS ONLY, never a D05 pass: separates a one-time memory rise from
/// growth on every open. Run it from a fresh app start, so neither part
/// inherits memory from the measured run.
///
/// 1. Control, no network and no MailBurrow code: decode a locally built
///    JSON reply the size of the Bichon large-message response, ten times.
/// 2. The app's shared decoder on that same reply, still without network.
/// 3. The app path: open the fixture's large message ten times through
///    `BichonApi.message()`, replacing it with a small message each time.
Future<Map<String, Object?>> runRetentionDiagnosis({
  required Uri server,
  required String token,
  required void Function(String) onStatus,
}) async {
  const cycles = 10;
  final result = <String, Object?>{'kind': 'diagnosis, not a D05 pass'};
  Map<String, Object?> summary(List<int> readings) => {
    'readingsMiB': [for (final r in readings) _mib(r)],
    'firstCycleRiseMiB': _mib(readings[1] - readings[0]),
    'afterFirstCycleMiB': _mib(readings.last - readings[1]),
    'totalMiB': _mib(readings.last - readings.first),
  };

  onStatus('Diagnosis: control without network…');
  // Same shape as Bichon's large-message reply, padded to its measured
  // size (8,290,934 bytes) so both parts decode the same amount.
  const replyTarget = 8290934;
  const bodyChars = 4120001;
  final words = 'harbor lantern meadow orchard pebble quartz ribbon ';
  String body(int n) => (words * (n ~/ words.length + 1)).substring(0, n);
  final shell = utf8
      .encode(
        jsonEncode({
          'text': body(bodyChars),
          'html': body(bodyChars),
          'attachments': <Object>[],
          'has_remote_content': false,
          'pad': '',
        }),
      )
      .length;
  final reply = utf8.encode(
    jsonEncode({
      'text': body(bodyChars),
      'html': body(bodyChars),
      'attachments': <Object>[],
      'has_remote_content': false,
      'pad': body(replyTarget > shell ? replyTarget - shell : 0),
    }),
  );
  final control = <int>[await settledRss()];
  for (var i = 0; i < cycles; i++) {
    onStatus('Diagnosis: control cycle ${i + 1} of $cycles…');
    var decoded = jsonDecode(utf8.decode(reply)) as Map<String, Object?>;
    if ((decoded['html'] as String).isEmpty) break;
    decoded = const {};
    control.add(await settledRss());
  }
  result['control'] = {'replyBytes': reply.length, ...summary(control)};

  // Same reply through the app's shared decoder (every backend uses it):
  // a background isolate decodes it and hands the result back. No network.
  final shared = <int>[await settledRss()];
  for (var i = 0; i < cycles; i++) {
    onStatus('Diagnosis: shared decoder cycle ${i + 1} of $cycles…');
    var decoded =
        await decodeArchiveJson(Stream.value(reply)) as Map<String, Object?>;
    if ((decoded['html'] as String).isEmpty) break;
    decoded = const {};
    shared.add(await settledRss());
  }
  result['sharedDecoder'] = summary(shared);

  final api = BichonApi(server, token);
  try {
    final account = (await api.accounts()).first.id;
    await api.folders(account); // the folder list maps the fixture folder
    final page = await api.emails(
      account,
      '',
      1,
      folder: fixtureFolder,
      filters: const SearchFilters(sortOrder: 'asc'),
    );
    String? find(String subject) {
      for (final e in page.items) {
        if (e.subject == subject) return e.id;
      }
      return null;
    }

    final large = find(largeSubject), small = find(attachmentSubject);
    if (large == null || small == null) {
      result['error'] = 'fixture messages not found';
      return result;
    }
    final app = <int>[await settledRss()];
    for (var i = 0; i < cycles; i++) {
      onStatus('Diagnosis: app cycle ${i + 1} of $cycles…');
      var message = await api.message(large);
      if (message.htmlBody.isEmpty && message.textBody.isEmpty) break;
      message = await api.message(small);
      app.add(await settledRss());
    }
    result['app'] = summary(app);
  } on Object catch (error) {
    result['error'] = error.runtimeType.toString();
  } finally {
    api.close();
  }
  result['settleSeconds'] = _settle.inSeconds;
  result['samplesPerReading'] = 5;
  return result;
}
