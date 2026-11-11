# Investigating an artifact privacy gate

[Main index](../../README.md) · [Troubleshooting](README.md) · [Playbook](../PLAYBOOK.md) · [Classification rules and evidence](../security/artifact-privacy-rules.md)

## Start here

The signed iOS workflow that runs this scan is kept outside this repository. The steps apply to any signed Android or iOS build scanned with `tools/privacy_check.py`.

This guide is for a release workflow blocked by the privacy scanner. A pattern match is an observation, not proof of a leak or a harmless compiler detail. Keep the gate blocking until the occurrence has a demonstrated source. A build/signing failure, a privacy failure and an app crash are different investigations.

A known false positive is a few bytes of a computed iOS code-signing digest; look for `origin=verified-sha256-code-page-hash` in the redacted Dart-app context. See the [signing-page digest rule](../security/artifact-privacy-rules.md#signing-page-digest-classification).

## Before another build

1. Record the build or run reference, exact source SHA, platform/version/build, failing step, fixed category/component, distinct-match count and fingerprint if available. Identify the last build that passed separately from a diagnostic build. Use the redacted summary, not raw signing/native logs.
2. State what is known, the current hypothesis and what would prove or reject it. Do not treat a missing fingerprint as proof of a VM symbol, or an unknown layout as proof of malformed data.
3. Check whether the artifact still exists. Signed-build workflows should delete the IPA, archive, native logs and signing material during cleanup, including on failure, so preserve safe evidence before cleanup.
4. Exhaust existing local evidence and pinned SDK/dependency sources first. Compare hashes in memory; never print candidate addresses or copy private values into a test. Distinguish an exact comparison from absence in the local Windows SDK, which lacks iOS artifacts.
5. Define the next run's evidence contract: which format/region/hash provenance will be reported, what remains unknown, any opt-in encrypted payload/destination/retention, and how the result changes the next action. Validate the parser on synthetic data and, where possible, a compiler-generated native fixture. Do not spend another run merely repeating the same insufficient report.
6. Limit retries: run one reviewed build per hypothesis, with any diagnostic evidence collection agreed in advance.

## Evidence to inspect while the binary exists

The current context report can provide these without printing matched text:

- Fixed component/native-format labels, distinct counts, full-match fingerprint and numeric-normalized fingerprint when applicable.
- Thin versus universal Mach-O support, a containing file-backed section or an explicit unknown/outside/ambiguous result. Section names from the binary are not printed.
- Bucketed match length, domain digit presence and adjacent NUL flags. These are clues, not provenance.
- Code-signature origin: the helper validates the native slice and signing tables, locates a single SHA-256 code-page slot and recomputes the digest. Only `verified-sha256-code-page-hash` establishes this particular origin. It does not validate Apple certificate trust or the rest of the artifact.

| Report | Interpretation and next action |
| --- | --- |
| Source/key/host/private-path category | Investigate its source privately. Do not use a binary-metadata exception to bypass it. |
| Numeric-normalized fingerprint | Possible compiler naming metadata. Verify the exact symbol against the pinned app/SDK source and binary context; a numeric domain alone proves nothing. |
| Unsupported or malformed layout | The parser cannot establish location. Check the fixed format label and parser support, including universal wrappers, before another run. |
| Outside file-backed sections | May be link-edit/signing metadata or other data. It does not mean safe; inspect declared regions and provenance. |
| Code-signature-unverified | A signing-region location alone is insufficient. Unsupported algorithm/layout, corruption or non-page data can produce this result; keep blocking. |
| Verified SHA-256 code-page hash | The bytes are part of a recomputed digest. Consider only a reviewed exact fingerprint plus this proven scope; do not exclude whole signatures/files. |
| Plaintext/literal address | Locate and fix its source if private. Replaying approved bytes as plaintext must stay blocking. |

If these fields are insufficient, the opt-in encrypted collector (`tools/encrypted_artifact_context.py`) can capture a bounded window. It captures at most 16 unresolved matches (at most 128 bytes each), with up to 64 bytes on either side, encrypted to a temporary local key. Retention is one day. Never retain the IPA, signing files or plaintext diagnostic in GitHub. The private key stays outside the repo on the local computer with restricted access. Decrypt and verify the receipt/fingerprint locally; do not print plaintext into tool/build logs. Structural evidence should be collected in the same run so a small encrypted window is not expected to reconstruct distant signing tables.

## Proving a fix

A classifier exception needs evidence, narrow scope and negative tests. For the confirmed signing-hash case, all three are required: the exact reviewed fingerprint, the exact iOS Dart-app entry, and a recomputed matching digest in a valid CodeDirectory page slot. A fingerprint, high-entropy window, section label or signature location alone is insufficient.

Test plaintext replay, wrong/non-native/Android/engine paths, unlisted fingerprints, changed pages/hash bytes, malformed tables and adjacent credentials. Source/history scans and other categories must remain strict. Use synthetic fixtures, never real app windows or private mail. Record tests separately from native builds and device results.

Run from the repository root:

```powershell
python -m unittest discover -s tools -p 'test_*.py'
python tools/check_docs.py
python tools/privacy_check.py
git diff --check
```

Encryption integration tests need the existing OpenSSL executable; confirm they actually ran rather than being skipped. On systems where it is not on PATH, `MAILSHELF_TEST_OPENSSL` may identify an existing installation. Do not add a dependency or put a personal path in the repo merely for a diagnostic.

A locally passing test does not prove a signed artifact passes, and a passing gate does not prove installation or device behavior.

## Reusable investigation record

For the next incident, write a dated record in the pull request or issue that fixes it:

- Symptom, affected build/source/run and last known working/uploaded build.
- Observations, hypotheses and the evidence required to distinguish them.
- Missing evidence and why; diagnostic payload, destination and retention.
- Root cause and the independent proof, with safe references rather than private values.
- Fix conditions and negative regressions, including what must remain blocking.
- Local checks, hosted build, upload/processing and device validation recorded separately.
- Cleanup completed and remaining work.

Update the playbook after the finding changes. Do not present superseded hypotheses as current facts.

## Android generated registrant paths and engine matches

A source scan can pass while an Android release APK still embeds build-machine information. Count flagged archive entries separately from individual pattern matches: the investigated RC9 artifact had three app-library path entries and two engine-library email-review entries, not five leaked credentials.

**Confirmed path origin.** Each packaged `libapp.so` contained the exact absolute file URI for `.dart_tool/flutter_build/dart_plugin_registrant.dart` in its checkout. In the pinned Flutter SDK, [compiler setup](https://github.com/flutter/flutter/blob/737ba8f885dc774b53b442759999a312c9461e4e/packages/flutter_tools/lib/src/compile.dart) supplies `flutter.dart_plugin_registrant`, and the [framework entry point](https://github.com/flutter/flutter/blob/737ba8f885dc774b53b442759999a312c9461e4e/packages/flutter/lib/src/dart_plugin_registrant.dart) preserves that value for isolate plugin initialization. This is a runtime constant, not merely an assumed debug-symbol leak. Do not assume stripping, obfuscation or split-debug-info removes it. The remedy is a verified rebuild from a neutral checkout path, followed by rescanning all included architectures. Never suppress personal-path findings or edit the signed APK in place.

**Engine origin.** The ARMv7 and x86-64 engine libraries contained 15 unclassified public author-attribution occurrences across them and one additional email-shaped pattern in executable ARMv7 code. The public author address was found in source files at pinned BoringSSL revision `c7eb007fd10627f1abb41a3e368b85e24cd20af9`. Engine `.text` and `.rodata` bytes matched the corresponding sections of the pinned cached Flutter engine archives; those archives matched the MD5-valued ETags returned by the official HTTPS object service. This supports upstream origin; it is not a whole-file APK identity match or a reason to ignore the entire engine. Archive packaging/stripping means a direct whole-library digest comparison may differ.

**Distribution decision.** Release APKs are built for arm64-v8a only, so the ARMv7 and x86-64 engines are not shipped and their matches do not block an arm64-only replacement. A neutral-runner probe of the same source confirmed that these two engines are the only engine findings. ABI selection does not affect the registrant path: every packaged `libapp.so`, arm64 included, embeds the checkout path.

The existing scanner remains unchanged and blocking. Any new classification must prove the exact upstream attribution context or the exact reviewed instruction match in its pinned executable section, with tests rejecting plaintext replay, wrong components/architectures, changed bytes/sections and unrelated adjacent credentials. A match's location in `.text` alone is insufficient: assembly can contain literal attribution text as well as instructions. Do not exempt an address domain, arbitrary binary bytes or all engine files.

Keep raw matches, actual personal paths, local build logs and certificate identity details outside Git. Preserve redacted provenance locally, including original/replacement artifact hashes and SDK/engine versions. After final feature fixes merge, rebuild, rescan and repeat signed-artifact/device checks.

**Outcome (2026-11-10).** The findings above describe the original local RC9 artifact and stay as historical evidence. A replacement built from a neutral checkout, arm64-v8a only, passed the artifact scan with 0 findings and was published as the [0.3.0-rc.9 prerelease](https://github.com/Kuncarlos91/MailBurrow/releases/tag/v0.3.0-rc.9). This clears only that exact APK, SHA-256 `8cf7b33f3a7a11ba5de8541f2e111d475224ecac591e2bebb8743ee572ed078b` (see the [RC9 gate results](../releasing/android-rc9.md#known-artifact-privacy-blocker)). Every future replacement still needs its own scan before upload. The ARMv7 and x86-64 engine findings remain **unresolved**: they were excluded from distribution, not classified, and must be handled as described above before those ABIs are ever shipped.
