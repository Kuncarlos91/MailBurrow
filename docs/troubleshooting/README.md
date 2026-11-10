# MailBurrow troubleshooting

[Main index](../../README.md) · [Setup guide](../setup-guide.md) · [Playbook](../PLAYBOOK.md)

For first-time setup problems (API not enabled, key, HTTPS address, Tailscale), start with the [setup guide's checks](../setup-guide.md#if-something-goes-wrong).

## Identify the installed build

Settings shows the app version and build. Include it, with your device and OS version, in any report. On Android, the release app (`com.kuncarlos91.mailburrow`) and debug builds (**MailBurrow Preview**) are separate apps with separate saved settings.

If Android says **App not installed** when updating, the new APK was signed with a different key from the installed app (for example a debug build over a release build). Uninstall the old app first; you will need to enter your server and key again.

## Connection and request failures

| Symptom | Checks/recovery | Relevant component |
| --- | --- | --- |
| Unable to connect/timeout | Check the HTTPS host/base path and that any private network (such as Tailscale) is connected on the phone. Reconnect and Retry. Do not expose the home server to fix a phone issue. | archive_api.dart, state/archive_session.dart |
| Certificate could not be verified | Operator checks name/certificate/chain and device time. Never disable certificate validation. | validateServer, platform TLS |
| Key not accepted (401) | Confirm the key belongs to this archive; the server operator can replace or revoke keys. Never paste a key into a report. | ArchiveFailure/readableError |
| Permission denied (403) | Endpoint authorization differs: working stats do not prove mail/download access. Operator checks scope. | archive_api.dart |
| API/message unavailable (404) | Check API compatibility and message/account existence; do not guess new paths. | archive_api.dart |
| Too many requests (429) | Wait before retrying. | readableError |
| Response too large | The app caps JSON responses at 8 MiB. Use the archive website for that response; review memory/performance before increasing limits. | decodeArchiveJson |
| Folders unavailable | Retry after network recovery. Check account permissions/returned folders. Missing Inbox may be a server sync issue; do not invent it locally. | loadFolders, flattenFolders |

## Mail, search and layout

| Symptom | Interpretation/next step |
| --- | --- |
| Slow search | The server runs queries. Watch the progress/elapsed feedback; old results are not a completed new search. Report approximate duration, query type and archive size without private query contents. |
| Empty results | Check folder/query/date/direction/sort filters; clear/reset deliberately. Empty differs from failed. |
| Need a distant page | Tap the page counter and use Go to page. |
| Large-text filter clipping | Report device, orientation and text size. Reducing accessibility scaling is not the fix. |
| Missing message date | Malformed or missing dates show as unavailable; dates without a zone are labelled time zone unspecified. |
| Simplified layout/text | Expected safety/performance fallback for complex HTML. Remote resources stay blocked. Report unreadability with a synthetic reproduction. |
| One message freezes | Record build/device, approximate size and formatting type. Do not paste private bodies. |
| No unread emphasis | Not implemented; opening a message does not change its server unread state. |

## Attachments

Attachment downloads are capped at 50 MiB and two minutes in total, with a 30-second idle timeout. For larger files use the Mail-Archiver website. During a download choose Cancel download or Back; after the destination picker opens, use its Cancel. Partial temporary files are cleaned up; files you saved are never deleted by the app.

Save and Open have separate confirmations. There is no malware scanning; do not open suspicious files to diagnose the app.

| Symptom | Next step |
| --- | --- |
| Cancelled save | Expected; no Open action appears for a cancelled save. |
| Could not save | Check the destination/provider/storage and retry. An incomplete provider file may remain. A new download needs network access. |
| Unavailable after leaving/reopening the reader | Open handles last only for the reader session. Use Files or save again. Moving/deleting a file or provider permission changes also end access. |
| Cloud provider (for example Nextcloud) fails to open | Try saving to local storage to compare, and report the provider, file type and whether it failed on the first or a later Open. |
| No viewer | Use Files or a trusted viewer for the expected format; do not execute an attachment to diagnose it. |

## Demo mode

| Symptom | Interpretation/next step |
| --- | --- |
| A "Demo · sample mail" bar is showing | You're in the built-in demo: all mail is fictional. Tap **Exit** on the bar, or **Settings → Exit demo**, to return to setup. |
| Try the demo button is missing | It's hidden while the demo is already open, for example on Connection settings opened from the demo. Exit the demo first. |
| Could not open the demo | The bundled sample data could not be read. Try again; if it keeps failing, report the app version and device. |
| My saved server is gone after the demo | The demo never changes a saved connection. On setup, use **Retry saved connection**, or reopen the app to restore it. |
| A demo link doesn't load | Demo links point to reserved example addresses that don't exist, so the browser shows an error. That's expected. |

## Settings and persistence

Totals cover all accounts accessible to the key, not only the selected account. Failed information refresh hides stale details until recovery.

Updates installed over the existing app keep your saved connection. Disconnect and forget removes saved settings without revoking the server key. If startup restore fails, it can be retried.

## Account selector

- Use Switch account in the app bar, tap the current account, or select an accessible account in Settings. Only accounts the server returns for the current key are offered; missing accounts need permission/sync checks on the server.
- Switching progress stays visible while the selection is saved and the new account's mail and folders load.
- Selecting another account returns to Mail, resets query/filters/folder/page and loads that account's data. A failed load never shows the previous account's mail.
- Previously selected account unavailable means the server no longer returned the remembered account; the app falls back to an accessible account with a notice.
- Could not save the account selection securely leaves the old account selected. Check device secure storage and retry.
- Cancelling the picker or selecting the active account does not reload mail.

## Safe bug report

Open a [GitHub issue](https://github.com/Kuncarlos91/MailBurrow/issues) with device/OS, app version/build, steps, expected and actual behavior, and whether a private network was connected. Approximate timing, synthetic file/message characteristics, orientation and text scaling help.

Exclude keys, passwords, private hosts, real message contents, raw logs and unredacted screenshots. Security concerns follow [SECURITY.md](../../SECURITY.md).

## Developer verification

Use the playbook source map and synthetic regression tests. Privacy scans are bounded patterns, not independent audits. Native permissions require real providers/devices; host mocks alone do not prove a fix. See [setup and CI](../development/setup-and-ci.md).

## Build or release privacy failure

Start with the [artifact privacy investigation guide](artifact-privacy.md) for a blocked release scan. Do not diagnose it as an app crash.

## Windows Android build environment

If Flutter uses Android Studio's bundled Java and cannot initialize the Windows-ROOT trust store, select a compatible Windows JDK with a process-only Gradle Java-home override. Do not disable TLS or change global SDK settings to work around it.

A direct Gradle release after tests can fail on missing IntegrationTestPlugin because generated registration is still for development. Run Flutter's release build command so it regenerates production registration. Do not hand-edit the generated file, remove integration tests, or add dev plugins to production.

### Opt-in local Android file diagnostics

A local diagnostic build can add `--dart-define=MAILSHELF_FILE_DIAGNOSTICS=true`. Default builds do not enable this tracing. Native events use only fixed MailShelfFiles categories for grant retention, saved-reference registration, release and the Open outcome; never add URIs, file names, provider exception messages, attachment bytes, server settings or keys. This is local logcat output, not an analytics upload. Read only the MailShelfFiles tag and do not share broad device logs.
