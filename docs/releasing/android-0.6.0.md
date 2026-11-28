# Android 0.6.0 build instructions and draft release notes

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [0.5.0 release](android-0.5.0.md)

The latest published Android release is [0.5.0](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0). The 0.6.0 release notes below are a draft, not a claim that a release APK is available or has passed device checks.

## Build instructions

The source version is `0.6.0+33`. The release application ID remains `com.kuncarlos91.mailburrow`; release APKs target arm64-v8a. The pinned toolchain is Flutter 3.47.8 / Dart 3.13.7 with locked dependencies.

Follow the [build/signing guide](android.md) for signing configuration and a checkout outside your personal profile. From the repository root:

```sh
flutter build apk --release --target-platform android-arm64 --build-name=0.6.0 --build-number=33 --dart-define=MAILSHELF_BUILD_VERSION=0.6.0 --dart-define=MAILSHELF_BUILD_NUMBER=33
```

Existing users' updates require the same signing key and application ID. Before distributing an APK, verify its package/version, signature, non-debuggable flag, merged permissions, arm64-only libraries, notices, privacy scan and checksum. Follow the [device checklist](../testing/device-checklist.md) on the exact signed APK, including an update from 0.5.0. Debug APKs from `android-test-apk` install separately and do not establish signed-update behavior.

## What is in 0.6.0

- **App lock** (**Settings → App lock**): fingerprint or face, with the device PIN, pattern or password as backup. It relocks immediately, after 1 minute (the default) or after 5 minutes away, and recent apps show a blank preview while locked.
- **Your own certificate per archive:** trust a home CA's root or a self-signed server certificate for one archive, after comparing its SHA-256 fingerprint. Hostname and validity checks stay on and can't be skipped.
  - Certificates with critical name constraints, policy constraints or extended key usage are refused.
  - An imported CA's own path-length limit is not applied on Android; limits on intermediates below it are. The confirmation screen says so before you trust a CA.
  - Saved archives with a certificate use index version 4, which 0.5.0 can't read.
- **Setup** shows the app version and build before connecting.

Full list: [CHANGELOG](../../CHANGELOG.md).

## Release notes (draft)

**MailBurrow 0.6.0 - Android (build 33)**

A read-only mobile viewer for your own Mail-Archiver, Open Archiver or Bichon server. This release adds app lock and lets you trust your own certificate for an archive.

- **App lock:** turn it on in **Settings → App lock**. MailBurrow asks for your fingerprint or face, with your device PIN, pattern or password as the backup, and relocks immediately, after 1 minute or after 5 minutes away. Archive content is hidden while locked, including in recent apps.
- **Your own certificate:** if your archive uses a home certificate authority (such as step-ca, Caddy, OPNsense or TrueNAS) or a self-signed certificate, add it in setup under **Advanced**, or later in **Settings → Archives → ⋮ → Certificate**. Compare the fingerprint with your server before you trust it. It applies to that archive only, and certificate checks can't be skipped. See the [setup guide](https://mailburrow.pages.dev/setup.html#own-certificate).
- **Setup** now shows the app version and build.

**Known limits:**
- **Own certificate:** an imported CA's own limit on how many other CAs it can authorize is not applied on Android; limits on intermediates below it are. Import your root CA rather than an intermediate when you can. Certificates with critical name constraints, policy constraints or extended key usage are refused.
- **Going back:** once an archive has its own certificate, 0.5.0 and earlier can't read any saved archive and offer to remove them all. Don't install an older version.
- **Carried over from 0.5.0:** TalkBack untested, expired Open Archiver keys untested, unmeasured cancellation timing, Bichon Pro/Enterprise untested.
- **Mail and attachments:** complex mail may use a simplified layout. Links and attachments are not malware-scanned. Attachment downloads are limited to 50 MiB and two minutes.
- **Not included:** sending or deleting mail, an offline mail cache, analytics and crash-report upload.
- **Devices:** 64-bit ARM (arm64-v8a) Android only. There's no iOS download.

Installs as an update over 0.5.0 without losing saved archives. Compare the APK's SHA-256 with the value on this release page before installing.
