# Project status

[Main index](../../README.md) · [Device testing checklist](device-checklist.md) · [Android RC9 preparation](../releasing/android-rc9.md)

MailBurrow is an early preview. A signed Android prerelease, [0.3.0-rc.9](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9), is published; there is no IPA or store listing.

| Area | Status |
| --- | --- |
| Features | Read-only browsing, search, filters, paging, safe reader, attachment save/open, account switching and a built-in demo mode with fictional mail are implemented. The published RC9 build supports Mail-Archiver only. The 0.4.0 source adds Open Archiver and multiple saved archives; those features require a 0.4.0 build. |
| Automated checks | Flutter analysis, Flutter host tests, Python helper tests, documentation links and the privacy scan run in [CI](../development/setup-and-ci.md) on pushes and pull requests. |
| Android | Earlier previews and the current demo flow have passed maintainer-reported Android debug-device checks, including offline entry, separate accounts, exits, attachment reopening and large-text landscape. Signed **0.3.0-rc.9/build23** (arm64-v8a only) was rebuilt from a neutral checkout, passed the artifact privacy scan with 0 findings, signature and package checks, and a maintainer device check on a Galaxy S24 Ultra with Android 16 (real archive, demo, PDF save/open, offline recovery, large text and landscape). It is published as a [GitHub prerelease](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9). |
| iOS / iPadOS | Builds from source on macOS. **Device regression of the new demo and other newest changes is pending.** No public TestFlight or App Store build. |
| Downloads | Android: [`MailBurrow-0.3.0-rc.9.apk`](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9) (prerelease, 64-bit ARM only), SHA-256 `8cf7b33f3a7a11ba5de8541f2e111d475224ecac591e2bebb8743ee572ed078b`. Releases are listed on the [Releases page](https://github.com/Kuncarlos91/MailBurrow/releases). |

Automated tests do not replace device testing. Before any binary release, run the [device testing checklist](device-checklist.md) on the exact build being published.
