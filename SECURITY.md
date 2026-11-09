# Security policy

MailBurrow is an independent, read-only client for Mail-Archiver. It is not an official Mail-Archiver app. Problems with your server, network or Mail-Archiver itself belong with your server's operator or the [Mail-Archiver project](https://github.com/s1t5/mail-archiver).

## Reporting a vulnerability

**Please don't open a public issue for a suspected vulnerability.**

Report it privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. If that isn't available to you, email the [support contact](docs/security/public-contacts.md#support-and-privacy) with a short description and no sensitive details, and we'll agree on a private way to share more.

Helpful details: the app version and build (shown in Settings), platform and OS version, what happens, and how to reproduce it with synthetic data. **Never send** API keys, passwords, signing files, private server addresses, real mail or unredacted screenshots.

This is a one-person project, so there is no guaranteed response time. Reports are taken seriously and fixed as quickly as practical. Passing tests or a pattern scan is not a security certification.

## Supported versions

Security fixes go into the latest release. Please update before reporting.

## If your access may be compromised

Revoke the API key on your Mail-Archiver server (**API Keys** page) and create a new one, then use **Disconnect and forget connection** in the app on any device that had the old key. A server address or the app's public signing certificate is not a secret.
