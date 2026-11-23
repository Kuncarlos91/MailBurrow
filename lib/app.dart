import 'package:flutter/material.dart';

import 'app_lock/app_lock_controller.dart';
import 'app_lock/app_lock_gate.dart';
import 'native_license_notices.dart';
import 'screens/archive_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledNativeNotices();
  final appLock = AppLockController()..start();
  runApp(MailShelfPreview(appLock: appLock));
}

class MailShelfPreview extends StatelessWidget {
  const MailShelfPreview({super.key, this.appLock});

  /// App lock; null leaves the app unguarded (used by tests).
  final AppLockController? appLock;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MailBurrow',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff6355b5)),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff6355b5),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    builder: appLock == null
        ? null
        : (context, child) => AppLockScope(
            controller: appLock!,
            child: AppLockGate(controller: appLock!, child: child!),
          ),
    home: const ArchiveHome(),
  );
}
