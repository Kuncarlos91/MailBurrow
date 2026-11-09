# Contributing to MailBurrow

Thanks for your interest. MailBurrow is a small, one-person project, so bug reports, setup feedback and focused pull requests are all welcome.

## Before you start

- **Bugs and setup problems:** open an issue using a template. Never include API keys, server addresses, real mail or unredacted screenshots.
- **Security problems:** report them privately, as described in [SECURITY.md](SECURITY.md).
- **Bigger changes:** open an issue first to discuss the idea, so your time isn't wasted.
- **Conduct:** everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Product boundaries

MailBurrow is a **read-only** client for a Mail-Archiver server that users run themselves. Changes should keep to that:

- No sending, editing or deleting mail, and no changes on the server.
- **No on-device mail cache:** no local mail database, offline copies or prefetching. Mail is fetched only when the user asks to view it.
- HTTPS with certificate validation, no redirects, and bounded responses and downloads.
- The project doesn't provide servers, accounts or private networks; docs and the app shouldn't suggest it does.

## Development

1. Install Flutter 3.47.8 stable. See [setup and CI](docs/development/setup-and-ci.md).
2. Fork the repository and create a short-lived branch from `main`.
3. Read the [Playbook](docs/PLAYBOOK.md) for the architecture and design decisions, and update it, the README or the [setup guide](docs/setup-guide.md) when your change affects them.
4. Before opening a pull request, run:

   ```sh
   flutter pub get --enforce-lockfile
   flutter analyze --no-pub --fatal-infos
   flutter test --no-pub
   python tools/check_docs.py
   python tools/privacy_check.py
   ```

5. Use synthetic data only: example addresses under `example.invalid` and placeholder server names. Never commit real mail, credentials, server settings, signing files or APKs.

CI runs the same analysis, tests and privacy scan on every pull request.

## Code and licensing

- Contributions are accepted under the project's [MIT License](LICENSE).
- If you bring in code or assets from another project, say where they come from and under which license, and keep third-party notices intact. After dependency changes, regenerate the notices with `python tools/dependency_notices.py`.
- AI coding assistants help build this app. That's fine for contributions too, as long as you've reviewed and tested what you submit.
