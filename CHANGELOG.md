# Changelog

All notable changes to MailBurrow are recorded here. Versions follow the app version shown in Settings.

## Unreleased

- **Added:** optional app lock in **Settings → App lock**. It asks for your fingerprint or face, with your device PIN, pattern or password as the backup, and relocks immediately, after 1 minute (default) or after 5 minutes away. While locked, archive content is hidden, untouchable and blank in recent apps; screenshots stay allowed. Startup stays covered until the setting is read, and a damaged setting never turns the lock off. Turning it off or changing the timing needs a fresh unlock. A successful unlock that arrives while the app is away counts only if the app returns within a few seconds (as with the device PIN/pattern screen or Face ID), time away during a settings save still counts, no new attachment-save dialog opens while locked, and the lock screen scrolls at large text sizes. Android now uses `FlutterFragmentActivity` and an AppCompat launch theme, as the new first-party `local_auth` dependency requires.
- **Changed:** setup now shows the app version and build, using the same build information as Settings, before connecting to a server.
- **iOS:** the bundle ID is now `com.kuncarlos91.mailburrow`, matching Android, and the bundle name is MailBurrow. Earlier TestFlight builds used `com.kuncarlos91.mailshelf`; the new ID installs as a separate app, so saved connections are entered again once.
- **Fixed:** the setup screen's introduction now names Bichon alongside Mail-Archiver and Open Archiver. In 0.5.0 it listed only the first two, though choosing Bichon worked. The introduction now derives its backend names from the selector's shared server-type list, with a regression covering every entry.
- **Changed:** exiting the demo reopens the archive that was open when the demo started, and Cancel on the Opening screen during an archive switch reopens the archive that was open before it. In 0.5.0 both returned to setup. Cancel at startup, or again while the previous archive reopens, still returns to setup, so Cancel never loops; a previous archive forgotten in the meantime is not reopened.
- **Community:** GitHub Discussions for questions, ideas and working setups, linked from the README and the issue chooser. Bugs still go through the issue forms.
- **Docs:** README and project status say iOS 0.5.0 passed internal TestFlight testing on an iPad but is not published on the App Store or public TestFlight.
- README: setup screenshot updated to the 0.5.0 screen with three server types.

## 0.5.0 (build31) - 2026-11-17

Published as the latest [GitHub release](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.5.0) from tag `v0.5.0`. APK `MailBurrow-0.5.0-build31.apk`, 20,336,658 bytes, SHA-256 `3688b9e2c17056ca247317f28628f9478980e7971b8ef4e2ace25a305a0646c7`. Release page and limits: [Android 0.5.0](docs/releasing/android-0.5.0.md).

Support for a third archive server type, Bichon 2.4.2 Community, plus the same archive and account rows on every tab. Saved Mail-Archiver and Open Archiver archives are kept when updating from 0.4.0.

- **Fixed:** folder lists are limited to 2,000 entries and nesting depth 32, malformed Mail-Archiver folder data is refused instead of partly shown, and the folder picker builds rows only as they scroll into view, so an oversized folder tree can no longer freeze the app.
- **Website:** Bichon setup and privacy sections on the website, and the README, status page and issue forms now cover Bichon.
- **Testing tools:** `tools/bichon_lab_check.py` checks a test Bichon server (read-only enforcement, account isolation, message and attachment contracts), with tests against a fake server. `tools/bichon_write_denial.py` checks that the reader token cannot tag, repair or delete mail, using one sacrificial fictional message. `tools/bichon_fixtures.py` writes deterministic fictional fixtures for the Bichon phone measurements, and `tools/bichon_fixture_cleanup.py` removes exactly those fixtures again (dry run by default).
- **Bichon:** Bichon 2.4.2 Community as a third server type in setup, using an access token for a read-only user. Credential messages and recovery say "access token" for Bichon archives; Bichon folders show no counts. Settings now shows the same archive and account rows as Mail and Search, so the archive can be switched from any tab. Tapping another archive in **Settings → Archives** now opens it, as from the Mail page; the list is a radio list, with the current archive selected. The privacy notice describes what Bichon archives send and that a Bichon server may record searches. Includes a read-only `BichonApi` adapter with literal search text and a transport limited to Bichon's read-only search POST.
- **Fixed:** an unexpected server response no longer says to check the Mail-Archiver API when the archive is an Open Archiver server; the message now applies to every server type.
- **Fixed:** after a connection drop, retrying mail from its notice now also retries folders that failed, instead of leaving "Could not load folders" on screen until its own Retry was tapped.
- Refresh the GitHub README with release/build badges, download/demo/setup navigation, tested-server badges, captioned demo screenshots and privacy-preserving feedback links. Update issue forms and issue-chooser links for both supported server types. Move the tested-server table to project status, show the setup screen under Connect, and record the completed 0.4.0 checklist items.

## 0.4.0 (build27) - 2026-11-14

Published as the latest [GitHub release](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.4.0) from tag `v0.4.0`. APK SHA-256 `3cc4c7c1e1f4840b45d9608b2741de37117bcac17e70f68629aca70d4c3fd6e5`.

Release preparation is not artifact or device sign-off. Candidate plan and gates: [Android 0.4.0 candidate](docs/releasing/android-0.4.0.md).

Support for a second archive server type, Open Archiver 0.6.2. Mail-Archiver users see a new server-type choice in setup; their saved connections are unchanged.

