# Documentation maintenance

[Main index](../../README.md) · [Playbook](../PLAYBOOK.md)

## Where information belongs

- Root README: main entry point and the only docs index.
- Playbook: current features, navigation, design rationale, architecture/API map, lifecycle and limits.
- Setup guide: server, HTTPS and app configuration for users.
- Development: CI, dependencies, notices, icons and native evidence.
- Troubleshooting: symptoms, safe recovery steps, affected components and diagnostic limits.
- Security: public contacts and artifact-classification rules. Root SECURITY/PRIVACY remain the policies.
- Root CHANGELOG: change/release history. Root third-party notices must remain intact.

## Required rolling update

For every meaningful feature, fix, API/native change, configuration change or failure-recovery change, review the playbook and update affected behavior/status/source-map/decision entries when needed. Review relevant setup and troubleshooting guidance too. Include updates in the same feature/fix commit. For changes with no documentation impact, record that determination in the work summary rather than inventing an entry.

Distinguish implemented locally, host-tested, native-compiled, device-tested and released. Update current state instead of appending contradictory pending notices. Record version/build/commit when known; never infer a device pass or release from a test, tag or successful upload alone.

For an investigation spanning multiple attempts, write a reusable troubleshooting entry and a dated evidence record: observations versus hypotheses, proof, failed approaches, narrow fix/regressions, cleanup and remaining validation. Link it from the main index/playbook. See the [artifact privacy example](../troubleshooting/artifact-privacy.md). Do not make future maintainers reconstruct a fix from chat or raw logs.

## Relocation rules and checks

Before moving/deleting a guide, search its filename across source, scripts, workflows, examples and Markdown. Update relative links for the new location. Preserve command working directories and exact configuration destinations; moving a guide does not move root signing properties/platform files. Preserve meaningful instructions and historical evidence before removing duplicates.

From the repository root:

```powershell
python tools/check_docs.py
python tools/privacy_check.py
python -m unittest discover -s tools -p 'test_*.py'
git diff --check
```

The documentation checker validates local Markdown destinations and heading fragments in root/docs guides. It does not fetch external websites, validate private GitHub access or test device instructions. Review those changes directly. The normal Flutter CI privacy job also runs it. Do not regenerate license notices just to move an inventory; use its generator only when dependency evidence changes.

No real API keys, signing material, private hostnames, message contents, personal paths or unredacted logs/screenshots belong in documentation. A clean scan is not proof of public readiness.


Generated Gradle diagnostics under `android/build/` stay ignored, alongside IDE inspection reports and root build outputs. Keep them out of commits and public reports; they can contain local filesystem paths.
