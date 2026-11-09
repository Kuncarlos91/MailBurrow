# Android 0.3.0-rc.9 candidate

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [Native license review](../development/android-native-license-review.md)

## Status and identity

**Preparation only.** No candidate APK has been built, signed, installed, uploaded or approved for publication by this change. All artifact/device gates below start pending. Public source is available; a public binary remains a separate milestone.

| Item | Intended value |
| --- | --- |
| Android version / code | `0.3.0-rc.9` / `23` |
| Settings stamp | `0.3.0-rc.9 (build 23)` |
| Release application ID | `com.kuncarlos91.mailburrow` |
| Debug application ID | `com.kuncarlos91.mailburrow.debug` (not the release candidate) |
| Launcher name | MailBurrow |
| Proposed tag | `v0.3.0-rc.9`, created only after exact-source/artifact approval |
| Signing | Existing maintainer release key; do not generate a replacement |

The older MailShelf Flutter Preview release used a different application ID. This first signed MailBurrow build installs beside it and requires entering the connection once. An existing same-ID signed MailBurrow install can update only with compatible signing and a higher version code. Never uninstall a working baseline just to make an update test pass. Debug installs are separate and are not signing/upgrade evidence for this APK.

This candidate allocates an Android build number only. It does not allocate an App Store Connect build number or publish an iOS build; future iOS uploads must use a separately verified increasing native build number.

## Build and freeze

After this PR merges, select an exact public `main` commit with both required checks passing. Record that commit, pinned Flutter/engine and resolved dependency graph with the candidate's SHA-256. Build from a clean checkout/environment without real messages, private archive settings or extra files. A fresh hosted build can reduce personal build-path metadata, but never proves privacy by itself. Hosted signing/build workflows require separate approval and setup; this preparation creates none.

Use your existing local signing configuration without copying it into Git or logs. From the repository root, the same single-line command works in PowerShell and POSIX shells:

```sh
flutter build apk --release --build-name=0.3.0-rc.9 --build-number=23 --dart-define=MAILSHELF_BUILD_VERSION=0.3.0-rc.9 --dart-define=MAILSHELF_BUILD_NUMBER=23
```

Expected output: `build/app/outputs/flutter-apk/app-release.apk`. Building locally is permitted for candidate validation, but a local APK with unresolved personal metadata is not a public release candidate. Freeze the exact APK after inspection; any rebuild needs a new hash and affected checks repeated. Record actual results, never keys, personal certificate fields, private hosts or raw logs in Git.

## Artifact gates - pending

- [ ] Freeze exact merged source and passing CI; verify locked dependency/notice inputs. No dependency upgrades are included in this preparation.
- [ ] Verify release package/version/code and Settings stamp; confirm non-debuggable state and merged permissions (no broad media/storage access).
- [ ] Verify the release signature against the established trusted certificate. Review the certificate's publicly visible identity fields with the owner before public upload; do not replace the key to hide identity.
- [ ] Scan the exact APK for credentials, private hosts, personal build paths and other metadata; investigate every finding privately. Do not weaken the classifier to obtain a pass.
- [ ] Inspect NOTICES/NOTICES.Z, Flutter/engine entries, required native notices and the Guava asset. Its raw SHA-256 must match committed LF provenance without newline normalization. See the native review for scope and limits.
- [ ] Calculate SHA-256, record file size and provenance. No tags, Releases assets or automatic uploads are authorized by a successful local build.

## Short device check - pending

Use harmless synthetic content. Record Pass/Fail/Not tested, device/OS and exact APK hash/build; keep archive settings and messages private.

1. Install the release APK with the correct identity. On an applicable same-ID baseline, update without uninstalling; otherwise test the first-install path. Connect, restart and confirm saved connection/account restoration.
2. Switch authorized accounts while a search is delayed. Old-account mail/folders must not appear afterward. Search, clear, filter, pick dates and page newer/older/go-to-page; verify progress and scrolling.
3. Open long/complex mail, scroll and return. Check date, safe simplified formatting, blocked remote resources and confirmed/cancelled external links.
4. Disconnect the private network, refresh in Mail/Search/Settings, reconnect and retry. Errors must be visible and clear after successful revalidation.
5. Save a harmless attachment locally and to an available cloud provider. Cancel download/retry; cancel Open chooser/reopen; close viewer/reopen without saving again. Cancel a replacement Save and confirm the first reference remains.
6. Open Settings > Open source licenses offline. Read Flutter and Guava notices, scroll at largest text/landscape and return without losing account state. Exercise the broader [device checklist](../testing/device-checklist.md) before publication.

## Draft public prerelease notes - not published

**MailBurrow 0.3.0-rc.9 - Android preview (build23)**

A read-only mobile viewer for your own Mail-Archiver: authorized account/folder browsing, server-side search and filters, paging, simplified message reading, and explicit attachment save/open. Configure your own compatible archive, trusted HTTPS endpoint, scoped API key and private-network access if needed. The project does not provide hosting or mail accounts.

This is a prerelease, not a stable release. Mail-Archiver is the only supported backend. Complex mail may use simplified layout. Links and attachments are not malware-scanned; attachment downloads are limited to 50 MiB and two minutes. No sending/deleting mail, offline mail cache, analytics or automatic crash-report upload. This release contains no iOS download.

The first signed MailBurrow installation is separate from the old MailShelf app; connect once in the new app. Obtain the APK only from the approved release, compare the supplied SHA-256 and report problems using synthetic steps. Release notes must include the actual source/tag, APK checksum, tested platforms and any remaining known limitations after validation.

## Publication handoff - pending

Only after artifact/device checks and explicit approval: tag the tested source, upload the frozen APK and checksum as a GitHub **prerelease**, download the uploaded APK and verify identical bytes/hash, and test the downloaded copy. Update the README/download status only when the asset is actually available. The existing source-only launch does not authorize this step.
