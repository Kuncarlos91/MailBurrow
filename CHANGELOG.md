# Changelog

All notable changes to MailBurrow are recorded here. Versions follow the app version shown in Settings.

## Unreleased (feature/open-archiver)

Groundwork for a second archive server type; no visible change for Mail-Archiver users.

- Backend method parameters, reader and attachment handles use text identifiers. Mail-Archiver keeps numeric wire IDs; UUID-like IDs no longer require integer casts in shared calls.
- Backends return typed results (accounts, mail pages and summaries, messages, totals) instead of Mail-Archiver JSON maps, so screens no longer depend on one server's field names. Mail-Archiver and the demo convert their JSON at the backend boundary, and malformed responses are rejected there. Capabilities remain separate groundwork.
- Typed JSON decoders reject wrong text/boolean types, invalid attachment metadata and impossible paging bounds with safe format errors rather than silently showing blank content or failing with cast errors.

- The saved connection now records its server type and stores the selected account ID as text (format version 2). Connections saved by 0.3.0-rc.9 and earlier migrate automatically on the next successful connection and keep the selected account.
- Reject ambiguous saved records with an explicit null version or a server type without a version before creating an API client; preserve the stored record for recovery.

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
