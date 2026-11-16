/// Runs the Bichon phone probe and returns numbers only. PROBE ONLY.
///
/// Diagnostic evidence for the D05 thresholds, measured with the real
/// [BichonApi] and transport against a fictional lab holding the
/// `tools/bichon_fixtures.py` messages. It is a separate profile build, so
/// it cannot close the release-APK gate on its own.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
