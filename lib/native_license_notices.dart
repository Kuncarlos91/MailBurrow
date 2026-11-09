import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Add attribution for the native Android dependency missing from Dart notices.
/// Loading is lazy: opening the notice viewer needs no server or network call.
void registerBundledNativeNotices() {
  if (defaultTargetPlatform != TargetPlatform.android || _registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString(
      'assets/licenses/guava-listenablefuture-1.0.txt',
    );
    yield LicenseEntryWithLineBreaks(const [
      'com.google.guava:listenablefuture 1.0 (Android)',
    ], text);
  });
}
