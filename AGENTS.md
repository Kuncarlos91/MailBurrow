# MailBurrow repository working instructions

Start with [README.md](README.md), the sole main documentation index, and [the playbook](docs/PLAYBOOK.md). Follow [documentation maintenance](docs/development/documentation.md).

## Product and service boundary

MailBurrow is a read-only client. Users configure their own Mail-Archiver, HTTPS endpoint, API keys and Tailscale/private-network access. The project does not provide customer TrueNAS/server hosting, mailbox provisioning, mail relay, managed tailnets or remote server administration. TrueNAS is an optional host, not a client runtime requirement. Keep setup/help/policies and tester guidance consistent with this boundary; do not request customer credentials or treat the owner's production log/backup audit as a release prerequisite. Any synthetic review/test environment is separate, fictional and explicitly scoped; it does not establish customer hosting.

## Rolling documentation

For every meaningful feature/fix, API/native integration, configuration or failure-recovery change, review the playbook and update affected behavior, architecture/source references, limitations and validation/release status when needed. Update the setup guide and troubleshooting in the same change when they are affected. If documentation is unaffected, say why in the work summary. Record user-visible changes in CHANGELOG; avoid contradictory current instructions.

Keep README.md for people setting up and using the app: what it is, requirements, install, connect, security summary and the documentation index. Do not add release-candidate status, build evidence, CI run IDs or investigation notes to it. Keep the Playbook to current behavior, design and decisions. Internal release, store and test records are kept outside this public repository by the owner; never add private build links, owner-only notes or personal details here.

Label local implementation, host tests, native builds, device testing and distribution separately. Never claim an installed build contains uncommitted changes. Verify API fields/endpoints from reliable upstream sources or established project context; do not guess schemas.

## Privacy and configuration preservation

Do not cache mail on the device: no local mail database, offline copies or prefetching. Mail is fetched only when the user asks to view it (see the playbook's design decision log). Attachments stay limited to the explicit, temporary save flow.

Keep keys, real messages, private server/network settings, signing materials, personal paths and unredacted diagnostic logs out of source/docs. Use synthetic fixtures/placeholders. Preserve TLS validation and read-only behavior. Do not request pasted API keys.

Before moving a guide, search generators, workflows, code error messages and Markdown. Update links/tool outputs together. Do not relocate configuration files as documentation cleanup. Root keystore properties, platform project paths and .github/workflows remain unchanged. Preserve root THIRD_PARTY_NOTICES.md content/path and the privacy classifier's strict behavior.

## Verification and authorization

Run `python tools/check_docs.py`, `python tools/privacy_check.py`, relevant Python tests and `git diff --check` for documentation/tooling changes. Run Flutter analysis/tests when behavior changes. Native code also needs platform compilation/device checks; host mocks alone are not proof.

User authorization in the active session governs commits, pushes, hosted signing runs, uploads and publication. Preparing changes or updating docs does not authorize those actions. Preserve unrelated pending changes and existing release identities/assets/tags. Add dependencies only when necessary.
