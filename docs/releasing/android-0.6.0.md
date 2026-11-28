# Android 0.6.0

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [0.5.0 release](android-0.5.0.md)

## Status and identity

**Candidate, not built.** `main` contains app lock (#76) and private CA support (#80–#87). No signed build 33 exists yet, and nothing here authorizes signing, publication or deploying the website. Record the source commit, file size and SHA-256 only once the maintainer has built and checked the exact APK. Never record keys, certificate fields, private hosts, server addresses or raw logs here.

| Item | Value |
| --- | --- |
| Android version / code | `0.6.0` / `33` (reserved in #78) |
| Settings stamp | `0.6.0 (33)` |
| Release application ID | `com.kuncarlos91.mailburrow` (unchanged) |
| Source commit | Pending: the exact `main` commit that is built |
| File | Pending: `MailBurrow-0.6.0-build33.apk` |
| SHA-256 | Pending |
| Signing | Existing maintainer release key |
| ABI | arm64-v8a only |
| Toolchain | Flutter 3.47.8, Dart 3.13.7, locked dependencies |

Build command, from the repository root with the existing signing configuration:

```sh
flutter build apk --release --target-platform android-arm64 --build-name=0.6.0 --build-number=33 --dart-define=MAILSHELF_BUILD_VERSION=0.6.0 --dart-define=MAILSHELF_BUILD_NUMBER=33
```

Test APKs from the `android-test-apk` workflow are debug builds. Their passes support the release but don't stand in for the signed build-33 checks below.

## What is in 0.6.0

- **App lock** (**Settings → App lock**): fingerprint or face, with the device PIN, pattern or password as backup. It relocks immediately, after 1 minute (the default) or after 5 minutes away, and recent apps show a blank preview while locked.
- **Your own certificate per archive:** trust a home CA's root or a self-signed server certificate for one archive, after comparing its SHA-256 fingerprint. Hostname and validity checks stay on and can't be skipped.
  - Certificates with critical name constraints, policy constraints or extended key usage are refused.
  - An imported CA's own path-length limit is not applied; limits on intermediates below it are. The confirmation screen says so before you trust a CA.
  - Saved archives with a certificate use index version 4, which 0.5.0 can't read.
- **Setup** shows the app version and build before connecting.

Full list: [CHANGELOG](../../CHANGELOG.md).

## Checks on the exact APK

**Artifact checks** (same as 0.5.0):
- package and version;
- not debuggable;
- permissions: `INTERNET` and `USE_BIOMETRIC`, plus AndroidX's app-private receiver permission; record anything else the merged manifest adds (for example a fingerprint permission from `local_auth`) before release;
- arm64-v8a only;
- the privacy scan finds 0 findings;
- the established signing certificate;
- bundled notices readable, including `pointycastle` and `androidx.biometric`;
- the installed copy's hash matches.

**Device checks**, on the exact APK (see the [device checklist](../testing/device-checklist.md), items 9 to 11):
- **Update from 0.5.0** (build 31) keeps saved archives, names, the selected account and keys.
- **App lock:** biometric and PIN fallback, each timing, cancelling the prompt, the blank recent-apps preview, swipe away and reopen, saving an attachment within the grace period, and turning it off.
- **Own certificate**, with fictional lab certificates only:
  - the Caddy lab: import, hostname refusal, restart, remove and re-import, attachment save;
  - a CA with a critical name constraint is refused;
  - the CA-limit warning shows for root and intermediate CAs, not for a self-signed server, and stays readable at the largest text size;
  - a chain over an intermediate's limit is refused before any request.
- **Regression pass:** Mail-Archiver, Open Archiver and Bichon browse, search, reader and attachment save; offline and Tailscale recovery; the demo; largest text in landscape.

## Release decisions

To be completed after the checks. Carry forward unless retested: TalkBack, expired Open Archiver keys (not before 2026-12-12), cancellation timing and retention, as described for [0.5.0](android-0.5.0.md#release-decisions). iOS/iPadOS stays source-only until a TestFlight run is separately approved.

## Release notes (draft)

**MailBurrow 0.6.0 - Android (build 33)**

A read-only mobile viewer for your own Mail-Archiver, Open Archiver or Bichon server. This release adds app lock and lets you trust your own certificate for an archive.

- **App lock:** turn it on in **Settings → App lock**. MailBurrow asks for your fingerprint or face, with your device PIN, pattern or password as the backup, and relocks immediately, after 1 minute or after 5 minutes away. Archive content is hidden while locked, including in recent apps.
- **Your own certificate:** if your archive uses a home certificate authority (such as step-ca, Caddy, OPNsense or TrueNAS) or a self-signed certificate, add it in setup under **Advanced**, or later in **Settings → Archives → ⋮ → Certificate**. Compare the fingerprint with your server before you trust it. It applies to that archive only, and certificate checks can't be skipped. See the [setup guide](https://mailburrow.pages.dev/setup.html#own-certificate).
- **Setup** now shows the app version and build.

**Known limits:**
- **Own certificate:** an imported CA's own limit on how many other CAs it can authorize is not applied; limits on intermediates below it are. Import your root CA rather than an intermediate when you can. Certificates with critical name constraints, policy constraints or extended key usage are refused.
- **Going back:** once an archive has its own certificate, 0.5.0 and earlier can't read any saved archive and offer to remove them all. Don't install an older version.
- **Carried over from 0.5.0:** TalkBack untested, expired Open Archiver keys untested, unmeasured cancellation timing, Bichon Pro/Enterprise untested.
- **Mail and attachments:** complex mail may use a simplified layout. Links and attachments are not malware-scanned. Attachment downloads are limited to 50 MiB and two minutes.
- **Not included:** sending or deleting mail, an offline mail cache, analytics and crash-report upload.
- **Devices:** 64-bit ARM (arm64-v8a) Android only. There's no iOS download.

Installs as an update over 0.5.0 without losing saved archives. Compare the APK's SHA-256 with the value on this release page before installing.
