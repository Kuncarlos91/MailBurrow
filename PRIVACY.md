# MailBurrow privacy notice

MailBurrow is a read-only phone app for [Mail-Archiver](https://github.com/s1t5/mail-archiver) and [Open Archiver](https://github.com/LogicLabs-OU/OpenArchiver) servers that you or your administrator run. You enter each server's HTTPS address and an API key; the app contacts that server to validate the connection, then uses the open archive for browsing. It does not fetch mail from inactive saved archives in the background. The project does not host archives, provide accounts, relay mail or run networks for users. Your server's operator controls its access, logs, retention and backups.

## What the app stores on your device

- For each saved archive (up to 20): its name, server type, server address, API key and selected account or source, in the platform's secure storage (Android Keystore-backed storage, iOS Keychain). **Settings → Archives → Forget on this device**, or **Disconnect and forget connection** for the open archive, removes that archive's details. Neither revokes the key on the server. If secure-storage key cleanup fails, an unreferenced key entry can remain until cleanup succeeds on a later startup.
- No mail database or offline copies. Browsing and searching fetch mail summaries and search results; opening a message fetches its content. These responses are processed in memory, without a persistent mail cache.
- Attachments you choose to save are downloaded to private temporary storage first, then saved where you pick. The temporary copy is removed after saving or on failure; if the app is interrupted, a private cache copy can remain until the operating system clears it. Files you save stay where you saved them, and a cloud provider you choose may sync them under its own policies.

## What the app sends, and to whom

- Archive requests go to the server you are connecting to, reconfiguring or actively browsing, over HTTPS with certificate checks. Validating another archive can contact it while the current archive remains open. They include that archive's API key, your searches and filters, and the IDs of accounts, sources, messages and attachments you open. A saved key is never sent to another archive or to a changed address.
- **Open Archiver:** search results can include full message text and text the server extracted from attachments; it is held in memory with the results and discarded with them. Opening a message downloads its original message, which can include inline images within the message limits (shown only under the rules below); separate attachment files download only when you save one. Messages from sources that keep full original files, attachments included, are not opened.
- Your server may record these requests. Mail-Archiver documents [access logging](https://github.com/s1t5/mail-archiver/blob/main/doc/API.md#access-logging) of searches, opened messages, downloads and API-key use; Open Archiver records searches (including the query) and message opens in its audit log; proxies and Tailscale may keep their own logs. The app having no analytics doesn't mean your server keeps no records.
- MailBurrow has **no analytics, advertising, tracking or third-party crash reporting**, and never asks for mailbox passwords or provider logins. Release builds don't record file operations. API keys and message content must never be put in logs or bug reports.

## Safety limits

- Ordinary API responses are limited to 8 MiB before decoding; larger ones are refused with a readable message. Open Archiver message detail has separate limits: a 40 MiB response, a 10 MiB decoded message and 4 MiB of other JSON fields.
- Attachment downloads are capped at 50 MiB, with a two-minute overall deadline and a 30-second idle timeout. Cancel or Back stops the download and removes the partial file where possible. These limits don't apply to the system save picker, file providers or viewer apps.
- Remote images, scripts, styles and other active content in emails are blocked. Links show their destination and ask before opening. Attachments download and open only when you choose. Links and attachments are not scanned for malware or phishing; simplified formatting is for safety and readability, not a verdict on trust.
- Opening a link hands the full address, including any tracking parameters, to another app under that app's policies. Plain-HTTP links get an extra warning; the app's own server requests are always HTTPS.
- On iOS, permission to reopen a saved file lasts only while you're viewing that message; nothing is saved for later. On Android, the app keeps the read permission the system grants for a saved file while you use it and releases it afterwards where possible; it keeps no history of saved files and asks for no broad media permission.

## Demo mode

**Try the demo** opens fictional sample mail that is built into the app. The demo connects to no server, sends nothing over the network and does not save or change any connection or credentials. If you save a demo attachment, it goes through the normal save dialog to the place you choose, and a demo link you confirm opens in your browser like any other link. Demo addresses and links use reserved documentation domains, not real customer addresses; a demo link may not load or may lead to an informational page rather than a working service.

## What the app never does

MailBurrow never sends, edits, deletes or uploads mail. It only reads what your API key allows.

## Contact

For support or privacy questions, use the [support contact](docs/security/public-contacts.md#support-and-privacy). Never include API keys, server addresses, messages or unredacted screenshots. If a key may have been exposed, revoke it on your archive server and create a new one. Report security problems as described in [SECURITY.md](SECURITY.md).
