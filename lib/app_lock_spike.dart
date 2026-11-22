// SPIKE (app lock plan P1). Temporary test tile for device checks; not for merge.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class AppLockSpikeTile extends StatefulWidget {
  const AppLockSpikeTile({super.key});

  @override
  State<AppLockSpikeTile> createState() => _AppLockSpikeTileState();
}

class _AppLockSpikeTileState extends State<AppLockSpikeTile> {
  static const _channel = MethodChannel('mailburrow/app_lock_spike');
  final _auth = LocalAuthentication();
  String _status = 'Not tested yet';
  bool _hidden = false;

  Future<void> _testUnlock() async {
    String status;
    try {
      final supported = await _auth.isDeviceSupported();
      final biometrics = await _auth.getAvailableBiometrics();
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock MailBurrow (test)',
      );
      status =
          'Device supported: $supported; '
          'biometrics: ${biometrics.map((b) => b.name).join(', ')}; '
          'result: ${ok ? 'unlocked' : 'not unlocked'}';
    } on LocalAuthException catch (e) {
      status = 'Failed: ${e.code.name}';
    } on PlatformException catch (e) {
      status = 'Failed: ${e.code}';
    }
    if (mounted) setState(() => _status = status);
  }

  Future<void> _toggleRecents() async {
    if (!Platform.isAndroid) return;
    final next = !_hidden;
    final sdk = await _channel.invokeMethod<int>('sdk');
    final applied = await _channel.invokeMethod<bool>('hideRecents', {
      'hide': next,
    });
    if (!mounted) return;
    setState(() {
      if (applied == true) _hidden = next;
      _status = applied == true
          ? 'Recents preview ${next ? 'hidden' : 'shown'} (Android API $sdk)'
          : 'Recents hiding not available on Android API $sdk';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const Key('app-lock-spike-unlock'),
          title: const Text('App lock test: unlock'),
          subtitle: Text(_status),
          onTap: _testUnlock,
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            key: const Key('app-lock-spike-recents'),
            title: const Text('App lock test: hide in recent apps'),
            value: _hidden,
            onChanged: (_) => _toggleRecents(),
          ),
      ],
    );
  }
}
