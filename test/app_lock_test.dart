import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/app_lock/app_lock_controller.dart';
import 'package:mailburrow/app_lock/app_lock_gate.dart';
import 'package:mailburrow/app_lock/app_lock_platform.dart';
import 'package:mailburrow/app_lock/app_lock_settings.dart';
import 'package:mailburrow/state/connection_store.dart';

class MemoryEntries extends SecureEntries {
  MemoryEntries([Map<String, String>? values]) : values = values ?? {};
  final Map<String, String> values;
  Object? readError;
  Object? writeError;
  int writes = 0;

  @override
  Future<String?> read({required String key}) async {
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    writes++;
    if (writeError != null) throw writeError!;
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async => values.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

class FakePlatform implements AppLockPlatform {
  bool supported = true;
  int? now = 1000000;
  final prompts = <Completer<AppLockAuthResult>>[];
  final reasons = <String>[];
  final privacy = <bool>[];

  /// When set, prompts answer at once with this result.
  AppLockAuthResult? autoAnswer;

  @override
  Future<bool> canAuthenticate() async => supported;

  @override
  Future<AppLockAuthResult> authenticate(String reason) {
    reasons.add(reason);
    if (autoAnswer != null) return Future.value(autoAnswer);
    final c = Completer<AppLockAuthResult>();
    prompts.add(c);
    return c.future;
  }

  void answer(AppLockAuthResult result) => prompts.last.complete(result);

  @override
  Future<int?> elapsedMillis() async => now;

  @override
  Future<void> setPrivacyProtection(bool enabled) async => privacy.add(enabled);
}

String stored(bool enabled, int seconds) => AppLockSettings(
  enabled: enabled,
  relockAfter: Duration(seconds: seconds),
).encode();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryEntries entries;
  late FakePlatform platform;
  late AppLifecycleState lifecycle;
  late AppLockController lock;

  AppLockController make() => AppLockController(
    store: AppLockStore(entries: entries),
    platform: platform,
    lifecycleState: () => lifecycle,
  );

  setUp(() {
    entries = MemoryEntries();
    platform = FakePlatform();
    lifecycle = AppLifecycleState.resumed;
    lock = make();
  });

  tearDown(() => lock.dispose());

  Future<void> settle() => pumpEventQueue();

  Future<void> startUnlocked({int relockSeconds = 60}) async {
    entries.values[AppLockStore.entry] = stored(true, relockSeconds);
    lock = make();
    platform.autoAnswer = AppLockAuthResult.success;
    await lock.start();
    await lock.unlock();
    await settle();
    platform.autoAnswer = null;
    expect(lock.phase, AppLockPhase.unlocked);
    expect(lock.contentVisible, isTrue);
  }

  void leave() {
    lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
    lifecycle = AppLifecycleState.paused;
    lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
  }

  Future<void> returnToApp() async {
    lifecycle = AppLifecycleState.resumed;
    lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
  }

  group('settings encoding', () {
    test('round-trips and rejects damaged values', () {
      const s = AppLockSettings(
        enabled: true,
        relockAfter: Duration(minutes: 5),
      );
      expect(AppLockSettings.decode(s.encode()), s);
      for (final bad in [
        'not json',
        '[]',
        '{"version":2,"enabled":true,"relockSeconds":60}',
        '{"version":1,"enabled":"yes","relockSeconds":60}',
        '{"version":1,"enabled":true,"relockSeconds":30}',
        '{"version":1,"enabled":true}',
      ]) {
        expect(() => AppLockSettings.decode(bad), throwsFormatException);
      }
    });

    test('uses its own entry, separate from saved connections', () {
      expect(AppLockStore.entry.startsWith('connection'), isFalse);
    });
  });

  group('startup', () {
    test('a new install is off and shows content', () async {
      lock = make();
      expect(lock.contentVisible, isFalse, reason: 'covered while loading');
      expect(lock.mayBuildContent, isFalse);
      await lock.start();
      expect(lock.phase, AppLockPhase.off);
      expect(lock.contentVisible, isTrue);
      expect(lock.mayBuildContent, isTrue);
      expect(platform.privacy, [false]);
      expect(platform.reasons, isEmpty);
    });

    test('a read failure stays covered, never off', () async {
      entries.readError = Exception('storage unavailable');
      lock = make();
      await lock.start();
      expect(lock.phase, AppLockPhase.error);
      expect(lock.contentVisible, isFalse);
      expect(lock.mayBuildContent, isFalse);
      expect(lock.message, isNotNull);
    });

    test('a damaged value stays covered and retry can recover', () async {
      entries.values[AppLockStore.entry] = '{"version":9}';
      lock = make();
      await lock.start();
      expect(lock.phase, AppLockPhase.error);
      entries.values[AppLockStore.entry] = stored(false, 60);
      await lock.retry();
      expect(lock.phase, AppLockPhase.off);
    });

    test(
      'repair after a damaged value needs unlock and keeps the lock on',
      () async {
        entries.values[AppLockStore.entry] = 'garbage';
        lock = make();
        await lock.start();
        final repairing = lock.unlockAndRepair();
        await settle();
        expect(lock.contentVisible, isFalse);
        platform.answer(AppLockAuthResult.success);
        await repairing;
        expect(lock.phase, AppLockPhase.unlocked);
        expect(lock.settings!.enabled, isTrue);
        expect(
          AppLockSettings.decode(entries.values[AppLockStore.entry]!).enabled,
          isTrue,
        );
      },
    );

    test('a cancelled repair stays covered', () async {
      entries.values[AppLockStore.entry] = 'garbage';
      lock = make();
      await lock.start();
      final repairing = lock.unlockAndRepair();
      await settle();
      platform.answer(AppLockAuthResult.canceled);
      await repairing;
      expect(lock.phase, AppLockPhase.error);
      expect(entries.values[AppLockStore.entry], 'garbage');
    });

    test('lock on: starts locked, content not built, privacy on', () async {
      entries.values[AppLockStore.entry] = stored(true, 60);
      lock = make();
      await lock.start();
      expect(lock.phase, AppLockPhase.locked);
      expect(lock.mayBuildContent, isFalse);
      expect(platform.privacy, [true]);
    });
  });

  group('unlocking', () {
    setUp(() async {
      entries.values[AppLockStore.entry] = stored(true, 60);
      lock = make();
      await lock.start();
    });

    test('success unlocks and builds content', () async {
      final unlocking = lock.unlock();
      expect(lock.phase, AppLockPhase.authenticating);
      platform.answer(AppLockAuthResult.success);
      await unlocking;
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.mayBuildContent, isTrue);
      expect(lock.contentVisible, isTrue);
    });

    test('cancel stays locked with no message and no retry', () async {
      final unlocking = lock.unlock();
      platform.answer(AppLockAuthResult.canceled);
      await unlocking;
      await settle();
      expect(lock.phase, AppLockPhase.locked);
      expect(lock.message, isNull);
      expect(platform.reasons, hasLength(1), reason: 'never retried');
    });

    test('failures show a generic message', () async {
      for (final result in [
        AppLockAuthResult.lockedOut,
        AppLockAuthResult.noScreenLock,
        AppLockAuthResult.failed,
      ]) {
        final unlocking = lock.unlock();
        platform.answer(result);
        await unlocking;
        expect(lock.phase, AppLockPhase.locked);
        expect(lock.message, isNotNull);
        expect(lock.contentVisible, isFalse);
      }
    });

    test(
      'a second tap while prompting does not start another prompt',
      () async {
        final first = lock.unlock();
        await lock.unlock();
        await lock.unlock();
        expect(platform.reasons, hasLength(1));
        platform.answer(AppLockAuthResult.success);
        await first;
      },
    );

    test('a result after dispose is ignored', () async {
      final unlocking = lock.unlock();
      lock.dispose();
      platform.answer(AppLockAuthResult.success);
      await unlocking;
      expect(lock.phase, AppLockPhase.authenticating);
      lock = make(); // for tearDown
    });

    test(
      'success delivered while away and a late return stays locked',
      () async {
        final unlocking = lock.unlock();
        lifecycle = AppLifecycleState.paused;
        lock.didChangeAppLifecycleState(AppLifecycleState.paused);
        platform.answer(AppLockAuthResult.success);
        await settle();
        expect(lock.contentVisible, isFalse);
        platform.now = platform.now! + 4000;
        await returnToApp();
        await unlocking;
        expect(lock.phase, AppLockPhase.locked);
        expect(lock.contentVisible, isFalse, reason: 'late return is a leave');
        expect(platform.prompts, hasLength(1), reason: 'no automatic retry');
      },
    );

    test('PIN or pattern screen: success just before resume unlocks', () async {
      final unlocking = lock.unlock();
      lifecycle = AppLifecycleState.paused;
      lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      platform.answer(AppLockAuthResult.success);
      await settle();
      platform.now = platform.now! + 300;
      await returnToApp();
      await unlocking;
      await settle();
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.contentVisible, isTrue);
    });

    test('Face ID: success while inactive unlocks on prompt return', () async {
      final unlocking = lock.unlock();
      lifecycle = AppLifecycleState.inactive;
      lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
      platform.answer(AppLockAuthResult.success);
      await settle();
      await returnToApp();
      await unlocking;
      await settle();
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.contentVisible, isTrue);
    });

