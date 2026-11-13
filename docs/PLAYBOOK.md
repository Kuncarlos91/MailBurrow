# MailBurrow Playbook

[Main documentation index](../README.md) · [Setup guide](setup-guide.md) · [Troubleshooting](troubleshooting/README.md) · [Maintenance rules](development/documentation.md)

How MailBurrow works today: features, safety rules, architecture, the Mail-Archiver API it uses and the design decisions behind it. Update it in the same change as the code it describes.

## Purpose and scope

MailBurrow is an independent, read-only Flutter client for a Mail-Archiver server. Shared Dart UI supports Android and iOS/iPadOS, with native credential storage, attachment save/open handling and signing. It does not connect directly to Gmail or change archived messages. The operator manages sync, users, API-key permissions and retention.

This describes the current source. Update it with implementation changes; release history is in the [changelog](../CHANGELOG.md).

## Navigation and connection

Mail, Search and Settings share one configured server/key. The Switch account app-bar button and the account rows in Settings open an account picker. It fetches the accounts endpoint with the configured key and offers only returned entries.

Selecting another account cancels/invalidates old mail/folder work, saves its numeric ID in the existing encrypted connection JSON, clears previous messages/folders/query/filters/page/errors and returns to Mail at page 1. The new account's messages/folders then load independently; failures show no previous-account data. Messages remain in their original server accounts; there is no local cross-account mail cache, moving, merging or deletion. Each list/folder request uses the selected account ID, and late old results are ignored. This is shared Android/iOS/iPadOS behavior. A storage failure leaves the previous account selected and reports a sanitized error. The picker remains usable during pending mail loading and is scrollable at large text sizes. A pinned, accessible Switching account progress indicator remains visible while secure selection and the new mail/folder loads are in progress, even when the list was scrolled down. Generation guards prevent an older switch completion from clearing a newer switch indicator. Selecting the current account or cancelling does not reload mail.

On startup, older connection records without accountId select the first returned account and are migrated on successful connection. A remembered ID is restored only if the current accounts response includes it; otherwise the first accessible account is used with a notice and the stored ID is updated. No credentials or mailbox permissions change, and no separate account list/messages are persisted. Server authorization remains authoritative.

Hostnames without a scheme normalize to HTTPS. Explicit HTTP, embedded credentials, query/fragment-bearing addresses and invalid ports are rejected. Optional base paths are preserved. Certificate validation stays enabled, redirects are disabled, and credentials go only to the configured archive. Tailscale is user/operator infrastructure: no network settings or sharing configuration is bundled.

**Demo mode.** **Try the demo** on setup opens a built-in archive of fictional mail instead of a server. `ArchiveSession.startDemo()` adopts a `DemoArchive` without address validation, network access or secure storage, so entering, browsing, switching accounts and exiting never read, write or delete the saved connection. Restore on launch never opens the demo, because it is never stored. A **Demo · sample mail** banner with **Exit** is shown on every screen while the demo is open, including Connection settings opened from it and the message reader. `exitDemo()` (the banner, **Settings → Exit demo**, or Disconnect while in the demo) closes the demo backend, which stops attachment copies in progress and deletes partial files, invalidates in-flight requests and returns to setup; a previously saved real connection can still be retried. Connecting to a real server from setup replaces the demo. The banner's text scaling is capped at 2x so it stays a compact bar at the largest text sizes.

Connection details use platform secure storage under the `connection` key. The saved record (format version 2) holds the **server type** (`mail-archiver`), server address, API key and the selected account ID **as text**; see [connection_store.dart](../lib/state/connection_store.dart). Records from 0.3.0-rc.9 and earlier (version 1: no version or server-type fields, numeric account ID) are read as Mail-Archiver, the only type those builds supported, and rewritten as version 2 on the next successful save. An explicit null version, a server-type field without a version, or an unknown version or server type makes the saved connection unreadable, so the user enters settings again: the app never works out a server's type by probing it with a saved key and never falls back to another type. Startup waits for restoration rather than briefly exposing setup; failures allow retrying saved settings. Disconnect and forget removes those settings and invalidates outstanding requests. It does not delete server mail/user-saved files or revoke the server key.

## Features and rolling design

