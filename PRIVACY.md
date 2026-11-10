# MailBurrow privacy notice

MailBurrow is a read-only phone app for a [Mail-Archiver](https://github.com/s1t5/mail-archiver) server that you or your administrator run. You enter the server's HTTPS address and an API key; the app talks only to that server. The project does not host archives, provide accounts, relay mail or run networks for users. Your server's operator controls its access, logs, retention and backups.

## What the app stores on your device

- Your server address, API key and selected account, in the platform's secure storage (Android Keystore-backed storage, iOS Keychain). **Disconnect and forget connection** in Settings removes them. It doesn't revoke the key on the server.
- No mail database or offline copies. Messages are fetched when you open them and held in memory while you view them.
- Attachments you choose to save are downloaded to private temporary storage first, then saved where you pick. The temporary copy is removed after saving or on failure; if the app is interrupted, a private cache copy can remain until the operating system clears it. Files you save stay where you saved them, and a cloud provider you choose may sync them under its own policies.

## What the app sends, and to whom

- Requests go only to the server you entered, over HTTPS with certificate checks. They include your API key, your searches and filters, and the IDs of accounts, messages and attachments you open.
- Your server may record these requests. Mail-Archiver documents [access logging](https://github.com/s1t5/mail-archiver/blob/main/doc/API.md#access-logging) of searches, opened messages, downloads and API-key use, and proxies or Tailscale may keep their own logs. The app having no analytics doesn't mean your server keeps no records.
- MailBurrow has **no analytics, advertising, tracking or third-party crash reporting**, and never asks for mailbox passwords or provider logins. Release builds don't record file operations. API keys and message content must never be put in logs or bug reports.

## Safety limits

- API responses are limited to 8 MiB before decoding; larger ones are refused with a readable message.
- Attachment downloads are capped at 50 MiB, with a two-minute overall deadline and a 30-second idle timeout. Cancel or Back stops the download and removes the partial file where possible. These limits don't apply to the system save picker, file providers or viewer apps.
- Remote images, scripts, styles and other active content in emails are blocked. Links show their destination and ask before opening. Attachments download and open only when you choose. Links and attachments are not scanned for malware or phishing; simplified formatting is for safety and readability, not a verdict on trust.
- Opening a link hands the full address, including any tracking parameters, to another app under that app's policies. Plain-HTTP links get an extra warning; the app's own server requests are always HTTPS.
- On iOS, permission to reopen a saved file lasts only while you're viewing that message; nothing is saved for later. On Android, the app keeps the read permission the system grants for a saved file while you use it and releases it afterwards where possible; it keeps no history of saved files and asks for no broad media permission.

## Demo mode

**Try the demo** opens fictional sample mail that is built into the app. The demo connects to no server, sends nothing over the network and does not save or change any connection or credentials. If you save a demo attachment, it goes through the normal save dialog to the place you choose, and a demo link you confirm opens in your browser like any other link. Demo addresses and links use reserved documentation domains, not real customer addresses; a demo link may not load or may lead to an informational page rather than a working service.

## What the app never does

MailBurrow never sends, edits, deletes or uploads mail. It only reads what your API key allows.

## Contact

For support or privacy questions, use the [support contact](docs/security/public-contacts.md#support-and-privacy). Never include API keys, server addresses, messages or unredacted screenshots. If a key may have been exposed, revoke it on your Mail-Archiver server and create a new one. Report security problems as described in [SECURITY.md](SECURITY.md).
