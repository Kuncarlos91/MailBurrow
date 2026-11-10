# Changelog

All notable changes to MailBurrow are recorded here. Versions follow the app version shown in Settings.

## 0.3.0-rc.9 (build23) - preparation

Android candidate for the first public APK prerelease. No APK, tag or release is published by this source change. See the [candidate guide](docs/releasing/android-rc9.md) for draft notes and pending artifact/device gates.

- Advance source version from RC8/build22; preserve the established MailBurrow app ID and signing configuration.
- **Demo mode:** **Try the demo** opens 70 fictional messages across three accounts, with folders, dates and 11 small attachments, without a server. A labelled banner remains visible throughout demo mode, including Connection settings and the reader; exit returns to setup without changing the saved connection.
- Include the merged demo documentation, privacy wording and Android dark-mode screenshots.
- Include the shared backend interface and independent backend tests, updated support/privacy destinations, community policies and native-notice provenance now in public source.
- Enforce canonical LF bytes for bundled notice assets, with checksum regression coverage.
- No dependency, permission or iOS upload change is included. Signed candidate inspection and exact-artifact device checks remain pending.

## Initial public source preview

First public source release of MailBurrow, a read-only Android and iOS client for a self-hosted [Mail-Archiver](https://github.com/s1t5/mail-archiver) server.

- Connect with an HTTPS server address and a Mail-Archiver API key, stored in the device's secure storage.
- Browse archived mail by account and folder, with paging and Go to page.
- Server-side search with date range, direction and sort filters.
- Simplified, safe message reader: remote content is not loaded and links ask before opening.
- Save attachments on request, with size and time limits, then open them from the reader.
- Switch between the mail accounts your key can see.
- Settings with archive totals, account details, build information and open-source licenses.
- No analytics, crash reporting or on-device mail cache.