| Feature | Behavior |
| --- | --- |
| Mail list | Sender initial/avatar, sender, subject, sent date including year (with unavailable-date fallback), attachment indication; folder and paging. |
| Search | Server query, progress/elapsed feedback, one-action clear. Mail tab clears active search. New requests supersede old results; failures show a visible notification with Retry. |
| Folders | Returned hierarchy/counts and All archived mail; selection only. Old responses are ignored after disconnect/replacement. No folder creation/editing. |
| Filters | Inclusive sent-date range with pickers; all/incoming/outgoing; sent/received date, subject, sender or recipient sorting; ascending/descending; reset/apply. Controls grow with large text. Attachment filtering is not implemented. |
| Pagination | Page size 25; Newer/Older, page count and Go to page. Successful navigation scrolls to the first result; failures retain position. |
| Reader | Subject, sender, full sent date/time, bounded prepared body, long-message scrolling, back navigation. Explicit zones use device time; zone-less dates are labelled time zone unspecified. |
| Safe message display | Remote/active content stripped; supported formatting retained. Complex tables flatten or fall back to text. Link confirmation. Simplified display is not a sender trust verdict. |
| Attachments | Confirm save, sanitize filename, private temporary download, destination picker, separate Open confirmation; risky-type caution. |
| Settings | Selected account/server, sync/enabled status, accessible totals/address list, account selection, connection settings, build information and forget. |
| Demo mode | Built-in fictional archive (3 accounts, 70 messages, 11 small attachments) served in memory with the same search, folder, filter, sort, paging, reader and attachment behavior as a server. Always labelled; never saved; no network. |
| Loading/errors | Section loading, empty states, sanitized errors and retry. Mail/Search failures show a snackbar with Retry plus an inline error. |

Unread emphasis, editing/deletion, background sync, offline mail, attachment filtering and server administration are not features.

## Safety and attachment lifecycle

Android remembers the MIME type of an explicitly saved attachment alongside its reader-session URI, so provider metadata changes do not change the viewer chooser on repeat Open. PDF filenames use `application/pdf`; other declared types are normalized, with a generic fallback. Existing-file selections use their own provider type, not the original attachment name. Type metadata is removed when the last reader reference is released. This does not inspect file bytes, scan malware or imply a file is safe; save/open confirmations and URI grants are unchanged.

Mail is untrusted. Body preparation has bounded processing, worker-isolate work and safe fallbacks. Remote images/fonts/scripts/styles are not automatically fetched. Link confirmation is not phishing detection. Spam/Junk context and risky extensions prompt caution; there is no malware scanner.

Attachment downloads enforce a 50 MiB (52,428,800-byte) cap on actual response bytes, a two-minute whole-transfer deadline and a 30-second body idle timeout. Oversized metadata/Content-Length is rejected early; unknown or understated lengths cannot bypass streamed accounting. Cancel download or Back/disposal stops only that transfer, closes its client/output and removes partial private data. The archive connection and unrelated requests remain usable. Disk writes are serialized with cleanup. After download, the destination picker owns cancellation and the underlying reader is guarded while export is pending. No new dependency, endpoint, TLS exception or mail mutation is introduced.

Attachments download only after confirmation into private temporary storage. The user chooses a destination. Source cleanup is attempted after save/cancel/failure; interruption or cleanup failure can leave cache copies. User-saved files persist independently.

Open is separately confirmed. Handles last only for the current reader session. Android tracks granted document URIs in native memory. On iOS the app retains the picker URL with balanced scoped access, returns an opaque token and releases access on message disposal/replacement. No bookmark, destination token or extra attachment copy is persisted. After leaving the reader, use Files or save again.

Saving/opening successfully does not make a file safe. See [privacy](../PRIVACY.md) and [troubleshooting](troubleshooting/README.md).

## Architecture and source map

```text
Flutter UI → ArchiveBackend (implemented by ArchiveApi) → configured HTTPS Mail-Archiver
     ├→ platform secure storage: connection restoration
     ├→ bounded body preparation → safe reader
     └→ confirmed download → native save/open bridge
```

