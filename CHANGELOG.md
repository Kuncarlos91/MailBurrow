# Changelog

All notable changes to MailBurrow are recorded here. Versions follow the app version shown in Settings.

## Unreleased (feature/open-archiver)

Support for a second archive server type, Open Archiver 0.6.2. Mail-Archiver users see a new server-type choice in setup; their saved connections are unchanged.

- Backend method parameters, reader and attachment handles use text identifiers. Mail-Archiver keeps numeric wire IDs; UUID-like IDs no longer require integer casts in shared calls.
- Backends return typed results (accounts, mail pages and summaries, messages, totals) instead of Mail-Archiver JSON maps, so screens no longer depend on one server's field names. Mail-Archiver and the demo convert their JSON at the backend boundary, and malformed responses are rejected there. Each backend now also declares a fixed list of capabilities (folders, filters, sort options, estimated totals, archive totals); Mail-Archiver and the demo report everything. The screens now follow the list: folders, unsupported filter and sort choices, and Settings archive totals are hidden when a server lacks them, and estimated match counts read "about N matches". Nothing changes for Mail-Archiver or the demo. An Open Archiver backend (v0.6.2) can list sources, browse a source and search within it, keeping only the list fields from search results. It can also open messages within the approved phone limits, refusing sources that keep full original messages (attachments included) before downloading anything. Malformed or duplicate detail fields and excessive metadata nesting/value counts are rejected; MIME boundary prefixes inside body text no longer truncate messages. Attachments of an opened message save within the existing 50 MiB limit, each checked against its stated size. Download URLs are restricted to the configured HTTPS origin; failed message validation cannot register attachment handles, and reopening removes attachments no longer listed. Setup now has an explicit Mail-Archiver / Open Archiver choice, saved with the connection; the app never guesses the type, and a cancelled or failed change keeps the current connection. Changing server type or opening/cancelling setup clears the unsaved key to prevent accidental reuse with another backend. Preserve-original classification rejects unknown flags, and search timestamps support pre-1970 dates while rejecting out-of-range values. Sort sets cannot change after declaration, and capability checks reject invalid directions and date ranges. The Filters action is hidden entirely when a backend offers no adjustable filters or sort choices.
- Typed JSON decoders reject wrong text/boolean types, invalid attachment metadata and impossible paging bounds with safe format errors rather than silently showing blank content or failing with cast errors. Account address, last-sync and archiving fields keep their "not reported" fallback.

- The saved connection now records its server type and stores the selected account ID as text (format version 2). Connections saved by 0.3.0-rc.9 and earlier keep the selected account through migration.
- Saved connections move to a store that can hold several archives (format version 3): an index without keys and one secure entry per archive's key, written in stages so a failed save never loses the working connection. Existing connections migrate automatically on first start and keep their server type, key and selected account; the archive picker can now switch between saved connections. Store transactions are serialized, ambiguous duplicate IDs are rejected, and unreadable indexes survive ordinary save/forget attempts. Cleanup failures after a committed save are retried without reporting the save as failed.
- **Several archives:** connecting from setup adds an archive instead of replacing the current one (the same server type and address updates that archive's key). The current archive's name, type and host appear above the account; tapping it opens an Archives picker to switch without re-entering keys, or to add another. Switching clears the previous archive's mail before the new one loads and shows which archive is opening; a failed switch names the archive, offers Retry and the saved list, and keeps the previous archive for the next start. Setup lists saved archives when none is open. If saved archives cannot be read by this version, setup offers **Remove all saved archives…**, which needs confirmation, removes only this device's saved archives and keys, and never changes server mail.
- Reject ambiguous saved records with an explicit null version or a server type without a version before creating an API client; preserve the stored record for recovery.

- Adding an archive preserves an unmigrated legacy connection. Confirmed all-archives reset reports credential-deletion failures and remains retryable instead of claiming success.

## 0.3.0-rc.9 (build23) - 2026-11-10

First public Android APK, published as a [GitHub prerelease](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9) from tag `v0.3.0-rc.9`. APK SHA-256 `8cf7b33f3a7a11ba5de8541f2e111d475224ecac591e2bebb8743ee572ed078b`. See the [candidate guide](docs/releasing/android-rc9.md) for the gates it passed.

- Advance source version from RC8/build22; preserve the established MailBurrow app ID and signing configuration.
- **Demo mode:** **Try the demo** opens 70 fictional messages across three accounts, with folders, dates and 11 small attachments, without a server. A labelled banner remains visible throughout demo mode, including Connection settings and the reader; exit returns to setup without changing the saved connection.
- Include the merged demo documentation, privacy wording and Android dark-mode screenshots.
- Android saved PDFs keep a stable PDF viewer type across repeated opens; document type metadata is held only for the reader session.
- Include the shared backend interface and independent backend tests, updated support/privacy destinations, community policies and native-notice provenance now in public source.
- Enforce canonical LF bytes for bundled notice assets, with checksum regression coverage.
- The release APK targets 64-bit ARM (arm64-v8a) only. Devices without ARM64 execution support, including 32-bit-only phones, cannot install it.
- Release APKs package only `arm64-v8a` native libraries, including plugin libraries such as `libdartjni.so`; debug builds keep all ABIs.
- No runtime dependency, permission or iOS upload change is included. Android MIME regression tests use JUnit only in the JVM test configuration.

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
