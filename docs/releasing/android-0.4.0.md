# Android 0.4.0 candidate

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [0.3.0-rc.9 record](android-rc9.md)

## Status and identity

**Not built or published.** This page is the plan and checklist for the 0.4.0 release. Record results here as each gate passes; never record keys, certificate fields, private hosts, server addresses or raw logs.

| Item | Intended value |
| --- | --- |
| Android version / code | `0.4.0` / `26` |
| Settings stamp | `0.4.0 (build 26)` |
| Release application ID | `com.kuncarlos91.mailburrow` (unchanged) |
| Launcher name | MailBurrow |
| Proposed tag | `v0.4.0`, created only after exact-source/artifact approval |
| Signing | Existing maintainer release key; do not generate a replacement |
| ABI | arm64-v8a only, as for 0.3.0-rc.9 |

Build numbers 24 and 25 were private test builds (`0.4.0-dev.1` and `0.4.0-dev.2`) on the maintainer's phone, so this release uses 26. It installs as an update over 0.3.0-rc.9 and over those test builds. This allocates an Android build number only; no iOS build is included (see the rc.9 record for iOS version rules).

## What is in 0.4.0

- Open Archiver 0.6.2 as a second server type, chosen explicitly in setup.
- Several saved archives: Add archive, the archive picker, switching, **Settings → Archives** (rename, change address or key, forget), **Enter a new key** for a refused key, and the all-archives reset for unreadable saved data.
- Shorter connection limit (10 s) and **Cancel** while an archive opens.
- Updated setup guide, website, troubleshooting and privacy notice.

Full list: [CHANGELOG](../../CHANGELOG.md).

## Release decisions

- **Expired-key check:** the maintainer chose to release without it. A deleted key is confirmed refused (401) by the lab check; an expired key has not been tested, because the shortest expiry Open Archiver allowed ends on 2026-12-11. The release notes must say so. Run the check after that date and record the result here.
- **Tested server versions:** Open Archiver `v0.6.2` (`logiclabshq/open-archiver@sha256:ec2e954959f7d0ee0089c4338437720da9b85520a23779cb6d7642943b3ae8e5`) and Mail-Archiver `2611.2` (`ghcr.io/s1t5/mailarchiver@sha256:4baca9cb9dc6f97f2824f62489ba649ededc1095c4555f4d8b87da71349f7ebc`).

## Before building

- [ ] **Preserve Original File source:** import `riverside-garden-club.zip` as a source with Preserve Original File on, rerun `tools/oa_lab_check.py` (the preserve-original check must pass, not skip), and confirm the app refuses that source's messages with its explanation.
- [ ] Merge this preparation, then merge `feature/open-archiver` into `main` only when the maintainer approves the release. The public website builds from `main`, so the merge publishes the new setup guide and privacy notice; set the privacy notice's "Updated" date to the publication date first.
- [ ] Select the exact `main` commit with all required checks passing.

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
- [ ] `apksigner verify --print-certs` shows the established certificate; review its DN privately before upload.
- [ ] Notices present (`NOTICES.Z`, Guava asset checksum as recorded for rc.9).
- [ ] SHA-256 and file size recorded.

## Device check on the exact APK

Install as an update over the current install on the reference phone (do not uninstall), then:

1. Settings shows `0.4.0 (build 26)`; both saved archives and their selected accounts or sources come back without keys.
2. Mail-Archiver: browse, search with filters, folders, read a long message, save and open an attachment.
3. Open Archiver: browse, attachment-text search, read, save an attachment; a Preserve Original File source's message is refused.
4. Switch archives both ways; rename one in **Settings → Archives**.
5. Airplane mode with Tailscale on: the account list and an archive switch show their error in about 10 seconds, and **Cancel** on the Opening screen returns to the saved list at once. Retry after the network returns.
6. Demo entry and exit leave both archives saved; force-close and reopen restores the last archive.
7. Settings > Open source licenses offline; largest text and landscape on the archive picker and Opening screen.

## Draft release notes

**MailBurrow 0.4.0 - Android (build 26)**

A read-only mobile viewer for your own Mail-Archiver or Open Archiver server. This release adds Open Archiver and lets you save several archives and switch between them.

- **Open Archiver 0.6.2:** choose the server type in setup. Sources appear as accounts. Browse, search (including text inside attachments), read messages and save attachments. Messages from sources that keep full original files are listed but not opened. No folders or server-wide totals for Open Archiver; search counts are estimates.
- **Several archives:** add up to 20 archives and switch from the archive name above the account, without entering keys again. **Settings → Archives** renames, changes the address or key of, or forgets an archive. If a saved key stops working, the app offers **Enter a new key** for that archive.
- **Faster offline errors:** connection attempts give up after 10 seconds, and **Cancel** stops waiting while an archive opens.
- **Setup guide:** includes a read-only Open Archiver role and serving two servers on one machine with Tailscale.

Tested with Open Archiver 0.6.2 and Mail-Archiver 2611.2 on Android 16. **Known limits:** Open Archiver's handling of an *expired* API key has not been tested yet (deleted keys are refused); other Open Archiver versions are untested; complex mail may use a simplified layout; links and attachments are not malware-scanned; attachment downloads are limited to 50 MiB and two minutes. No sending or deleting mail, offline mail cache, analytics or crash-report upload. The APK is for 64-bit ARM (arm64-v8a) Android devices only; no iOS download.

Installs as an update over 0.3.0-rc.9; saved connections are kept. Compare the APK's SHA-256 with `<sha256>` before installing.

## Publication handoff

Only after the artifact and device checks and explicit maintainer approval: tag the tested `main` commit `v0.4.0`, upload the frozen APK with its checksum, download the uploaded APK and confirm identical bytes, then update the README, status page and website download links to 0.4.0.
