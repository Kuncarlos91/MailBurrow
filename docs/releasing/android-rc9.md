# Android 0.3.0-rc.9 candidate

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [Native license review](../development/android-native-license-review.md)

## Status and identity

**Local validation only; public upload blocked.** A local signed candidate has been built and installed for testing, but its artifact privacy findings remain unresolved. It has not been uploaded or approved for publication. The replacement-artifact and device gates below remain pending. Public source is available; a public binary remains a separate milestone.

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

This candidate allocates an Android build number only. It does not allocate an App Store Connect build number or publish an iOS build; future iOS uploads must use a separately verified increasing native build number. iOS uploads must also override the source prerelease version with a numeric version such as `--build-name=0.3.0`; [Apple requires three period-separated integers for CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring), so `0.3.0-rc.9` is not a valid iOS upload version. Keep the Settings build defines consistent with the separately chosen iOS version and build number; do not reuse the Android build23 command for an iOS upload.

## Included source and remaining validation

This candidate includes the merged demo backend, entry/banner/exit flow, documentation/privacy wording and Android demo screenshots. The demo contains 70 fictional messages across three accounts and 11 small attachments; it is available without a server, including in release builds. It never persists a demo connection. Explicit attachment saves and confirmed external links still use the normal file-provider/browser flows.

Android debug-device demo checks have passed, including offline entry, account separation, Connection settings, exit paths, attachment reopening, relaunch and saved-connection recovery, plus largest-text landscape. Those debug results are not evidence that the signed RC9 APK passes; the local signed test build has a separate unresolved privacy gate. The current demo has not yet passed iPad/iOS device validation; iOS build/upload numbering and any metered signing run require separate verification and approval.

The support/privacy templates are updated in source. Their deployment and live-page verification remain separate tasks; merging source does not deploy Cloudflare Pages.

## Build and freeze

After this PR merges, select an exact public `main` commit with both required checks passing. Record that commit, pinned Flutter/engine and resolved dependency graph with the candidate's SHA-256. Build from a clean checkout/environment without real messages, private archive settings or extra files. A fresh hosted build can reduce personal build-path metadata, but never proves privacy by itself. Hosted signing/build workflows require separate approval and setup; this preparation creates none.

Use your existing local signing configuration without copying it into Git or logs. From the repository root, the same single-line command works in PowerShell and POSIX shells:

```sh
flutter build apk --release --target-platform android-arm64 --build-name=0.3.0-rc.9 --build-number=23 --dart-define=MAILSHELF_BUILD_VERSION=0.3.0-rc.9 --dart-define=MAILSHELF_BUILD_NUMBER=23
```

Expected output: `build/app/outputs/flutter-apk/app-release.apk`, containing only `lib/arm64-v8a/` native libraries.

**Why 64-bit ARM only.** A clean release build of this source, signed with a throwaway key on a neutral Linux runner, produces two blocking `email-address-review` findings. Both are in the 32-bit ARM and x86_64 Flutter engines: BoringSSL's public CRYPTOGAMS author credits in wording the classifier has not reviewed, plus one machine-code byte run that happens to match the address pattern in the 32-bit engine. The arm64-v8a engine's credits are already reviewed, and the Dart app library passes. Neither finding involves personal data or the maintainer's machine. Shipping arm64-v8a only avoids widening the classifier and covers current Android phones; 32-bit-only phones, some low-memory Android Go devices and x86 emulators or Chromebooks cannot install this APK. Adding those ABIs later requires reviewing their engine strings first; see [artifact privacy rules](../security/artifact-privacy-rules.md#android-abi-scope). Building locally is permitted for candidate validation, but a local APK with unresolved personal metadata is not a public release candidate. Freeze the exact APK after inspection; any rebuild needs a new hash and affected checks repeated. Record actual results, never keys, personal certificate fields, private hosts or raw logs in Git.

## Known artifact privacy blocker

