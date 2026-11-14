# Android 0.4.0 candidate

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [0.3.0-rc.9 record](android-rc9.md)

## Status and identity

**Not built or published.** This page is the plan and checklist for the 0.4.0 release. Keep detailed gate results, device measurements and build records in the maintainer’s private release records. This public page describes required checks; public release notes may include the final source commit, artifact hash, size and tested-version summary. Never record keys, certificate fields, private hosts, server addresses or raw logs here.

| Item | Intended value |
| --- | --- |
| Android version / code | `0.4.0` / `26` |
| Settings stamp | `0.4.0 (build 26)` |
| Release application ID | `com.kuncarlos91.mailburrow` (unchanged) |
| Launcher name | MailBurrow |
| Proposed tag | `v0.4.0`, created only after exact-source/artifact approval |
| Signing | Existing maintainer release key; do not generate a replacement |
| ABI | arm64-v8a only, as for 0.3.0-rc.9 |

Build numbers 24 and 25 were private test builds (`0.4.0-dev.1` and `0.4.0-dev.2`) on the maintainer's phone, so this release uses 26. It is intended to install as an update over 0.3.0-rc.9 and those test builds; the exact APK must pass the upgrade checks below before that claim is published. This allocates an Android build number only; no iOS build is included (see the rc.9 record for iOS version rules).

## What is in 0.4.0

- Open Archiver 0.6.2 as a second server type, chosen explicitly in setup.
- Several saved archives: Add archive, the archive picker, switching, **Settings → Archives** (rename, change address or key, forget), **Enter a new key** for a refused key, and the all-archives reset for unreadable saved data.
- Shorter connection limit (10 s) and **Cancel** while an archive opens.
- Updated setup guide, website, troubleshooting and privacy notice.

Full list: [CHANGELOG](../../CHANGELOG.md).

## Release decisions

- **Expired-key check:** the maintainer chose to release without it. A deleted key is confirmed refused (401) by the lab check; an expired key has not been tested, because the shortest expiry Open Archiver allowed ends on 2026-12-11. The release notes must say so. Run the check on or after 2026-12-12 and retain the result in the private compatibility record. This is a waiver of the expiry check only, not evidence it passed or a waiver of the other release gates.
- **Release type:** a normal GitHub release marked **latest**, not a prerelease (maintainer decision, 2026-11-13). The README and release notes keep the early-preview wording, and the known limits below are stated in the notes.
- **Tested server versions:** Open Archiver `v0.6.2` (`logiclabshq/open-archiver@sha256:ec2e954959f7d0ee0089c4338437720da9b85520a23779cb6d7642943b3ae8e5`) and Mail-Archiver `2611.2` (`ghcr.io/s1t5/mailarchiver@sha256:4baca9cb9dc6f97f2824f62489ba649ededc1095c4555f4d8b87da71349f7ebc`).

## Before building

- [ ] **Preserve Original File source:** import `riverside-garden-club.zip` as a source with Preserve Original File on, rerun `tools/oa_lab_check.py` (the preserve-original check must pass, not skip), and confirm the app refuses that source's messages with its explanation.
- [ ] **Real-backend memory and cancellation:** using synthetic mail on the reference phone, measure peak memory through response reading, MIME parsing and body preparation, including repeated opens, inline resources, nested/encoded mail and inputs near the approved limits. Verify oversized inputs fail safely and real-network cancellation stops reads/cleans temporary files. The earlier before/after samples from a tiny message do not close this gate. Record results against the approved budgets privately.
- [ ] **Compatibility and maintenance:** prepare a backend/version/feature/platform matrix with tested Android behavior and iOS explicitly unverified; identify the maintainer responsible for upstream compatibility monitoring. Do not imply support for untested server versions.
- [ ] Merge this preparation, then merge `feature/open-archiver` into `main` only when the maintainer approves the release. Confirm the website deployment configuration first: if deployment from `main` is automatic, the merge can publish the setup guide and privacy notice before any APK upload. Otherwise, website rendering/deployment is a separate explicit step. Set the notice’s "Updated" date to its actual publication date and keep RC9 download links until the new asset exists.
- [ ] Select the exact `main` commit with all required checks passing. Record the source SHA, pinned Flutter/engine and resolved dependency graph privately; run `flutter pub get --enforce-lockfile` and verify notice inputs without dependency upgrades.

## Build and freeze

Build from a clean checkout outside your user profile (for example `C:\build\mailburrow`), with your existing local signing configuration:

```sh
flutter build apk --release --target-platform android-arm64 --build-name=0.4.0 --build-number=26 --dart-define=MAILSHELF_BUILD_VERSION=0.4.0 --dart-define=MAILSHELF_BUILD_NUMBER=26
```

