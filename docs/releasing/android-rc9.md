# Android 0.3.0-rc.9 candidate

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [Native license review](../development/android-native-license-review.md)

## Status and identity

**Published as a GitHub prerelease on 2026-11-10:** [v0.3.0-rc.9](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9), tag at the merge of #12. The replacement APK was built from a neutral checkout for arm64-v8a only, cleared the artifact privacy blocker below with 0 findings, passed the recorded signature, package, notice and device checks, and the uploaded asset's SHA-256 matches the frozen file: `8cf7b33f3a7a11ba5de8541f2e111d475224ecac591e2bebb8743ee572ed078b` (19,943,294 bytes). The sections below are kept as the record of the gates.

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

Expected output: `build/app/outputs/flutter-apk/app-release.apk`, containing only `lib/arm64-v8a/` native libraries. `--target-platform` limits only Flutter's own libraries; `android/app/build.gradle.kts` also excludes every non-arm64 native library (for example the `jni` plugin's `libdartjni.so`) from **release** packaging, so the APK is never offered to devices that lack an arm64 Flutter engine. Debug builds keep all ABIs for emulators.

**Why 64-bit ARM only.** A probe release build of this source, signed with a throwaway key on a neutral Linux runner, produced two blocking `email-address-review` findings. Both were in the ARMv7 (`armeabi-v7a`) and x86_64 Flutter engines: BoringSSL's public CRYPTOGAMS author credits in wording the classifier has not reviewed, plus one machine-code byte run in the ARMv7 engine that happens to match the address pattern. In that probe, the arm64-v8a engine's credits were already reviewed. Its Dart app libraries passed only because the runner's checkout path contains no personal directory. Shipping arm64-v8a only keeps those two engines out of the APK without widening the classifier. Devices without ARM64 (arm64-v8a) execution support cannot install it, including 32-bit-only phones and x86 emulators or other devices without ARM64 translation. Some Chromebooks and x86 devices can run ARM64 apps through translation; check the specific device. Android Go branding alone does not determine compatibility. Adding another ABI later requires reviewing its engine strings first; see [artifact privacy rules](../security/artifact-privacy-rules.md#android-abi-scope).

**Changing the ABI does not clear the local signed RC9.** Its arm64 app library also embeds the absolute generated-plugin-registrant URI from the personal checkout (see the blocker below). Only a replacement built from a neutral, non-personal checkout directory, then passing the scan, can clear that. Building locally is permitted for candidate validation, but a local APK with unresolved personal metadata is not a public release candidate. Freeze the exact APK after inspection; any rebuild needs a new hash and affected checks repeated. Record actual results, never keys, personal certificate fields, private hosts or raw logs in Git.

## Known artifact privacy blocker

**Resolved for the published arm64-only APK.** Inspection of a local signed RC9 build flagged five archive entries: three Dart app libraries contain the checkout's absolute generated-plugin-registrant URI, and two Flutter engine libraries contain email-shaped matches requiring reviewed classification. Passing source scans, signature checks or Preview device tests does not clear this artifact gate. See the [Android investigation](../troubleshooting/artifact-privacy.md#android-generated-registrant-paths-and-engine-matches).

Before replacing that artifact (outcome for the published APK `8cf7b33f3a7a…` in each item):

- [x] Merge the final candidate fixes, including any pending PDF viewer fix, and freeze passing source. *#9 (PDF) and #12 (arm64 packaging) merged; tag `v0.3.0-rc.9` = `44d5d45`, required CI passed.*
- [x] Rebuild from a clean, non-personal checkout path. Confirm the generated registrant URI no longer exposes a user's directory in any packaged CPU architecture. Do not allowlist personal paths or patch a signed binary. *Rebuilt from a neutral checkout with the pub cache outside the user profile; no personal-path finding.*
- [x] Build the replacement for arm64-v8a only (command above) and confirm it contains no `armeabi-v7a` or `x86_64` libraries. *Done: only `lib/arm64-v8a/` `libapp.so`, `libdartjni.so` and `libflutter.so`.* The ARMv7 and x86_64 engine matches are excluded from distribution rather than classified. They remain blocking and still need narrowly scoped, provenance-backed handling with negative tests before those ABIs are ever shipped; until then they do not block an otherwise passing arm64-only replacement. No whole-file or whole-domain exclusions; unrelated addresses, credentials and private paths must still block.
- [x] Rescan the exact replacement signed arm64 APK. Public upload stays blocked until it reports **0 findings**, including no personal path in `lib/arm64-v8a/libapp.so`. Then repeat identity/signature/notices checks and device regression, and record its new checksum privately until approved for release. *288 entries, 0 items need review, on both the local file and the downloaded release asset. Follow-up checks are recorded below.*

## Artifact gates - results

