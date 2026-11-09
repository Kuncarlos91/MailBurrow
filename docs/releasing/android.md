# Android builds and signing

[Main index](../../README.md) · [Setup and CI](../development/setup-and-ci.md)

For local testing run `flutter build apk --debug --target-platform android-arm64`. Output: `build/app/outputs/flutter-apk/app-debug.apk`. Preview installs separately and is not a release artifact.

For signed builds, create your own keystore outside Git, copy root `keystore.properties.example` to ignored root `keystore.properties`, and set your own keystore path, alias and passwords locally. In Java properties on Windows use forward slashes for paths. Existing users' updates require the same signing key, app ID and a higher version code; do not generate a replacement key for an established app.

Build only after signing configuration is ready. Pass the same version and build number to Flutter's native version flags and to the app's Settings stamp, matching `version:` in `pubspec.yaml` (for example `0.3.0+23`):

```sh
flutter build apk --release \
  --build-name=0.3.0 --build-number=23 \
  --dart-define=MAILSHELF_BUILD_VERSION=0.3.0 \
  --dart-define=MAILSHELF_BUILD_NUMBER=23
```

Use the same flags with `flutter build appbundle --release` for an AAB. APK: `build/app/outputs/flutter-apk/app-release.apk`; AAB: `build/app/outputs/bundle/release/app-release.aab`.

The `MAILSHELF_BUILD_*` defines only control what Settings displays; the legacy name is intentional. Without them, including plain `flutter build apk --release` and debug builds, Settings shows **Build information not supplied** rather than claiming a release identity. Never ship a public release unstamped.

Never commit or upload local artifacts incidentally. Before public distribution verify signature, package/version, non-debuggable flag, merged permissions, notices, privacy metadata, checksum and signed-update/device tests. Run the [device testing checklist](../testing/device-checklist.md) on the exact APK.
