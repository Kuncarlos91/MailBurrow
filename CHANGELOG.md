# Changelog

All notable changes to MailBurrow are recorded here. Versions follow the app version shown in Settings.

## Unreleased

- **Demo mode:** **Try the demo** on the setup screen opens a built-in archive of fictional mail (three accounts, 70 messages, small attachments), so the app can be explored without a server. It is always labelled with a "Demo · sample mail" bar, never saved and makes no network requests; exit from the bar or Settings.

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
