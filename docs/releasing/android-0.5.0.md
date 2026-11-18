# Android 0.5.0

[Main index](../../README.md) · [Build/signing guide](android.md) · [Device checklist](../testing/device-checklist.md) · [0.4.0 release](android-0.4.0.md)

## Status and identity

**Released 2026-11-17** as the latest GitHub release, tag `v0.5.0`. The maintainer reports that build 31 from `d56777fb3476e458e5300458bc59c0075a71721b` passed the artifact and device checks below. The app inputs at the tagged `main` commit must be identical to that commit; otherwise this APK is not the one tested. This page summarizes the release. Detailed measurements and build records stay in the maintainer's private release records. Never record keys, certificate fields, private hosts, server addresses or raw logs here.

| Item | Value |
| --- | --- |
| Android version / code | `0.5.0` / `31` |
| Settings stamp | `0.5.0 (31)` |
| Release application ID | `com.kuncarlos91.mailburrow` (unchanged) |
| File | `MailBurrow-0.5.0-build31.apk`, 20,336,658 bytes |
| SHA-256 | `3688b9e2c17056ca247317f28628f9478980e7971b8ef4e2ace25a305a0646c7` |
| Signing | Existing maintainer release key |
| ABI | arm64-v8a only |
| Toolchain | Flutter 3.47.8, Dart 3.13.7, locked dependencies |

Builds 28 to 30 were private candidates on the maintainer's phone. Each was replaced before release by a fix or a requested change, so none of their passes transfer to build 31.

## What is in 0.5.0

- **Bichon 2.4.2 Community** as a third server type. Connect with an access token for a read-only user: global Member role and Account viewer on the accounts the phone should read. Bichon accounts appear as accounts and mailboxes as folders, without folder counts. Search is literal, messages open as parsed text/HTML with remote content blocked, and attachments download only when you save one.
- The **same archive and account rows** on Mail, Search and Settings. Tapping an archive in **Settings → Archives** opens it.
- **Folder limits:** at most 2,000 folders and nesting depth 32. Larger or malformed folder lists are refused instead of freezing the app.
- **Recovery:** retrying mail after a connection drop also retries folders that failed.

Full list: [CHANGELOG](../../CHANGELOG.md).

## Checks on the exact APK

**Artifact checks:**
- package and version;
- not debuggable;
- permissions: `INTERNET` only, plus AndroidX's app-private receiver permission;
- arm64-v8a only;
- the privacy scan found 0 findings;
- the established signing certificate;
- bundled notices readable (`NOTICES.Z` and the Guava license matching the repository);
- the installed copy's hash matches.

**Device checks** were maintainer-reported, on a Galaxy S24 Ultra with Android 17:
- **Update from 0.4.0:** a direct update from the published 0.4.0 (build 27) kept saved archives, a custom name, the selected account and keys.
- **Mail-Archiver:** browse, search with filters, paging, folders, long messages, reader, and attachment save and open.
- **Open Archiver:** browse and switch sources, search, reader, and attachment save and open.
- **Bichon:**
  - browse, folders and search;
  - reader and attachment save;
  - a revoked token and an expired token were refused;
  - the valid token was restored.
- **Recovery:** offline and Tailscale recovery, and search after airplane mode.
- **Cancel:**
  - Cancel on the Opening screen;
  - Back and **Cancel download** stop a 45 MiB attachment download.
- **Other:**
  - the demo, and force-close and reopen;
  - rename;
  - the largest text in landscape;
  - the license screen offline;
  - Cancel on a link prompt.
- **Memory:** for the recorded warmed Bichon run, peak growth was bounded at about 44.3 MiB (within 64 MiB); after three further open/close cycles, settled RSS was 3.9 MiB below the baseline. This short run does not establish absence of retained objects or long-term growth.

## Release decisions

- **Not tested on the device:**
  - **TalkBack** was not tested on build 31; large text was.
  - **Oversized or malformed folder responses** are covered by automated tests only. No server sent one to the phone.
  - **Open Archiver Preserve Original File** refusal was not retested on build 31. It passed on 0.4.0, and that code is unchanged.
- **Cancellation timing:** cancellation was shown to stop transfers. On the release APK, the exact delay and the bytes read after Back were not measured for message, search or attachment requests. The maintainer accepted this on the combined evidence of a phone probe, the visible stops on build 31 and the automated tests.
- **Retention:** a separate profile-mode phone probe exceeded the 2 MiB retention criterion. A diagnostic follow-up suggested an early rise and a variable plateau; the cause was not proven. The maintainer accepted that observed pattern as an exception. The warmed build-31 sequence ended below its baseline; it does not prove long-term leak freedom or resolve the probe's cause.
- **Expired Open Archiver keys:** still untested, carried over from 0.4.0. The check can run from 2026-12-12.
- **Server versions:** only the versions under [tested servers](../testing/status.md#tested-servers) were tested. Bichon Pro and Enterprise are untested.
- **iOS / iPadOS:** source-only, with 0.5.0 behavior on iOS unverified.

## Release notes

**MailBurrow 0.5.0 - Android (build 31)**

A read-only mobile viewer for your own Mail-Archiver, Open Archiver or Bichon server. This release adds Bichon and shows the same archive and account rows on every tab.

- **Bichon 2.4.2 Community:** choose **Bichon** in setup and enter an access token for a read-only user (Member, with Account viewer on the accounts you need). Browse accounts and folders, search, read messages with remote content blocked, and save attachments. Folder lists show no counts. Search treats your text literally. A Bichon server may record searches; see the [privacy notice](https://mailburrow.pages.dev/privacy.html).
- **Same rows everywhere:** Mail, Search and Settings show the archive and account at the top; tap either to switch. In **Settings → Archives**, tap an archive to open it.
- **Large folder trees:** up to 2,000 folders and depth 32 (root depth zero); larger or malformed lists are refused instead of freezing the app.
- **Recovery:** retrying after a connection drop now also reloads failed folders.

**Tested with** Mail-Archiver 2611.2, Open Archiver 0.6.2 and Bichon 2.4.2 Community on Android 17.

**Known limits:**
- **Bichon:** Pro/Enterprise and other versions are untested.
- **Open Archiver:** expired-key handling is untested.
- **Accessibility:** TalkBack was not tested on this build.
- **Folder robustness:** oversized/malformed folder responses have host-test coverage, but were not exercised on the release device.
- **Open Archiver preserve-original sources:** refusal was not retested on build 31; the earlier 0.4.0 check is historical.
- **Cancellation evidence:** attachment interruption/recovery was observed, but exact client timing/post-cancel bytes and release-APK message/search cancellation remain unmeasured under the maintainer's accepted exception.
- **Mail and attachments:** complex mail may use a simplified layout. Links and attachments are not malware-scanned. Attachment downloads are limited to 50 MiB and two minutes.
- **Not included:** sending or deleting mail, an offline mail cache, analytics and crash-report upload.
- **Devices:** the APK is for 64-bit ARM (arm64-v8a) Android devices only. There's no iOS download, and 0.5.0 behavior on iOS/iPadOS is unverified.

Installs as an update over 0.4.0 without losing saved archives; that update was tested on a device. Compare the APK's SHA-256 with `3688b9e2c17056ca247317f28628f9478980e7971b8ef4e2ace25a305a0646c7` before installing.