**Public APK upload is blocked.** Inspection of a local signed RC9 build flagged five archive entries: three Dart app libraries contain the checkout's absolute generated-plugin-registrant URI, and two Flutter engine libraries contain email-shaped matches requiring reviewed classification. Passing source scans, signature checks or Preview device tests does not clear this artifact gate. See the [Android investigation](../troubleshooting/artifact-privacy.md#android-generated-registrant-paths-and-engine-matches).

Before replacing that artifact:

- [ ] Merge the final candidate fixes, including any pending PDF viewer fix, and freeze passing source.
- [ ] Rebuild from a clean, non-personal checkout path. Confirm the generated registrant URI no longer exposes a user's directory in any packaged CPU architecture. Do not allowlist personal paths or patch a signed binary.
- [ ] Complete narrowly scoped, provenance-backed handling of the engine attribution/instruction-pattern matches, with negative tests. No whole-file or whole-domain exclusions; unrelated addresses, credentials and private paths must still block.
- [ ] Rescan the exact replacement signed APK, repeat identity/signature/notices checks and device regression, and record its new checksum privately until approved for release.

## Artifact gates - pending

- [ ] Freeze exact merged source and passing CI; verify locked dependency/notice inputs. No dependency upgrades are included in this preparation.
- [ ] Verify release package/version/code and Settings stamp; confirm non-debuggable state and merged permissions (no broad media/storage access).
- [ ] Verify the release signature against the established trusted certificate with `apksigner verify --print-certs app-release.apk` (Android SDK build-tools). Review the printed certificate DN (name, organization, location, email) before public upload: the APK signing block is not a ZIP entry, so `tools/privacy_check.py` **does not scan the certificate**. Do not replace the key to hide identity; that would break updates for existing installs. `keytool -printcert -jarfile` reads only legacy v1 signatures and may print nothing for this APK.
- [ ] Confirm the APK contains only `lib/arm64-v8a/` native libraries.
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
6. Start the built-in demo offline. Browse/search/filter/page, switch all three fictional accounts, read long/complex mail and save/reopen a harmless attachment. Check the banner at largest text and landscape, including Connection settings. Test Cancel and exits from the banner, Settings and reader. Verify a saved real connection still restores and relaunch does not restore demo mode.
7. Open Settings > Open source licenses offline. Read Flutter and Guava notices, scroll at largest text/landscape and return without losing account state. Exercise the broader [device checklist](../testing/device-checklist.md) before publication.

## Draft public prerelease notes - not published

**MailBurrow 0.3.0-rc.9 - Android preview (build23)**

A read-only mobile viewer for your own Mail-Archiver: authorized account/folder browsing, server-side search and filters, paging, simplified message reading, and explicit attachment save/open. Configure your own compatible archive, trusted HTTPS endpoint, scoped API key and private-network access if needed. The project does not provide hosting or mail accounts.

Tap **Try the demo** on setup to explore 70 fictional messages across three accounts without a server. The demo banner stays visible; Exit returns to setup without changing a saved real connection. Demo attachments save only when requested, and confirmed links open in your browser.

This is a prerelease, not a stable release. Mail-Archiver is the only supported backend. Complex mail may use simplified layout. Links and attachments are not malware-scanned; attachment downloads are limited to 50 MiB and two minutes. No sending/deleting mail, offline mail cache, analytics or automatic crash-report upload. The APK is for 64-bit ARM Android phones (arm64-v8a); it will not install on 32-bit-only phones or x86 emulators and Chromebooks. This release contains no iOS download.

The first signed MailBurrow installation is separate from the old MailShelf app; connect once in the new app. Obtain the APK only from the approved release, compare the supplied SHA-256 and report problems using synthetic steps. Release notes must include the actual source/tag, APK checksum, tested platforms and any remaining known limitations after validation.

## Publication handoff - pending

Only after artifact/device checks and explicit approval: tag the tested source, upload the frozen APK and checksum as a GitHub **prerelease**, download the uploaded APK and verify identical bytes/hash, and test the downloaded copy. Update the README/download status only when the asset is actually available. The existing source-only launch does not authorize this step.
