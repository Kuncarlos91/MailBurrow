import unittest
import subprocess
import sys
import tempfile
from pathlib import Path
from privacy_check import inspect, artifact_context
import zipfile
import hashlib
import contextlib
import io
from unittest.mock import patch

class PrivacyGuardTests(unittest.TestCase):
    def test_realistic_sensitive_categories(self):
        cases = [
            (b"gh" + b"p_" + b"a" * 36, "provider-token-shaped"),
            (b"ma_" + b"q" * 43, "mail-archiver-key-shaped"),
            (b"-----BEGIN " + b"PRIVATE KEY-----", "private-key-material"),
            (b"https://archive." + b"privatetail.ts." + b"net", "private-network-host"),
            (b"C:/Users/" + b"owner/keys", "personal-local-path"),
            (b"user@" + b"personal-domain.org", "email-address-review"),
            (b'api_key = "' + b"q7Z9h2N4v8X6a1P3" + b'"', "literal-credential-review"),
            (b"Bearer " + b"q7Z9h2N4v8X6a1P3s5T0", "literal-credential-review"),
        ]
        for sample, expected in cases:
            with self.subTest(expected=expected):
                self.assertIn(expected, inspect(sample))

    def test_approved_public_contact_requires_exact_address_and_document(self):
        approved = b"mailburrowsupport@" + b"gmail.com"
        path = "docs/security/public-contacts.md"
        self.assertFalse(inspect(approved, path))
        self.assertFalse(inspect(approved, path.replace("/", "\\")))
        for other in (b"mailburrowhelp@" + b"gmail.com",
                      b"mailburrowsupport@" + b"another-domain.org",
                      b"x" + approved):
            self.assertIn("email-address-review", inspect(other, path))

    def test_public_contact_is_not_exempt_in_other_files_or_artifacts(self):
        approved = b"mailburrowsupport@" + b"gmail.com"
        for path in ("", "PRIVACY.md", "lib/contact.dart",
                     "docs/security/other.md", "docs/security/public-contacts.md.bak"):
            self.assertIn("email-address-review", inspect(approved, path))
        path = "docs/security/public-contacts.md"
        self.assertIn("email-address-review", inspect(approved, path, check_path=False, artifact=True))
        native = b"\xcf\xfa\xed\xfe" + approved + b"\0"
        self.assertIn("email-address-review", inspect(native,
            "Payload/Synthetic.app/Frameworks/App.framework/App", check_path=False, artifact=True))

    def test_public_contact_does_not_clear_adjacent_secrets_or_addresses(self):
        approved = b"mailburrowsupport@" + b"gmail.com"
        path = "docs/security/public-contacts.md"
        cases = [
            (b"other@" + b"personal-domain.org", "email-address-review"),
            (b"ma_" + b"q" * 43, "mail-archiver-key-shaped"),
            (b"gh" + b"p_" + b"a" * 36, "provider-token-shaped"),
            (b"-----BEGIN " + b"PRIVATE KEY-----", "private-key-material"),
            (b"https://archive." + b"private-tail.ts." + b"net", "private-network-host"),
        ]
        for sample, category in cases:
            self.assertIn(category, inspect(approved + b"\n" + sample, path))

    def test_placeholder_examples_and_dynamic_values(self):
        for sample in [
            b"https://archive.example.ts.net",
            b"C:/Users/your-name/AndroidKeys/release.jks",
            b"user@example.invalid",
            b'apiKey: "replace-with-your-key"',
            b'authorization: "Bearer $key"',
            b"no private data",
            b"Icon-App-20x20@2x.png",
        ]:
            with self.subTest(sample=sample):
                self.assertFalse(inspect(sample))

    def test_public_api_routes_are_not_local_paths(self):
        self.assertFalse(inspect(b"https://api.github.com/users/project-owner"))

    def test_notice_exception_does_not_hide_credentials(self):
        self.assertNotIn("email-address-review", inspect(b"author@" + b"upstream.org", "THIRD_PARTY_NOTICES.md"))
        sample = b"-----BEGIN " + b"PRIVATE KEY-----"
        self.assertIn("private-key-material", inspect(sample, "THIRD_PARTY_NOTICES.md"))

    def test_artifact_cli_redacts_secret_and_filename(self):
        sample = b"gh" + b"p_" + b"a" * 36
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "private-review.bin"
            artifact.write_bytes(sample)
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("privacy_check.py")), "--artifact", str(artifact)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"provider-token-shaped", result.stdout)
            self.assertNotIn(sample, result.stdout + result.stderr)
            self.assertNotIn(str(artifact).encode(), result.stdout + result.stderr)

    def test_unreviewed_vm_fingerprint_is_redacted_and_never_clears_finding(self):
        sample = b"_SyntheticWidget@" + b"123456789.build"
        binary = b"\xcf\xfa\xed\xfe" + sample + b"\0"
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        context = artifact_context(path, binary)
        digest = hashlib.sha256(b"_SyntheticWidget@#.build").hexdigest()
        self.assertIn(digest, context)
        self.assertNotIn(sample.decode(), context)
        self.assertNotIn("SyntheticWidget", context)
        self.assertIn("email-address-review", inspect(binary, path, check_path=False, artifact=True))
        self.assertIn("findings remain blocking", context)
        self.assertNotIn(digest, artifact_context(path, sample))
        self.assertNotIn(digest, artifact_context("Payload/Synthetic.app/other.bin", binary))
        self.assertNotIn(digest, artifact_context("Payload/Synthetic.app/Frameworks/Flutter.framework/Flutter", binary))

    def test_app_match_fingerprint_never_discloses_or_exempts_an_address(self):
        sample = b"owner@" + b"private-domain.org"
        binary = b"\xcf\xfa\xed\xfe" + sample + b"\0"
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        context = artifact_context(path, binary)
        self.assertIn(hashlib.sha256(sample).hexdigest(), context)
        self.assertIn("numeric-normalized fingerprints (SHA-256, first 16): none", context)
        self.assertNotIn(sample.decode(), context)
        self.assertIn("email-address-review", inspect(binary, path, check_path=False, artifact=True))
        self.assertNotIn(hashlib.sha256(sample).hexdigest(), artifact_context(path, sample))
        self.assertNotIn(hashlib.sha256(sample).hexdigest(), artifact_context("Payload/Synthetic.app/other.bin", binary))

    def test_numeric_fingerprint_does_not_assume_private_class_or_key_length(self):
        sample = b"prefix.PublicType@" + b"42.field"
        binary = b"\xcf\xfa\xed\xfe" + sample + b"\0"
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        context = artifact_context(path, binary)
        self.assertIn(hashlib.sha256(b"prefix.PublicType@#.field").hexdigest(), context)
        self.assertNotIn(sample.decode(), context)
        self.assertIn("email-address-review", inspect(binary, path, check_path=False, artifact=True))

    def test_artifact_context_distinguishes_components(self):
        cases = [
            ("Payload/Synthetic.app/embedded.mobileprovision", "embedded-provisioning-profile"),
            ("Payload/Synthetic.app/_CodeSignature/CodeResources", "code-signature-metadata"),
            ("Payload/Synthetic.app/Frameworks/Flutter.framework/Flutter", "flutter-engine-framework"),
            ("Payload/Synthetic.app/Frameworks/App.framework/App", "dart-app-framework"),
            ("Payload/Synthetic.app/Frameworks/Synthetic.framework/Synthetic", "other-framework"),
            ("Payload/Synthetic.app/Assets.car", "asset-catalog"),
            ("lib/arm64-v8a/libapp.so", "dart-app-framework"),
            ("lib/arm64-v8a/libflutter.so", "flutter-engine-framework"),
            ("Payload/Synthetic.app/Info.plist", "bundle-property-list"),
            ("Payload/Synthetic.app/Synthetic", "main-app-executable"),
        ]
        for name, expected in cases:
            with self.subTest(component=expected):
                self.assertIn("Component: " + expected + ";", artifact_context(name, b"\xcf\xfa\xed\xfe"))

    def test_notice_match_is_context_not_a_privacy_exception(self):
        address = b"reviewer@" + b"upstream.org"
        with patch("privacy_check.Path.read_bytes", return_value=address):
            context = artifact_context("private-filename", address)
        self.assertIn("exact-notice-matches: 1", context)
        self.assertIn("findings remain blocking", context)
        self.assertNotIn(address.decode(), context)
        self.assertNotIn("private-filename", context)
        self.assertIn("email-address-review", inspect(address, check_path=False))

    def test_missing_notice_inventory_is_reported(self):
        with patch("privacy_check.Path.read_bytes", side_effect=OSError):
            context = artifact_context("private-filename", b"no address")
        self.assertIn("notice-inventory: unavailable", context)

    def test_zip_context_redacts_and_keeps_failure_status(self):
        address = b"reviewer@" + b"unlisted-domain.org"
        token = b"gh" + b"p_" + b"a" * 36
        entry = "Payload/private-marker.app/Frameworks/App.framework/App"
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "private-marker.ipa"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr(entry, address + b" " + token)
            command = [sys.executable, str(Path(__file__).with_name("privacy_check.py")), "--artifact", str(artifact)]
            plain = subprocess.run(command, capture_output=True)
            detailed = subprocess.run(command + ["--artifact-context"], capture_output=True)
            self.assertEqual(plain.returncode, 1)
            self.assertEqual(detailed.returncode, 1)
            self.assertIn(b"email-address-review", detailed.stdout)
            self.assertIn(b"provider-token-shaped", detailed.stdout)
            self.assertIn(b"Component: dart-app-framework", detailed.stdout)
            self.assertNotIn(b"Component:", plain.stdout)
            for private in (address, token, entry.encode(), str(artifact).encode(), b"private-marker"):
                self.assertNotIn(private, detailed.stdout + detailed.stderr)

    def test_context_requires_artifact(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("privacy_check.py")), "--artifact-context"], capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_reviewed_symbols_require_exact_binary_scope_and_signature(self):
        value = b"_Synthetic" + b"@" + b"1234567.fromBuffer"
        normalized = b"_Synthetic" + b"@#.fromBuffer"
        digest = hashlib.sha256(normalized).hexdigest()
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        binary = b"\xcf\xfa\xed\xfe\0" + value + b"\0"
        with patch("privacy_check.REVIEWED_DART_SYMBOL_HASHES", {digest}):
            self.assertNotIn("email-address-review", inspect(binary, path, False, artifact=True))
            self.assertIn("reviewed-dart-symbols: 1", artifact_context(path, binary))
            self.assertIn("email-address-review", inspect(binary, path, False))
            self.assertIn("email-address-review", inspect(value, path, False, artifact=True))
            self.assertIn("email-address-review", inspect(binary, "Payload/Synthetic.app/other.bin", False, artifact=True))
            self.assertIn("email-address-review", inspect(binary.replace(b"fromBuffer", b"otherMember"), path, False, artifact=True))
            numeric_email = b"_Person" + b"@" + b"1234567.com"
            self.assertIn("email-address-review", inspect(binary + numeric_email, path, False, artifact=True))

    def test_known_symbol_does_not_hide_other_sensitive_data(self):
        value = b"_Synthetic" + b"@" + b"1234567.fromBuffer"
        digest = hashlib.sha256(b"_Synthetic" + b"@#.fromBuffer").hexdigest()
        binary = b"\xcf\xfa\xed\xfe\0" + value + b"\0"
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        samples = [(b"gh" + b"p_" + b"a" * 36, "provider-token-shaped"),
                   (b"ma_" + b"q" * 43, "mail-archiver-key-shaped"),
                   (b"-----BEGIN " + b"PRIVATE KEY-----", "private-key-material"),
                   (b"person@" + b"unlisted-domain.org", "email-address-review")]
        with patch("privacy_check.REVIEWED_DART_SYMBOL_HASHES", {digest}):
            for extra, category in samples:
                self.assertIn(category, inspect(binary + extra, path, False, artifact=True))

    def test_engine_attribution_requires_exact_context_hash_and_engine_scope(self):
        prefix = b"Synthetic upstream attribution <"
        address = b"author@" + b"upstream.org"
        attribution = prefix + address + b">"
        digest = hashlib.sha256(attribution).hexdigest()
        path = "Payload/Synthetic.app/Frameworks/Flutter.framework/Flutter"
        binary = b"\xcf\xfa\xed\xfe\0" + attribution + b"\0"
        with patch("privacy_check.REVIEWED_ENGINE_ATTRIBUTIONS", {prefix: digest}):
            self.assertNotIn("email-address-review", inspect(binary, path, False, artifact=True))
            self.assertIn("reviewed-upstream-attributions: 1", artifact_context(path, binary))
            self.assertIn("email-address-review", inspect(binary, path, False))
            self.assertIn("email-address-review", inspect(binary.replace(b"author", b"another"), path, False, artifact=True))
            self.assertIn("email-address-review", inspect(binary + address, path, False, artifact=True))
            self.assertIn("email-address-review", inspect(binary, "Payload/Synthetic.app/Frameworks/App.framework/App", False, artifact=True))
            self.assertIn("email-address-review", inspect(binary[:-1], path, False, artifact=True))

    def test_recognized_metadata_is_reported_even_when_zip_passes(self):
        value = b"_Synthetic" + b"@" + b"1234567.fromBuffer"
        digest = hashlib.sha256(b"_Synthetic" + b"@#.fromBuffer").hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "private-marker.ipa"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("Payload/private-marker.app/Frameworks/App.framework/App", b"\xcf\xfa\xed\xfe\0" + value + b"\0")
            output = io.StringIO()
            import privacy_check
            with patch("privacy_check.REVIEWED_DART_SYMBOL_HASHES", {digest}), patch.object(sys, "argv", ["privacy_check", "--artifact", str(artifact), "--artifact-context"]), contextlib.redirect_stdout(output):
                self.assertEqual(privacy_check.main(), 0)
            self.assertIn("reviewed-dart-symbols: 1", output.getvalue())
            self.assertNotIn("private-marker", output.getvalue())
            self.assertNotIn(value.decode(), output.getvalue())

    def test_prohibited_files_and_allowed_example(self):
        for path in ["keystore.properties", "android/local.properties",
                     "keys/release.jks", ".env", ".env.production",
                     "private.eml", "build/release.apk", ".idea/report.xml"]:
            self.assertIn("prohibited-file", inspect(b"", path))
        self.assertFalse(inspect(b"storePassword=replace-with-your-password",
                                 "keystore.properties.example"))

if __name__ == "__main__":
    unittest.main()