| Component | Source and responsibilities |
| --- | --- |
| Demo mode | [demo_archive.dart](../lib/demo/demo_archive.dart): `DemoArchive`, an `ArchiveBackend` serving [bundled sample data](../assets/demo/archive.json) and attachments with in-memory search, folders, filters, sorting and 25-per-page paging; it never creates an `HttpClient`, and `close()` stops attachment copies. [demo_banner.dart](../lib/demo/demo_banner.dart) is the banner. The data is generated deterministically by [generate_demo_archive.py](../tools/generate_demo_archive.py) using only invented people and RFC 2606 documentation domains; run it after editing the generator, and `--check` (also run by the helper tests) verifies the committed files. [export_demo_eml.py](../tools/export_demo_eml.py) exports the same demo data as one zip of `.eml` files per account, for loading into a test archive server ([test archive servers](development/test-archive-servers.md)). The older [generate_demo_mail.py](../tools/generate_demo_mail.py) instead writes mailbox files for importing into a review server. |
| Account selection | [account_selector.dart](../lib/account_selector.dart): fresh allowed-account list, loading/empty/error/retry states and current-account indication. Parent state handles secure persistence, scoped reset and reload. |
| App/state/navigation | [main.dart](../lib/main.dart) and [app.dart](../lib/app.dart) start the app. [archive_session.dart](../lib/state/archive_session.dart) is a `ChangeNotifier` holding setup, restoration, account switching, folders, search, request generations and pagination; it requests snackbars, focus and scrolling through hooks. [connection_store.dart](../lib/state/connection_store.dart) reads and writes the saved connection in secure storage. [archive_home.dart](../lib/screens/archive_home.dart) owns those UI effects, sheets and tabs, and draws [setup_view.dart](../lib/screens/setup_view.dart), [mail_view.dart](../lib/screens/mail_view.dart) and [settings_view.dart](../lib/screens/settings_view.dart). [message_reader.dart](../lib/screens/message_reader.dart) is the reader. |
| Backend interface | [archive_backend.dart](../lib/archive_backend.dart): the `ArchiveBackend` interface, the only way the app reaches a server (accounts, folders, search, message, attachment download, stats, cancel, close). Account, message and attachment method parameters use opaque text IDs. Mail-Archiver validates numeric wire IDs inside its adapter. Results are typed models from [archive_models.dart](../lib/archive_models.dart) (`ArchiveAccount`, `MailPage`/`MailSummary`, `MailMessage` with `MailAttachment`, `ArchiveStats`); each backend converts its own responses and rejects malformed ones with a `FormatException`, so screens and the session never read a server's JSON. Each backend also declares fixed `ArchiveCapabilities` ([archive_capabilities.dart](../lib/archive_capabilities.dart)): folders, date-range and direction filters, accepted sort fields and orders, whether match totals are estimates, and whether per-key archive totals exist. Capability sort sets are immutable snapshots; declarations require known sort options and the default sent-date/descending sort. `allows()` rejects invalid direction/date-range input as well as unsupported features. Capabilities are never detected by probing a server. Mail-Archiver and the demo report every capability; screens do not consult them yet. Two implementations exist: `ArchiveApi`, the only network-backed one, for Mail-Archiver, and `DemoArchive`, which serves the built-in demo data without any network access (see Demo mode). Support for other archivers would add further network-backed implementations. |
| Shared backend contract | [archive_models.dart](../lib/archive_models.dart) defines the typed results and folder metadata, with `fromJson` factories for the Mail-Archiver JSON shape that the demo data mirrors. Missing optional fields retain their defaults; an account's display-only fields (address, last sync, archiving state) fall back to "not reported" on a wrong type, as in 0.3.0; otherwise wrong field types, non-finite attachment sizes, pages below 1 and negative page counts fail with safe format errors (empty results may report zero pages); [archive_errors.dart](../lib/archive_errors.dart) defines common failures and safe error presentation. The interface and UI import these directly. Mail-Archiver keeps JSON parsing and HTTP behavior in `ArchiveApi`, which re-exports the shared definitions for existing callers. Independent test backends exercise session isolation/cleanup, message-reader errors/retry and attachment progress/cancel/save flows; mocked native channels do not establish device behavior or second-service compatibility. |
| Transport | [archive_api.dart](../lib/archive_api.dart): validated HTTPS, auth, timeouts, bounded JSON, cancellation and safe errors. API calls share one `HttpClient` per connection so TLS connections are reused; cancelling, timing out or failing a call stops only that call: before headers it aborts the request, and after headers it cancels that response's body subscription (abort no longer applies then), dropping that connection. `close()` cancels all calls and closes the client. `ArchiveSession.connect` closes any candidate client it does not adopt. Attachment downloads keep a separate client per transfer. |
| Body/content safety | [message_body.dart](../lib/message_body.dart), [content_safety.dart](../lib/content_safety.dart): sanitization, complex layouts, safe links, file cautions/temp directories. |
| Attachments | [attachments.dart](../lib/attachments.dart), [attachment_download.dart](../lib/attachment_download.dart), [saved_files.dart](../lib/saved_files.dart), [Android bridge](../android/app/src/main/kotlin/com/kuncarlos91/mailburrow/MainActivity.kt), [session MIME policy](../android/app/src/main/kotlin/com/kuncarlos91/mailburrow/SavedAttachmentTypes.kt), [iOS bridge](../ios/Runner/AppDelegate.swift). |
| Filters/dates/pages | [search_filters.dart](../lib/search_filters.dart), [message_date.dart](../lib/message_date.dart), [pagination.dart](../lib/pagination.dart). |
| Settings | [archive_information.dart](../lib/archive_information.dart), [build_information.dart](../lib/build_information.dart). |
| Validation | [Flutter tests](../test), [helpers](../tools), [CI/setup](development/setup-and-ci.md). |

## API contract currently consumed

These are existing implemented calls, not a complete upstream capability catalog. Verify new fields/endpoints against reliable sources or established context. Prefix with the configured server base path. All operations below are GET/read-only; no mail mutations.

