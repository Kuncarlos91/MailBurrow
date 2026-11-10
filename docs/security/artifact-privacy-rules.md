# Artifact privacy classification rules

[Main index](../../README.md) · [Investigation guide](../troubleshooting/artifact-privacy.md)

The privacy scanner (`tools/privacy_check.py`) also inspects built app artifacts. Compiled binaries contain byte sequences that look like email addresses but are not personal data. This page records the few exact cases the scanner recognizes, the evidence behind each, and what stays blocking. For a new failure, start with the [investigation guide](../troubleshooting/artifact-privacy.md).

These rules change only email-pattern classification for exact reviewed metadata in specific binary entries. Source and history scans never use them, and they do not change the app.

## Why matches occur

- **Dart compiler names:** private Dart class/member names are mangled with an underscore prefix, an at-sign and a numeric library key. The key is a compiler detail, not an API or signing secret.
- **Engine attribution:** BoringSSL assembly in the Flutter engine carries public upstream author attribution strings.
- **Signing metadata:** a few bytes of a computed SHA-256 code-page digest in an iOS code signature can happen to match the address pattern.

## Evidence

Pinned references from this Flutter SDK's DEPS:

- Engine revision: cf636b1dfb818dd6a3ff16e390e93b1a036969c8.
- [Dart naming implementation](https://github.com/dart-lang/sdk/blob/416e33b0ffaef062a60ec966bb8c82ed2b83f128/runtime/vm/object.cc): documents mangling such as an underscore-prefixed class name, numeric private key and named member. The runtime naming key is not an API or signing secret.
- BoringSSL revision: c7eb007fd10627f1abb41a3e368b85e24cd20af9. Exact public attribution text was verified against files below, downloaded directly from that pinned upstream source. The author contact in these strings is public upstream attribution, not a project contact.

| Upstream path at pinned BoringSSL revision | Source SHA-256 |
| --- | --- |
| crypto/chacha/asm/chacha-armv8.pl | 28b1552719406d03e7f967b3391cbd85a995165eee49aaa847d7bd0f9891631f |
| crypto/fipsmodule/aes/asm/ghash-neon-armv8.pl | 0e8980f6f0f23655ef31983aac8c3041f05f8973d1b3ead3294aaaa6d91d874b |
| crypto/fipsmodule/ec/asm/p256-armv8-asm.pl | 8037f2deefa4a53a44883e10d56478fdc7ddc4762a78bac83bfabc55457348a1 |
| crypto/fipsmodule/aes/asm/ghashv8-armx.pl | 53c9a6a9845f275be5c5e549157bccaf48570c8d125d375854f7a41a09291cf5 |
| crypto/fipsmodule/sha/asm/sha1-armv8.pl | a9813252a7acbf80ecc87a2f14d722f2c9395ad551f8aeeb2efbc0701ba63a58 |
| crypto/fipsmodule/sha/asm/sha512-armv8.pl | 8342665105035a16c71c073dec6fe6fdcb76f5ac0132b62298c92879ec9c317b |
| crypto/fipsmodule/bn/asm/armv8-mont.pl | f298b027a36f7ec26bacc8dc1d699f245c69371b6de65b0de9d1c8745bee8bc6 |

Example [pinned upstream assembly generator](https://github.com/google/boringssl/blob/c7eb007fd10627f1abb41a3e368b85e24cd20af9/crypto/chacha/asm/chacha-armv8.pl). SHA assembly uses a BITS template for SHA256/SHA512; attribution hashes in the scanner cover exact rendered strings, not the template itself.

## Narrow classification

The artifact must be a ZIP entry with the exact app-framework or Flutter-engine binary path (or a standard Android architecture libapp/libflutter path), and have an ELF or supported Mach-O header. A matching path/header is a scope check, not proof of authenticity.

For the Dart binary, only 44 reviewed class/member signatures are recognized by SHA-256. The numeric compiler library suffix is normalized before hashing; the class and member names must match exactly. The pattern alone does not clear a match: other numeric email domains, different class/member names and regular addresses remain findings.

For the engine, only eight full attribution strings are recognized by SHA-256. They require the exact reviewed prefix, exact contact/text bytes, closing bracket and immediate NUL terminator. Standalone copies of the same address, changed text and other engine addresses remain findings. Whole-framework and domain-wide exclusions are not used. No third-party copyright/attribution is removed or rewritten.

Recognized counts are visible through the redacted context report even if no findings remain. Source/history scans never apply these artifact classifications. Notice-inventory matches remain informational only. Provider/API tokens, private keys, literal credentials, private hosts, personal paths and other categories are still scanned across the whole entry.

## Android ABI scope

The reviewed engine attributions are the arm64-v8a (ARMv8) wording only. The armeabi-v7a and x86_64 Flutter engines carry the same upstream author credit in other wording (for example "for ARMv4/NEON" and "for x86_64"), and the 32-bit engine also contains a machine-code byte run that matches the address pattern. These remain **blocking** and are not added to the reviewed list. Public Android release APKs are therefore built for arm64-v8a only. Supporting another ABI requires reviewing its exact strings with pinned upstream evidence first.

The scanner inspects ZIP entries only. An APK signed with the v2/v3 schemes keeps its certificate in the APK signing block, outside any entry, so certificate identity fields must be reviewed separately (for example with `apksigner verify --print-certs`).

## Signing-page digest classification

One reviewed full-match fingerprint is recognized in signed iOS builds. Recognition additionally requires the exact iOS Dart App.framework binary scope, a valid native layout and a single containing SHA-256 code-page hash slot whose digest the checker recomputes correctly (`origin=verified-sha256-code-page-hash`). It does not exempt arbitrary digests, signatures, binary files, domains, normal addresses or raw copies of the same bytes. The context report counts this case as `reviewed-code-page-hashes`.

## Validation and limitations

Synthetic regression tests cover scope, native header, exact signature/text, unknown addresses, numeric email lookalikes, signing-digest provenance (unlisted digests, corrupt pages/hash bytes, plaintext replay, wrong paths), source/history mode, adjacent credentials and redacted output. Run them with `python -m unittest discover -s tools -p 'test_*.py'`.

Differences in architecture, SDK output, symbols or attribution text remain blocking until reviewed. New hashes must be backed by evidence, never added merely to obtain a passing run. Exact reviewed strings can be deliberately copied into a binary; these are bounded heuristic checks, not a forensic guarantee that an app contains no private information. Licensing, signing-certificate metadata and device testing are separate checks.
