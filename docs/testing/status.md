# Project status

[Main index](../../README.md) · [Device testing checklist](device-checklist.md) · [Android RC9 preparation](../releasing/android-rc9.md)

MailBurrow is an early preview, published as source. There is no public signed APK, IPA or store listing yet.

| Area | Status |
| --- | --- |
| Features | Read-only browsing, search, filters, paging, safe reader, attachment save/open, account switching and a built-in demo mode with fictional mail are implemented. Mail-Archiver is the only supported backend. |
| Automated checks | Flutter analysis, Flutter host tests, Python helper tests, documentation links and the privacy scan run in [CI](../development/setup-and-ci.md) on pushes and pull requests. |
| Android | Earlier previews and the current demo flow have passed maintainer-reported Android debug-device checks, including offline entry, separate accounts, exits, attachment reopening and large-text landscape. A local signed **0.3.0-rc.9/build23** candidate has been built, but **public upload is blocked by artifact privacy findings** (see the [candidate gates](../releasing/android-rc9.md#known-artifact-privacy-blocker)). A corrected signed build, exact-artifact inspection and device regression remain pending. |
| iOS / iPadOS | Builds from source on macOS. **Device regression of the new demo and other newest changes is pending.** No public TestFlight or App Store build. |
| Downloads | None yet. Signed releases will be published on the [Releases page](https://github.com/Kuncarlos91/MailBurrow/releases) when ready. |

Automated tests do not replace device testing. Before any binary release, run the [device testing checklist](device-checklist.md) on the exact build being published.