    test('a pending background success is dropped on dispose', () async {
      final unlocking = lock.unlock();
      lifecycle = AppLifecycleState.paused;
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      platform.answer(AppLockAuthResult.success);
      await settle();
      lock.dispose();
      await unlocking;
      expect(lock.contentVisible, isFalse);
      lock = make();
    });
  });

  group('relock timing', () {
    test('a short leave within the grace period does not lock', () async {
      await startUnlocked(relockSeconds: 60);
      leave();
      await settle();
      expect(lock.contentVisible, isFalse, reason: 'covered while away');
      platform.now = platform.now! + 59 * 1000;
      await returnToApp();
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.contentVisible, isTrue);
    });

    test('reaching the grace period locks and prompts once', () async {
      await startUnlocked(relockSeconds: 60);
      leave();
      await settle();
      platform.now = platform.now! + 60 * 1000;
      await returnToApp();
      expect(lock.phase, AppLockPhase.authenticating);
      expect(platform.reasons.last, 'Unlock MailBurrow');
      platform.answer(AppLockAuthResult.canceled);
      await settle();
      expect(lock.phase, AppLockPhase.locked);
      expect(platform.prompts, hasLength(1), reason: 'no automatic retry');
    });

    test('immediately locks on any leave', () async {
      await startUnlocked(relockSeconds: 0);
      leave();
      await settle();
      await returnToApp();
      expect(lock.contentVisible, isFalse);
      expect(lock.phase, AppLockPhase.authenticating);
    });

    test('an unknown clock counts as expired', () async {
      await startUnlocked(relockSeconds: 300);
      platform.now = null;
      leave();
      await settle();
      await returnToApp();
      expect(lock.contentVisible, isFalse);
    });

    test('a clock that went backwards counts as expired', () async {
      await startUnlocked(relockSeconds: 300);
      leave();
      await settle();
      platform.now = platform.now! - 1;
      await returnToApp();
      expect(lock.contentVisible, isFalse);
    });

    test('inactive only covers; it is not a leave', () async {
      await startUnlocked(relockSeconds: 0);
      lifecycle = AppLifecycleState.inactive;
      lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(lock.contentVisible, isFalse);
      await returnToApp();
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.contentVisible, isTrue);
    });

    test('leaving while locked prompts once on return', () async {
      entries.values[AppLockStore.entry] = stored(true, 60);
      lock = make();
      lifecycle = AppLifecycleState.paused;
      await lock.start();
      expect(platform.reasons, isEmpty, reason: 'no prompt while away');
      await returnToApp();
      expect(platform.reasons, hasLength(1));
    });
  });

  group('settings changes', () {
    test('turning on needs a successful prompt, then saves', () async {
      lock = make();
      await lock.start();
      final enabling = lock.enable();
      await settle();
      expect(entries.values.containsKey(AppLockStore.entry), isFalse);
      platform.answer(AppLockAuthResult.success);
      expect(await enabling, isNull);
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.settings!.relockAfter, AppLockSettings.defaultRelock);
      expect(entries.values[AppLockStore.entry], stored(true, 60));
      expect(platform.privacy.last, isTrue);
    });

    test('no screen lock: explains and stays off without prompting', () async {
      platform.supported = false;
      lock = make();
      await lock.start();
      expect(await lock.enable(), contains('screen lock'));
      expect(lock.phase, AppLockPhase.off);
      expect(platform.reasons, isEmpty);
    });

    test('a cancelled prompt leaves it off', () async {
      lock = make();
      await lock.start();
      final enabling = lock.enable();
      await settle();
      platform.answer(AppLockAuthResult.canceled);
      expect(await enabling, isNull);
      expect(lock.phase, AppLockPhase.off);
      expect(entries.writes, 0);
    });

    test('a save failure reports honestly and stays off', () async {
      lock = make();
      await lock.start();
      entries.writeError = Exception('write failed');
      platform.autoAnswer = AppLockAuthResult.success;
      expect(await lock.enable(), contains('still off'));
      expect(lock.phase, AppLockPhase.off);
    });

    test('turning off needs a fresh prompt and a durable save', () async {
      await startUnlocked();
      entries.writeError = Exception('write failed');
      platform.autoAnswer = AppLockAuthResult.success;
      expect(await lock.disable(), contains('still on'));
      expect(lock.phase, AppLockPhase.unlocked);
      expect(lock.enabled, isTrue);
      entries.writeError = null;
      expect(await lock.disable(), isNull);
      expect(lock.phase, AppLockPhase.off);
      expect(platform.privacy.last, isFalse);
    });

    test('a cancelled prompt does not turn it off', () async {
      await startUnlocked();
      final disabling = lock.disable();
      await settle();
      platform.answer(AppLockAuthResult.canceled);
      await disabling;
      expect(lock.enabled, isTrue);
    });

    test('changing the timing needs a fresh prompt', () async {
      await startUnlocked();
      final changing = lock.setRelockAfter(Duration.zero);
      await settle();
      expect(lock.settings!.relockAfter, const Duration(minutes: 1));
      platform.answer(AppLockAuthResult.success);
      await changing;
      expect(lock.settings!.relockAfter, Duration.zero);
      expect(entries.values[AppLockStore.entry], stored(true, 0));
    });

    test('unsupported timings are refused without prompting', () async {
      await startUnlocked();
      await lock.setRelockAfter(const Duration(seconds: 30));
      expect(platform.reasons, hasLength(1), reason: 'only the startup unlock');
    });

    test('a leave during a failed settings prompt is still judged', () async {
      await startUnlocked(relockSeconds: 60);
      final changing = lock.setRelockAfter(Duration.zero);
      await settle();
      leave();
      await settle();
      platform.now = platform.now! + 120 * 1000;
      await returnToApp();
      platform.answer(AppLockAuthResult.canceled);
      await changing;
      await settle();
      expect(lock.contentVisible, isFalse, reason: 'time away exceeded');
    });

    test(
      'a successful settings prompt does not count its own time away',
      () async {
        await startUnlocked(relockSeconds: 60);
        final changing = lock.setRelockAfter(const Duration(minutes: 5));
        await settle();
        leave();
        await settle();
        platform.now = platform.now! + 120 * 1000;
        await returnToApp();
        platform.answer(AppLockAuthResult.success);
        await changing;
        await settle();
        expect(lock.phase, AppLockPhase.unlocked);
        expect(lock.contentVisible, isTrue);
      },
    );
  });

  group('back', () {
    test('is consumed only while content is hidden', () async {
      await startUnlocked();
      expect(await lock.didPopRoute(), isFalse);
      leave();
      expect(await lock.didPopRoute(), isTrue);
    });
  });

  group('gate', () {
    Widget app(AppLockController controller) => MaterialApp(
      builder: (context, child) => AppLockScope(
        controller: controller,
        child: AppLockGate(controller: controller, child: child!),
      ),
      home: const Scaffold(
        body: Column(
          children: [
            Text('Secret subject line'),
            TextField(key: Key('hidden-field')),
            AppLockSettingsTiles(),
          ],
        ),
      ),
    );

    testWidgets('nothing behind a startup lock is built', (tester) async {
      entries.values[AppLockStore.entry] = stored(true, 60);
      lock = make();
      await tester.runAsync(lock.start);
      await tester.pumpWidget(app(lock));
      await tester.pump();
      expect(find.text('Secret subject line'), findsNothing);
      expect(find.text('MailBurrow is locked'), findsOneWidget);
      expect(find.byKey(const Key('app-lock-unlock')), findsOneWidget);
    });

    testWidgets('hidden content cannot be seen, read or touched', (
      tester,
    ) async {
      await tester.runAsync(() => startUnlocked());
      await tester.pumpWidget(app(lock));
      expect(find.text('Secret subject line'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hidden-field')));
      await tester.pump();
      lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const Key('app-lock-surface')), findsOneWidget);
      // Offstage: no hit testing, painting or semantics; focus is removed.
      expect(find.text('Secret subject line'), findsNothing);
      expect(
        find.text('Secret subject line', skipOffstage: false),
        findsOneWidget,
        reason: 'kept alive, not rebuilt',
      );
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()),
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Secret subject line'), findsNothing);
      semantics.dispose();
    });

    testWidgets('Settings shows the switch and timing', (tester) async {
      await tester.runAsync(() => startUnlocked());
      await tester.pumpWidget(app(lock));
      expect(find.text('App lock'), findsOneWidget);
      expect(find.text('After 1 minute'), findsOneWidget);
    });

    testWidgets('Settings hides app lock when it is not set up', (
      tester,
    ) async {
      lock = make();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AppLockSettingsTiles())),
      );
      expect(find.text('App lock'), findsNothing);
    });
  });
}