- Backend method parameters, reader and attachment handles use text identifiers. Mail-Archiver keeps numeric wire IDs; UUID-like IDs no longer require integer casts in shared calls.
- Backends return typed results (accounts, mail pages and summaries, messages, totals) instead of Mail-Archiver JSON maps, so screens no longer depend on one server's field names. Mail-Archiver and the demo convert their JSON at the backend boundary, and malformed responses are rejected there. Each backend now also declares a fixed list of capabilities (folders, filters, sort options, estimated totals, archive totals); Mail-Archiver and the demo report everything. The screens now follow the list: folders, unsupported filter and sort choices, and Settings archive totals are hidden when a server lacks them, and estimated match counts read "about N matches". Nothing changes for Mail-Archiver or the demo. An Open Archiver backend (v0.6.2) can list sources, browse a source and search within it, keeping only the list fields from search results. It can also open messages within the approved phone limits, refusing sources that keep full original messages (attachments included) before downloading anything. Malformed or duplicate detail fields and excessive metadata nesting/value counts are rejected; MIME boundary prefixes inside body text no longer truncate messages. Attachments of an opened message save within the existing 50 MiB limit, each checked against its stated size. Download URLs are restricted to the configured HTTPS origin; failed message validation cannot register attachment handles, and reopening removes attachments no longer listed. Setup now has an explicit Mail-Archiver / Open Archiver choice, saved with the connection; the app never guesses the type, and a cancelled or failed change keeps the current connection. Changing server type or opening/cancelling setup clears the unsaved key to prevent accidental reuse with another backend. Preserve-original classification rejects unknown flags, and search timestamps support pre-1970 dates while rejecting out-of-range values. Sort sets cannot change after declaration, and capability checks reject invalid directions and date ranges. The Filters action is hidden entirely when a backend offers no adjustable filters or sort choices.
- Typed JSON decoders reject wrong text/boolean types, invalid attachment metadata and impossible paging bounds with safe format errors rather than silently showing blank content or failing with cast errors. Account address, last-sync and archiving fields keep their "not reported" fallback.

- The saved connection now records its server type and stores the selected account ID as text (format version 2). Connections saved by 0.3.0-rc.9 and earlier keep the selected account through migration.
- Saved connections move to a store that can hold several archives (format version 3): an index without keys and one secure entry per archive's key, written in stages so a failed save never loses the working connection. Existing connections migrate automatically on first start and keep their server type, key and selected account; the archive picker can now switch between saved connections. Store transactions are serialized, ambiguous duplicate IDs are rejected, and unreadable indexes survive ordinary save/forget attempts. Cleanup failures after a committed save are retried without reporting the save as failed.
- **Several archives:** connecting from setup adds an archive instead of replacing the current one (the same server type and address updates that archive's key). The current archive's name, type and host appear above the account; tapping it opens an Archives picker to switch without re-entering keys, or to add another. Switching clears the previous archive's mail before the new one loads and shows which archive is opening; a failed switch names the archive, offers Retry and the saved list, and keeps the previous archive for the next start. Setup lists saved archives when none is open. If saved archives cannot be read by this version, setup offers **Remove all saved archives…**, which needs confirmation, removes only this device's saved archives and keys, and never changes server mail.
- Reject ambiguous saved records with an explicit null version or a server type without a version before creating an API client; preserve the stored record for recovery.

- **Testing tools:** `tools/generate_stress_mail.py` generates fictional large and unusual messages for the phone memory check, `tools/sample_app_memory.ps1` reports the app's peak memory over adb, and `tools/oa_stress_check.py` confirms Open Archiver kept each stress case's structure after import.
- README setup screenshot shows the server-type choice.
- **Documentation:** the setup guide, website and README cover Open Archiver 0.6.2, including a read-only role policy (**Admin → Roles**), API keys, serving two servers on one machine with Tailscale, and several saved archives. Troubleshooting adds the Open Archiver messages. The privacy notice covers several saved archives and what Open Archiver sends (attachment text in search results, original messages with inline images, preserve-original sources not opened). The interim feature-branch notes are removed.
- Offline with a VPN such as Tailscale still on, connection errors appear after about 10 seconds instead of up to 30, and **Cancel** on the Connecting and Opening screens and in the account list stops waiting at once without opening or saving anything. Cancellation is disabled during the secure-storage commit; late cancelled restores cannot overwrite a newer attempt’s state.
- If a saved archive's key is no longer accepted, setup offers **Enter a new key** for that archive only; the other archives and their keys are not touched.
- **Settings → Archives:** rename a saved archive, change its address or key, or forget it on this device. Changing an address or key requires entering the key again and validating the connection before it is saved, keeps the server type, and refuses to duplicate another archive; a failed change keeps the saved archive. Forgetting asks for confirmation, removes only that archive's address and key from this device, and never changes server mail or revokes the key; forgetting the open archive returns to setup without opening another.
- Adding an archive preserves an unmigrated legacy connection. Confirmed all-archives reset reports credential-deletion failures and remains retryable instead of claiming success.

- Retrying or switching saved archives clears pending archive edits so later connection attempts cannot overwrite the wrong profile.

- Clarify 0.4.0 versus RC9 setup compatibility, Open Archiver source selection and IP-based rate limits, and privacy disclosures for connection validation, search payloads and key cleanup.

- Correct stress-fixture MIME roles and selected charset bodies; make memory sampling independent of proc field order and Android signal permissions, with explicit measurement limits.

- Harden imported stress-case verification against false passes, malformed responses and server text leaking through MIME diagnostics.

- Leaving a loading reader now cancels its own HTTP request immediately; other archive requests stay active, and late responses cannot prepare or register content for the closed reader.
- Correct Open Archiver revocation terminology and prevent known key reuse from producing misleading expiry-test evidence.

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
