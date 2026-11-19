# Project status

[Main index](../../README.md) · [Device testing checklist](device-checklist.md) · [Android 0.5.0 release](../releasing/android-0.5.0.md)

MailBurrow is an early preview. The signed Android release [0.5.0](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) is published; there is no IPA or store listing.

| Area | Status |
| --- | --- |
| Features | Read-only browsing, search, filters, paging, safe reader, attachment save/open, account switching and a built-in demo mode with fictional mail are implemented. 0.4.0 added Open Archiver 0.6.2 and up to 20 saved archives with switching; 0.5.0 adds Bichon 2.4.2 Community. |
| Automated checks | Flutter analysis, Flutter host tests, Python helper tests, documentation links and the privacy scan run in [CI](../development/setup-and-ci.md) on pushes and pull requests. |
| Android | Earlier previews and the current demo flow have passed maintainer-reported Android debug-device checks, including offline entry, separate accounts, exits, attachment reopening and large-text landscape. Signed **0.3.0-rc.9/build23** (arm64-v8a only) was rebuilt from a neutral checkout, passed the artifact privacy scan with 0 findings, signature and package checks, and a maintainer device check on a Galaxy S24 Ultra with Android 16 (real archive, demo, PDF save/open, offline recovery, large text and landscape). It was published as a [GitHub prerelease](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9). Signed **0.4.0/build27** (arm64-v8a only) passed the artifact privacy scan, ABI, signature and package checks and a maintainer device check on the same phone, installed as an update; it was published as a [release](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0). Signed **0.5.0/build31** (arm64-v8a only) passed the artifact privacy scan, ABI, signature, package and notice checks and a maintainer device check on the same phone with Android 17, including a direct update from the published 0.4.0; it is published as the [latest release](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0). |
| iOS / iPadOS | The maintainer reports that 0.5.0 passed an internal TestFlight check on an iPad on November 18, 2026, covering setup/demo and a summary pass of the backend, saved-archive, attachment and recovery checklist. This was not an independently observed, item-by-item test record. Quantitative memory/cancellation limits were not measured; A physical iPhone was not tested. **Not published:** no App Store or public TestFlight build, so others build from source on macOS. |
| Downloads | Android: [`MailBurrow-0.5.0-build31.apk`](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) (64-bit ARM only), SHA-256 `3688b9e2c17056ca247317f28628f9478980e7971b8ef4e2ace25a305a0646c7`. Releases are listed on the [Releases page](https://github.com/Kuncarlos91/MailBurrow/releases). |

## Tested servers

These are reviewed release facts recorded for the November 17, 2026 release (0.5.0) and the November 14, 2026 release (0.4.0), not live backend monitoring. Other server versions are unverified.

| Android app | Server tested | Scope and limits |
| --- | --- | --- |
| [0.5.0 (build 31)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) | Mail-Archiver 2611.2 | Browse, search with filters, folders, long messages, reader and attachment save/open on Android 17. |
| [0.5.0 (build 31)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) | Open Archiver 0.6.2 | Source browsing and switching, search, reader and attachment save/open on Android 17. Same limits as 0.4.0; Preserve Original File refusal was not retested on this build. Expired-key handling is untested. |
| [0.5.0 (build 31)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) | Bichon 2.4.2 Community | Read-only Member/Account viewer token: account and folder browsing, search, reader with remote content blocked, attachment save, refused revoked and expired tokens, offline recovery, on Android 17. No folder counts. Pro/Enterprise untested. |
| [0.4.0 (build 27)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) | Mail-Archiver 2611.2 | Browse, search, filters, folders, reader and attachment save/open on Android 16. |
| [0.4.0 (build 27)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) | Open Archiver 0.6.2 | Source browsing, search, reader and attachment saving on Android 16. No folders or archive totals; search counts are estimates. Messages from Preserve Original File sources cannot be opened. Expired-key handling is untested. |

iPhone/iPad builds are source-only for users; 0.5.0 has maintainer-reported internal TestFlight checks on an iPad only. See the [0.5.0 release decisions and limitations](../releasing/android-0.5.0.md#release-decisions) and the [0.4.0 ones](../releasing/android-0.4.0.md#release-decisions).

Automated tests do not replace device testing. Before any binary release, run the [device testing checklist](device-checklist.md) on the exact build being published.