Expected output: `build/app/outputs/flutter-apk/app-release.apk`. Freeze that exact file; any rebuild needs a new hash and the affected checks repeated.

## Artifact gates

- [ ] `python tools/check_apk_abis.py build/app/outputs/flutter-apk/app-release.apk` passes (arm64-v8a only).
- [ ] `python tools/privacy_check.py --artifact build/app/outputs/flutter-apk/app-release.apk` reports **0 findings**, including no personal path in `lib/arm64-v8a/libapp.so`. Do not weaken the classifier.
- [ ] Package, version `0.4.0`, code `26`, not debuggable, no broad storage or media permissions (`aapt2 dump badging`).
- [ ] `apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk` succeeds and shows the established certificate; review its DN privately before upload.
- [ ] Notices present (`NOTICES.Z`, Guava asset checksum as recorded for rc.9).
- [ ] SHA-256 and file size recorded.

## Device check on the exact APK

Install as an update over the current install on the reference phone (do not uninstall). Retain the earlier private-build results as historical evidence; they do not replace checks on this frozen APK. Verify the direct RC9-to-v3 migration on a preserved RC9 baseline as well as the current v3-to-v3 upgrade; do not erase a working baseline to manufacture that test. If a path was not exercised, record it as not tested. Then:

1. Settings shows `0.4.0 (build 26)`; both saved archives and their selected accounts or sources come back without keys.
2. Mail-Archiver: browse, search with filters, folders, read a long message, save and open an attachment.
3. Open Archiver: browse, attachment-text search, read, save an attachment; a Preserve Original File source's message is refused.
4. Switch archives both ways; rename one in **Settings → Archives**.
5. Airplane mode with Tailscale on: the account list and an archive switch should hit the roughly 10-second address-lookup/connection limit; response-header/body limits remain separate, so do not claim every failure takes 10 seconds. Before persistence starts, **Cancel** on Connecting/Opening returns to setup at once, and late results do not save or activate the abandoned archive. Cancel is disabled during secure persistence and after opening. Retry after the network returns.
6. Demo entry and exit leave both archives saved; force-close and reopen restores the last archive.
7. Settings > Open source licenses offline; largest text and landscape on the archive picker and Opening screen.

## Draft release notes

Use the tested-version and upgrade claims below only after the exact APK passes the relevant gates; replace `<sha256>` with its verified hash.

**MailBurrow 0.4.0 - Android (build 26)**

A read-only mobile viewer for your own Mail-Archiver or Open Archiver server. This release adds Open Archiver and lets you save several archives and switch between them.

- **Open Archiver 0.6.2:** choose the server type in setup. Sources appear as accounts. Browse, search (including text inside attachments), read messages and save attachments. Messages from sources that keep full original files are listed but not opened. No folders or server-wide totals for Open Archiver; search counts are estimates.
- **Several archives:** add up to 20 archives and switch from the archive name above the account, without entering keys again. **Settings → Archives** renames, changes the address or key of, or forgets an archive. If a saved key stops working, the app offers **Enter a new key** for that archive.
- **Faster offline errors:** address lookup and connection have a 10-second limit; response-header/body limits are separate. **Cancel** stops waiting before secure saving begins; it is disabled during the commit and once the archive is open.
- **Setup guide:** includes a read-only Open Archiver role and serving two servers on one machine with Tailscale.

Tested with Open Archiver 0.6.2 and Mail-Archiver 2611.2 on Android 16. **Known limits:** Open Archiver's handling of an *expired* API key has not been tested yet (deleted keys are refused); other Open Archiver versions are untested; complex mail may use a simplified layout; links and attachments are not malware-scanned; attachment downloads are limited to 50 MiB and two minutes. No sending or deleting mail, offline mail cache, analytics or crash-report upload. The APK is for 64-bit ARM (arm64-v8a) Android devices only; no iOS download, and 0.4.0 behavior on iOS/iPadOS is unverified.

Installs as an update over 0.3.0-rc.9; saved connections are kept. Compare the APK's SHA-256 with `<sha256>` before installing.

## Publication handoff

Only after the artifact and device checks and explicit maintainer approval: tag the tested `main` commit `v0.4.0`, create a normal GitHub release marked **latest** (not a prerelease), upload the frozen APK with its checksum, download the uploaded APK and confirm identical bytes, then update the README, status page and website download links to 0.4.0 and remove the now-obsolete RC9-only availability caveats. Verify the live download, setup and privacy pages and publish the tested compatibility matrix. A tag, upload, site deployment or community announcement requires its own explicit approval; this preparation authorizes none of those actions.
