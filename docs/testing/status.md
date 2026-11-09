# Project status

[Main index](../../README.md) · [Device testing checklist](device-checklist.md)

MailBurrow is an early preview, published as source. There is no public signed APK, IPA or store listing yet.

| Area | Status |
| --- | --- |
| Features | Read-only browsing, search, filters, paging, safe reader, attachment save/open and account switching are implemented. Mail-Archiver is the only supported backend. |
| Automated checks | Flutter analysis, Flutter host tests, Python helper tests, documentation links and the privacy scan run in [CI](../development/setup-and-ci.md) on pushes and pull requests. |
| Android | Earlier preview builds were tested on real devices. The newest source changes (the shared backend interface) pass host tests; **device regression is pending**. |
| iOS / iPadOS | Builds from source on macOS. **Device regression of the newest changes is pending.** No public TestFlight or App Store build. |
| Downloads | None yet. Signed releases will be published on the [Releases page](https://github.com/Kuncarlos91/MailBurrow/releases) when ready. |

Automated tests do not replace device testing. Before any binary release, run the [device testing checklist](device-checklist.md) on the exact build being published.
