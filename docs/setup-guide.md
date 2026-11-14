# Setting up MailBurrow with your own archive

[Main index](../README.md) · [Troubleshooting](troubleshooting/README.md) · [Privacy notice](../PRIVACY.md)

MailBurrow is a phone app for reading the mail you already archive with [Mail-Archiver](https://github.com/s1t5/mail-archiver). It talks only to your Mail-Archiver server, over HTTPS, with an API key you create. This guide covers how the pieces fit together and the exact settings each one needs.

**Feature-branch builds:** setup also offers **Open Archiver** for the 0.6.2 backend; this option is not in the published 0.3.0-rc.9 build. Choose the server type explicitly before entering its key. Changing the type clears the entered key. Open Archiver needs an HTTPS endpoint and a key for a user whose role can read the intended sources; sources that keep full original files cannot be opened. The steps below describe Mail-Archiver; full Open Archiver setup guidance awaits live validation. In these builds, **Settings → Archives** manages saved archives (Rename, Change address or key, Forget on this device, Add archive). Changing an address or key requires entering a key again; changing server type means adding another archive.

The same guide is on the [MailBurrow website](https://mailburrow.pages.dev/setup.html).

To see what the app looks like before setting anything up, tap **Try the demo** on the setup screen: it opens fictional sample mail built into the app, with no server needed.

Checked against Mail-Archiver's [REST API guide](https://github.com/s1t5/mail-archiver/blob/main/doc/API.md), the TrueNAS Mail Archiver and Tailscale apps, and Tailscale's HTTPS and Serve documentation, as of November 2026. Menu names can change between versions.

## How it works

```mermaid
flowchart LR
  provider["Your mail providers<br>(IMAP, Microsoft 365)"] -->|"Mail-Archiver syncs"| archiver["Mail-Archiver<br>(TrueNAS app or Docker)"]
  archiver --- db[("PostgreSQL")]
  https["HTTPS front door<br>(Tailscale Serve or reverse proxy)"] -->|"plain HTTP on your server"| archiver
  phone["MailBurrow on your phone"] -->|"HTTPS + API key<br>read-only"| https
```

- **Mail-Archiver does the archiving.** It copies mail from your providers into its own database. MailBurrow never connects to Gmail, Outlook or any mail provider, and never sees your mailbox passwords.
- **MailBurrow only reads.** It uses Mail-Archiver's read-only API to list accounts, folders and messages, run searches, and download attachments you ask for. It can't change, delete or send mail.
- **Nothing is kept on the phone.** Messages are fetched when you open them and aren't stored for offline reading. Only the server address and API key are saved, in the phone's secure storage.
- **HTTPS is required.** The app checks the server's certificate and refuses plain `http://` addresses, so your key is never sent unencrypted.

## What you need

| Piece | Required? | What it does |
| --- | --- | --- |
| [Mail-Archiver](https://github.com/s1t5/mail-archiver), release **2607.3 or later** | Yes | Archives your mail and provides the API. The API is **off by default**. |
| A Mail-Archiver API key | Yes | Lets the app read the archive with your user's permissions. |
| An HTTPS address with a **trusted certificate** | Yes | For example `https://archive.example.ts.net`. Self-signed certificates don't work. |
| [Tailscale](https://tailscale.com/) on the server and the phone | Recommended | Private access from anywhere, plus a free trusted certificate through Tailscale Serve. |
| TrueNAS | Optional | One easy way to run Mail-Archiver, through its community app. Docker on any machine works too. |
| Your own domain and a reverse proxy | Optional | An alternative to Tailscale for the HTTPS address. |

## Step 1: Turn on Mail-Archiver's API

The API is controlled by the `Api__Enabled` setting. While it's off, every `/api/` address returns "not found", and MailBurrow reports *Archive API or message unavailable*.

**TrueNAS app:**

1. Open **Apps**, select **Mail Archiver** and choose **Edit**.
2. Under **Additional Environment Variables**, add **Name** `Api__Enabled` with **Value** `true`.
3. Save. The app restarts.
4. Check the app version is 2607.3 or later; update the app if it isn't.

**Docker Compose:** add this to the Mail-Archiver service's `environment:` list, then recreate the container:

```yaml
      - Api__Enabled=true
```

Optional settings, from Mail-Archiver's [setup guide](https://github.com/s1t5/mail-archiver/blob/main/doc/Setup.md):

- `Api__AllowAttachmentDownloads` is `true` by default. Leave it on, or attachment downloads in the app will fail.
- `Api__RateLimitPerMinute` is `120` by default. That's plenty for one phone. If you see *Too many requests*, wait a minute.

## Step 2: Create an API key

A key **inherits the permissions of the user who creates it**. A regular user's key sees only the mail accounts assigned to that user; an administrator's key sees every account on the server. For a phone, use a regular user that has only the accounts you want to read on it.

1. Sign in to Mail-Archiver's web interface as that user.
2. Open the **API Keys** page and create a key. Give it a clear name such as "MailBurrow phone", and an expiry date if you like.
3. Copy the key straight away. It starts with `ma_` and is shown only once.

Keep the key private. Never paste it into chats, issue reports or screenshots. If your phone is lost, revoke the key on the same **API Keys** page; an administrator can revoke any user's keys.

## Step 3: Give the server an HTTPS address

Mail-Archiver serves plain HTTP. On TrueNAS the app's default web port is `30315`. Put one of the following in front of it.

### Option A: Tailscale Serve (recommended)

Tailscale Serve gives your server an address like `https://truenas.your-tailnet.ts.net` with a certificate phones trust, reachable only from devices signed in to your Tailscale network.

1. In the [Tailscale admin console](https://login.tailscale.com/admin/dns), open **DNS**, make sure **MagicDNS** is on, and under **HTTPS Certificates** select **Enable HTTPS**.
2. On the server, point Serve at Mail-Archiver's port:

   ```sh
   tailscale serve --bg 30315
   ```

   Replace `30315` with your port if it differs. The output shows your HTTPS address. `--bg` keeps it running in the background.
3. Check it: `tailscale serve status` should show `https://<machine>.<tailnet>.ts.net` forwarding to your port.

**On TrueNAS** with the Tailscale community app:

- Follow [Tailscale's TrueNAS guide](https://tailscale.com/kb/1483/truenas) to install the app with an auth key. Then edit the app: **untick Userspace** and **tick Host Network**, so Tailscale can reach the Mail Archiver app's port on the host.
- The app's form doesn't include a Serve setting, so run the `tailscale serve --bg 30315` command in a **shell inside the Tailscale app**, opened from the app's details on the **Apps** page. After the next restart, run `tailscale serve status` again to check the setting was kept.

The first connection can take a few seconds while Tailscale issues the certificate.

### Option B: Your own domain with a reverse proxy

If you already run a reverse proxy such as Caddy, Nginx Proxy Manager or Traefik with Let's Encrypt certificates, add a host like `mail.example.com` that forwards to Mail-Archiver's port. Some things to watch:

- The certificate must be publicly trusted. Let's Encrypt is fine; self-signed certificates and private certificate authorities aren't supported.
- **No redirects.** MailBurrow doesn't follow redirects, so its key is never sent anywhere unexpected. Use the final address, and don't put a login page or single sign-on in front of `/api/`.
- If Mail-Archiver lives under a path such as `https://example.com/mail`, enter that full address in the app; the path is kept.
- If the address is reachable from the internet, your archive's web interface is too. Consider keeping it private, for example with Tailscale or a VPN, and keep Mail-Archiver updated.

### Addresses that won't work

| Address | Why |
| --- | --- |
| `http://truenas:30315` or `http://100.x.y.z:30315` | Plain HTTP. The app only connects over HTTPS. |
| `https://192.168.1.10` with a self-signed certificate | The certificate isn't trusted. |
| An address that redirects to another one | The app doesn't follow redirects. Use the final address. |

## Step 4: Connect the app

1. If you use Tailscale, install the **Tailscale** app on your phone and sign in to the same Tailscale network. Turn it on.
2. Optional check: open your HTTPS address in the phone's browser. You should see Mail-Archiver's sign-in page with no certificate warning.
3. Open MailBurrow and enter:
   - **HTTPS server address:** for example `truenas.your-tailnet.ts.net`. `https://` is added if you leave it out.
   - **API key:** the `ma_…` key from step 2.
4. Tap **Connect to archive**.

If the key can see more than one mail account, switch between them from the account row or in Settings. **Disconnect and forget connection** in Settings removes the address and key from the phone; it doesn't revoke the key on the server.

## If something goes wrong

| Message in the app | Likely cause | What to do |
| --- | --- | --- |
| Enter a valid HTTPS server address… | The address has `http://`, a username and password, a query or a fragment | Enter just the host name, or `https://` plus host name and optional path |
| Unable to connect. Check your HTTPS address and private network. | Tailscale is off on the phone, the address is wrong, or Serve or the proxy isn't running | Turn on Tailscale, open the address in the phone's browser, check `tailscale serve status` |
| The server certificate could not be verified. | Self-signed or untrusted certificate | Use Tailscale Serve or a Let's Encrypt certificate |
| Your API key was not accepted. | Key mistyped, expired or revoked, or its user is inactive | Create a new key and enter it again |
| Archive API or message unavailable. | The API isn't enabled, Mail-Archiver is older than 2607.3, the address points at the wrong service, or the message is outside the key's accounts | Check `Api__Enabled=true` and the version, then the address |
| Too many requests. Wait and retry. | More than the rate limit (120 a minute by default) | Wait a minute |
| The server took too long to respond. | Slow connection or busy server | Retry; check the server is running |

More detail is in [troubleshooting](troubleshooting/README.md). When asking for help, never include your API key, server address or messages.

## Privacy and security in short

- Treat the API key as read access to its user's archived mail. Use a regular user, not an administrator, and only the accounts you need.
- Your server keeps its own access logs. MailBurrow has no analytics or crash reporting. See the [privacy notice](../PRIVACY.md).
- MailBurrow downloads an attachment only when you choose to, and saves it where you pick.
- Report security problems privately, as described in [SECURITY.md](../SECURITY.md).
