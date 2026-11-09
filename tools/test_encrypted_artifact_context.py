import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from encrypted_artifact_context import capture, HEADER, MAGIC, OPTIONS, main
from privacy_check import inspect

OPENSSL = os.environ.get("MAILSHELF_TEST_OPENSSL") or shutil.which("openssl")
ENTRY = "Payload/Synthetic.app/Frameworks/App.framework/App"
SAMPLE = b"owner@" + b"unlisted-domain.org"


@unittest.skipUnless(OPENSSL, "OpenSSL required for encryption integration test")
class EncryptedContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.private, cls.public = cls.root / "key.pem", cls.root / "public.pem"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096", "-out", str(cls.private)], capture_output=True, check=True)
        subprocess.run([OPENSSL, "pkey", "-in", str(cls.private), "-pubout", "-out", str(cls.public)], capture_output=True, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def make_artifact(self, root, data, entry=ENTRY):
        artifact = root / "synthetic.ipa"
        with zipfile.ZipFile(artifact, "w") as z:
            z.writestr(entry, data)
            z.writestr("Payload/Synthetic.app/embedded.mobileprovision", b"never capture signing metadata")
        return artifact

    def test_encrypt_decrypt_exact_evidence_and_leave_gate_blocking(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            secret = b"ma_" + b"q" * 43
            data = b"\xcf\xfa\xed\xfe" + b"x\0" + SAMPLE + b"\0" + secret
            artifact = self.make_artifact(root, data)
            output = root / "encrypted"
            self.assertEqual(capture(artifact, self.public, output, OPENSSL), 1)
            ciphertext = (output / "context-00.bin").read_bytes()
            self.assertEqual(len(ciphertext), 512)
            self.assertNotIn(SAMPLE, ciphertext)
            self.assertNotIn(secret, ciphertext)
            decoded = subprocess.run([OPENSSL, "pkeyutl", "-decrypt", "-inkey", str(self.private)] + OPTIONS, input=ciphertext, capture_output=True, check=True).stdout
            magic, header, digest, start, relative, length, size = HEADER.unpack_from(decoded)
            self.assertEqual(magic, MAGIC)
            self.assertEqual(header, data[:4])
            self.assertEqual(decoded[HEADER.size + relative:HEADER.size + relative + length], SAMPLE)
            self.assertEqual(decoded[HEADER.size:], data[start:start + size])
            self.assertIn("email-address-review", inspect(data, ENTRY, False, True))
            self.assertIn("mail-archiver-key-shaped", inspect(data, ENTRY, False, True))
            manifest = (output / "manifest.json").read_bytes()
            self.assertNotIn(SAMPLE, manifest)
            self.assertNotIn(secret, manifest)
            self.assertEqual(set(p.name for p in output.iterdir()), {"manifest.json", "context-00.bin"})

    def test_invalid_key_wrong_scope_header_and_oversize_fail_without_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bad = root / "bad.pem"; bad.write_bytes(b"not a public key")
            artifact = self.make_artifact(root, b"\xcf\xfa\xed\xfe" + SAMPLE)
            output = root / "encrypted"
            with self.assertRaises(ValueError): capture(artifact, bad, output, OPENSSL)
            self.assertFalse(output.exists())
            for data, entry in ((b"unknown" + SAMPLE, ENTRY), (b"\xcf\xfa\xed\xfe" + SAMPLE, "other.bin"),
                                (b"\xcf\xfa\xed\xfe" + b"a" * 140 + SAMPLE, ENTRY)):
                artifact = self.make_artifact(root, data, entry)
                with self.assertRaises(ValueError): capture(artifact, self.public, output, OPENSSL)
                self.assertFalse(output.exists())

    def test_example_and_reviewed_symbols_are_not_collected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact = self.make_artifact(root, b"\xcf\xfa\xed\xfe" + b"user@example.invalid")
            output = root / "encrypted"
            self.assertEqual(capture(artifact, self.public, output, OPENSSL), 0)
            self.assertEqual(list(p.name for p in output.iterdir()), ["manifest.json"])

    def test_capture_limit_never_writes_partial_plaintext_or_ciphertext(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = b"\xcf\xfa\xed\xfe" + b"\0".join(b"person" + str(i).encode() + b"@unlisted-domain.org" for i in range(17))
            artifact = self.make_artifact(root, payload)
            output = root / "encrypted"
            with self.assertRaises(ValueError): capture(artifact, self.public, output, OPENSSL)
            self.assertFalse(output.exists())


class EncryptedFailureReportingTests(unittest.TestCase):
    def test_cli_never_emits_subprocess_diagnostics_or_private_paths(self):
        error = subprocess.CalledProcessError(1, ["openssl"], output=SAMPLE, stderr=b"private-marker " + SAMPLE)
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("sys.argv", ["tool", "--artifact", "private-marker.ipa", "--public-key", "private-marker.pem", "--destination", "private-marker"]), patch("encrypted_artifact_context.capture", side_effect=error), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(main(), 1)
        self.assertNotIn(SAMPLE.decode(), stdout.getvalue() + stderr.getvalue())
        self.assertNotIn("private-marker", stdout.getvalue() + stderr.getvalue())
        self.assertIn("Privacy gate unchanged", stdout.getvalue())
