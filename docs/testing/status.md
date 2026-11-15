# Project status

[Main index](../../README.md) · [Device testing checklist](device-checklist.md) · [Android 0.4.0 release](../releasing/android-0.4.0.md)

MailBurrow is an early preview. The signed Android release [0.4.0](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) is published; there is no IPA or store listing.

| Area | Status |
| --- | --- |
| Features | Read-only browsing, search, filters, paging, safe reader, attachment save/open, account switching and a built-in demo mode with fictional mail are implemented. 0.4.0 adds Open Archiver 0.6.2 and up to 20 saved archives with switching. |
| Automated checks | Flutter analysis, Flutter host tests, Python helper tests, documentation links and the privacy scan run in [CI](../development/setup-and-ci.md) on pushes and pull requests. |
| Android | Earlier previews and the current demo flow have passed maintainer-reported Android debug-device checks, including offline entry, separate accounts, exits, attachment reopening and large-text landscape. Signed **0.3.0-rc.9/build23** (arm64-v8a only) was rebuilt from a neutral checkout, passed the artifact privacy scan with 0 findings, signature and package checks, and a maintainer device check on a Galaxy S24 Ultra with Android 16 (real archive, demo, PDF save/open, offline recovery, large text and landscape). It was published as a [GitHub prerelease](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9). Signed **0.4.0/build27** (arm64-v8a only) passed the artifact privacy scan, ABI, signature and package checks and a maintainer device check on the same phone, installed as an update; it is published as the [latest release](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0). |
| iOS / iPadOS | Builds from source on macOS. **Device regression of the new demo and other newest changes is pending.** No public TestFlight or App Store build. |
| Downloads | Android: [`MailBurrow-0.4.0-build27.apk`](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) (64-bit ARM only), SHA-256 `3cc4c7c1e1f4840b45d9608b2741de37117bcac17e70f68629aca70d4c3fd6e5`. Releases are listed on the [Releases page](https://github.com/Kuncarlos91/MailBurrow/releases). |

## Tested servers

These are reviewed release facts recorded for the November 14, 2026 release, not live backend monitoring. Other server versions are unverified.

| Android app | Server tested | Scope and limits |
| --- | --- | --- |
| [0.4.0 (build 27)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) | Mail-Archiver 2611.2 | Browse, search, filters, folders, reader and attachment save/open on Android 16. |
| [0.4.0 (build 27)](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) | Open Archiver 0.6.2 | Source browsing, search, reader and attachment saving on Android 16. No folders or archive totals; search counts are estimates. Messages from Preserve Original File sources cannot be opened. Expired-key handling is untested. |

iPhone/iPad builds are source-only, with 0.4.0 device behavior unverified. See [release decisions and limitations](../releasing/android-0.4.0.md#release-decisions).

Automated tests do not replace device testing. Before any binary release, run the [device testing checklist](device-checklist.md) on the exact build being published.