- [x] Freeze exact merged source and passing CI; verify locked dependency/notice inputs. *`flutter pub get --enforce-lockfile`; Guava notice input verified below.* No dependency upgrades are included in this preparation.
- [x] Verify release package/version/code; confirm non-debuggable state and merged permissions (no broad media/storage access). *Maintainer-reviewed `aapt2 dump badging`: `0.3.0-rc.9`/`23`, `native-code: 'arm64-v8a'`, not debuggable, no broad storage or media permissions.*
- [x] Settings stamp reads `0.3.0-rc.9 (build 23)`. *Maintainer-confirmed on the device; the stamp appears only after connecting or starting the demo.*
- [x] Verify the release signature against the established trusted certificate with `apksigner verify --print-certs app-release.apk` (Android SDK build-tools). Review the printed certificate DN (name, organization, location, email) before public upload: the APK signing block is not a ZIP entry, so `tools/privacy_check.py` **does not scan the certificate**. Do not replace the key to hide identity; that would break updates for existing installs. `keytool -printcert -jarfile` reads only legacy v1 signatures and may print nothing for this APK. *Maintainer confirmed the established key and reviewed the DN privately; details are not recorded here.*
- [x] Confirm the APK contains only `lib/arm64-v8a/` native libraries. *For later releases, `python tools/check_apk_abis.py <apk>` does this check.*
- [x] Scan the exact APK for credentials, private hosts, personal build paths and other metadata; investigate every finding privately. Do not weaken the classifier to obtain a pass.
- [x] Inspect NOTICES/NOTICES.Z, Flutter/engine entries, required native notices and the Guava asset. Its raw SHA-256 must match committed LF provenance without newline normalization. See the native review for scope and limits. *In the downloaded release asset: `NOTICES.Z` (gzip) holds 1,623 license groups including Flutter, the engine, Dart, Skia, BoringSSL, ICU, zlib, FreeType, HarfBuzz and Apache terms; the Guava entry's raw SHA-256 is `0035edb8…fc1d`, matching the provenance. `version-control-info.textproto` and `app-metadata.properties` contain no personal data.*
- [x] Calculate SHA-256, record file size and provenance. *`8cf7b33f3a7a11ba5de8541f2e111d475224ecac591e2bebb8743ee572ed078b`, 19,943,294 bytes; the uploaded release asset digest and a re-download match.* No tags, Releases assets or automatic uploads are authorized by a successful local build.

## Short device check - maintainer-reported pass (Galaxy S24 Ultra, Android 16)

The maintainer installed the frozen APK as an update and reported all seven checks working. Treat the procedure below as the checklist that was run; per-step evidence is not recorded in Git.

Use harmless synthetic content. Record Pass/Fail/Not tested, device/OS and exact APK hash/build; keep archive settings and messages private.

1. Install the release APK with the correct identity. On an applicable same-ID baseline, update without uninstalling; otherwise test the first-install path. Connect, restart and confirm saved connection/account restoration.
2. Switch authorized accounts while a search is delayed. Old-account mail/folders must not appear afterward. Search, clear, filter, pick dates and page newer/older/go-to-page; verify progress and scrolling.
3. Open long/complex mail, scroll and return. Check date, safe simplified formatting, blocked remote resources and confirmed/cancelled external links.
4. Disconnect the private network, refresh in Mail/Search/Settings, reconnect and retry. Errors must be visible and clear after successful revalidation.
5. Save a harmless attachment locally and to an available cloud provider. Cancel download/retry; cancel Open chooser/reopen; close viewer/reopen without saving again. Cancel a replacement Save and confirm the first reference remains.
6. Start the built-in demo offline. Browse/search/filter/page, switch all three fictional accounts, read long/complex mail and save/reopen a harmless attachment. Check the banner at largest text and landscape, including Connection settings. Test Cancel and exits from the banner, Settings and reader. Verify a saved real connection still restores and relaunch does not restore demo mode.
7. Open Settings > Open source licenses offline. Read Flutter and Guava notices, scroll at largest text/landscape and return without losing account state. Exercise the broader [device checklist](../testing/device-checklist.md) before publication.

## Public prerelease notes - published

**MailBurrow 0.3.0-rc.9 - Android preview (build23)**

A read-only mobile viewer for your own Mail-Archiver: authorized account/folder browsing, server-side search and filters, paging, simplified message reading, and explicit attachment save/open. Configure your own compatible archive, trusted HTTPS endpoint, scoped API key and private-network access if needed. The project does not provide hosting or mail accounts.

Tap **Try the demo** on setup to explore 70 fictional messages across three accounts without a server. The demo banner stays visible; Exit returns to setup without changing a saved real connection. Demo attachments save only when requested, and confirmed links open in your browser.

This is a prerelease, not a stable release. Mail-Archiver is the only supported backend. Complex mail may use simplified layout. Links and attachments are not malware-scanned; attachment downloads are limited to 50 MiB and two minutes. No sending/deleting mail, offline mail cache, analytics or automatic crash-report upload. The APK is for 64-bit ARM (arm64-v8a) Android devices. Devices without ARM64 execution support, including 32-bit-only phones, cannot install it. This release contains no iOS download.

The first signed MailBurrow installation is separate from the old MailShelf app; connect once in the new app. Obtain the APK only from the approved release, compare the supplied SHA-256 and report problems using synthetic steps. Release notes must include the actual source/tag, APK checksum, tested platforms and any remaining known limitations after validation.

## Publication handoff - done

Only after artifact/device checks and explicit approval: tag the tested source, upload the frozen APK and checksum as a GitHub **prerelease**, download the uploaded APK and verify identical bytes/hash, and test the downloaded copy. Update the README/download status only when the asset is actually available. The existing source-only launch does not authorize this step.