| Route below `/api/v1/` | Use and known shape |
| --- | --- |
| `accounts` | Account-object list; established fields include id, emailAddress, lastSync and isEnabled. Selected account matched by id; only returned entries displayed. |
| `stats` | Object with emails/accounts/attachments counts. UI labels totals across accessible accounts, not selected-account totals. Invalid counts fail visibly. |
| `accounts/{id}/folders` | Returned tree flattened for display; do not invent Inbox or treat selection as creation. |
| `emails` | accountId, q, page, pageSize=25, optional folder and filter parameters. Response: items, page, totalPages, optional totalItems. |
| `emails/{id}` | Used fields include subject, from, sentDate, textBody/htmlBody, folderName, attachments. List entries use from, subject, sentDate and hasAttachments. |
| `emails/{emailId}/attachments/{attachmentId}` | Explicitly requested file streamed to a private temporary destination. |

No guessed received-date fallback is used. Attachment indication uses hasAttachments; details use returned attachments. Showing dates/accounts needs no additional detail/attachment fetch.

Local JSON limit: 8 MiB received bytes before decoding, including streamed/declared-size checks, with decoding off the UI isolate. Downloads stream separately. Request generations prevent late results replacing newer searches or forgotten connections. Backend availability/compatibility remain external dependencies.

## Failure and recovery decisions

Preserve useful messages and scroll position on failed refresh. Show Mail/Search errors visibly with Retry, retain the inline error, and preserve current page/query/filter context. Never echo response bodies, keys or private hosts.

Folders/information retain their own loading/errors. A successful section retries a prior failed mail load instead of assuming endpoint permissions are equivalent. Continued denial/timeout becomes the current error. A section success must not dismiss unrelated setup/storage failures.

## Configuration and sensitive-data boundaries

| Repository-root location | Role and preservation rule |
| --- | --- |
| `pubspec.yaml`, `pubspec.lock` | Dependency and native version/build source; docs moves do not upgrade dependencies. |
| `keystore.properties.example` → ignored `keystore.properties` | Android signing config stays at root; keystore stays outside Git. Never overwrite existing local settings. |
| `android/`, `ios/` | Platform projects, IDs, entitlements and native integrations stay in place. |
| `.github/workflows/` | Existing CI/manual signing paths unchanged; docs do not dispatch them. |
| `assets/demo/` | Generated fictional demo archive and attachments; edit the generator, not the files. Must contain only invented people and reserved example domains. |
| `THIRD_PARTY_NOTICES.md` | Root content/path preserved; privacy tooling depends on it. |
| `docs/development/dependencies.md`, `docs/development/native-dependencies.md` | Relocated inventories; generators updated to match. |

Use synthetic examples only, such as archive.example.ts.net. No real keys/messages, private hostnames, signing values, personal paths or raw diagnostic logs.

## Build environment

Use Flutter release commands to regenerate production plugin registration after host/integration tests. Direct Gradle can otherwise see a stale development registrant. On Windows, Flutter may select Android Studio Java independently of JAVA_HOME; an existing compatible Windows JDK can be selected with a process-only Gradle override, preserving certificate validation. See [build troubleshooting](troubleshooting/README.md#windows-android-build-environment).

## Verification and handoff

Run focused tests, appropriate shared checks, privacy/docs checks and diff review. Native changes require compilation/provider/device checks beyond host mocks. Keep evidence honest about untested cases.

Match Dart build defines to native version/build and preserve the app identity so updates install over earlier versions.

## Design decision log

| Date | Decision | Reason/evidence |
| --- | --- | --- |
| 2026-11-01 | Shared Flutter UI plus native security/storage/files | Consistent navigation with platform permissions; native evidence separate. |
| 2026-11-01 | Read-only API and untrusted-email handling | Avoid mutation/automatic active resources; host safety tests plus device checks. |
| 2026-11-01 | Session-only attachment opening | Avoid persistent bookmarks/extra mail copies. |
| 2026-11-01 | Preserve scroll on failure; reset after successful page change | Keep context but expose new page start; paging tests. |
| 2026-11-01 | Explicit account switching | Switching resets account-scoped state, persists only the allowed ID with encrypted connection settings and invalidates old requests; selection/race/storage tests. |
| 2026-11-01 | README is the main index; one rolling playbook plus guides | Discoverable current behavior without stale instructions. |
| 2026-11-09 | Built-in demo mode with fictional data | Lets people and app reviewers try the app without a server. The demo uses the normal `ArchiveBackend` path, is always labelled, never stored and makes no network requests; storage, exit and no-network tests. |
| 2026-11-06 | No offline or local mail cache; mail is fetched only when the user asks to view it | Decision to limit privacy risk: no message lists, bodies or attachments are kept on the device between views. Offline reading is out of scope; do not add a cache, prefetching or a local mail database without a new maintainer decision. |

Update affected behavior and decisions with future changes. See [maintenance rules](development/documentation.md).
