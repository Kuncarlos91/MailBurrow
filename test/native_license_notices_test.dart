import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/native_license_notices.dart';

void main() {
  testWidgets(
    'Android native notice is bundled, complete and registered once',
    (tester) async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      registerBundledNativeNotices();
      expect(await LicenseRegistry.licenses.toList(), isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      registerBundledNativeNotices();
      registerBundledNativeNotices();
      debugDefaultTargetPlatformOverride = null;
      final entries = await LicenseRegistry.licenses.toList();
      expect(entries, hasLength(1));
      expect(
        entries.single.packages.single,
        'com.google.guava:listenablefuture 1.0 (Android)',
      );
      final text = entries.single.paragraphs
          .map((paragraph) => paragraph.text)
          .join(' ');
      expect(text, contains('Copyright (C) 2007 The Guava Authors'));
      expect(text, contains('Version 2.0, January 2004'));
      expect(text, contains('END OF TERMS AND CONDITIONS'));
    },
  );
}
