import hashlib
import struct
import unittest
from types import SimpleNamespace
from signature_origin import signature_origin
from privacy_check import inspect, EMAIL, artifact_context
from unittest.mock import patch


def fixture(version=0x20001, limit64=False, seed=None):
    minimum = 64 if version >= 0x20300 else 44
    ident = b"synthetic\0"
    cd_length = minimum + len(ident) + 32
    signature_length = 20 + cd_length
    header = b"\xcf\xfa\xed\xfe" + struct.pack("<7I", 0x100000c, 0, 6, 1, 16, 0, 0)
    command = struct.pack("<4I", 0x1d, 16, 64, signature_length)
    page = header + command + (b"synthetic bytes!" if seed is None else struct.pack(">QQ", seed, 0))
    assert len(page) == 64
    digest = hashlib.sha256(page).digest()
    cd = struct.pack(">9I4BI", 0xfade0c02, cd_length, version, 0, minimum + len(ident), minimum,
                     0, 1, 0 if limit64 else 64, 32, 2, 0, 12, 0)
    if minimum == 64:
        cd += struct.pack(">IIIQ", 0, 0, 0, 64 if limit64 else 0)
    signature = struct.pack(">5I", 0xfade0cc0, signature_length, 1, 0, 20) + cd + ident + digest
    start = 64 + 20 + minimum + len(ident) + 4
    return page + signature, start


def match(start, size=6):
    return SimpleNamespace(start=lambda: start, end=lambda: start + size)


class SignatureOriginTests(unittest.TestCase):
    def test_recomputes_real_page_digest_in_thin_and_universal(self):
        for version, limit64 in ((0x20001, False), (0x20300, False), (0x20300, True)):
            data, start = fixture(version, limit64)
            self.assertEqual(signature_origin(data, match(start)), "verified-sha256-code-page-hash")
            wrapped = b"\xca\xfe\xba\xbe" + struct.pack(">6I", 1, 0x100000c, 0, 28, len(data), 0) + data
            self.assertEqual(signature_origin(wrapped, match(start + 28)), "verified-sha256-code-page-hash")

    def test_tampering_signature_text_and_cross_slot_matches_do_not_verify(self):
        data, start = fixture()
        corrupt = bytearray(data); corrupt[55] ^= 1
        self.assertEqual(signature_origin(bytes(corrupt), match(start)), "code-signature-unverified")
        corrupt = bytearray(data); corrupt[start] ^= 1
        self.assertEqual(signature_origin(bytes(corrupt), match(start)), "code-signature-unverified")
        self.assertEqual(signature_origin(data, match(64 + 20 + 44)), "code-signature-unverified")
        self.assertNotEqual(signature_origin(data, match(len(data) - 2)), "verified-sha256-code-page-hash")
        self.assertEqual(signature_origin(data, match(52)), "outside-code-signature")

    def test_malformed_tables_and_unsupported_algorithms_do_not_verify(self):
        valid, start = fixture()
        for offset, value in ((40, 0xffffffff), (44, 0xffffffff), (64, 0), (68, 0xffffffff), (72, 65),
                              (80, 0xffffffff), (84, 0), (88, 0xffffffff), (112, 0xffffffff)):
            data = bytearray(valid); struct.pack_into(">I" if offset >= 64 else "<I", data, offset, value)
            self.assertNotEqual(signature_origin(bytes(data), match(start)), "verified-sha256-code-page-hash")
        self.assertEqual(signature_origin(b"unknown", match(0)), "unknown-native-layout")

    def test_report_does_not_clear_address_or_credential_findings(self):
        sample = b"owner@" + b"unlisted-domain.org"
        self.assertIn("email-address-review", inspect(sample, check_path=False, artifact=True))
        data, start = fixture()
        self.assertNotIn("synthetic", signature_origin(data, match(start)))


class ReviewedCodeHashTests(unittest.TestCase):
    def synthetic(self):
        data, start = fixture(seed=562165)
        found = list(EMAIL.finditer(data))
        self.assertEqual(len(found), 1)
        return data, found[0], hashlib.sha256(found[0].group()).hexdigest()

    def test_exact_allowlist_and_recomputed_digest_are_both_required(self):
        data, found, digest = self.synthetic()
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        self.assertIn("email-address-review", inspect(data, path, False, True))
        with patch("privacy_check.REVIEWED_CODE_PAGE_HASHES", frozenset({digest})):
            self.assertNotIn("email-address-review", inspect(data, path, False, True))
            self.assertIn("reviewed-code-page-hashes: 1", artifact_context(path, data))
            self.assertIn("distinct-review-addresses: 0", artifact_context(path, data))
            # Source/history and other binaries never receive the exception.
            self.assertIn("email-address-review", inspect(data, path, False, False))
            for other in ("other.bin", "lib/arm64-v8a/libapp.so", "Payload/Synthetic.app/Frameworks/Flutter.framework/Flutter"):
                self.assertIn("email-address-review", inspect(data, other, False, True))
            # A changed page fails digest verification even if the matched bytes remain.
            altered = bytearray(data); altered[55] ^= 1
            self.assertIn("email-address-review", inspect(bytes(altered), path, False, True))
            # Literal replay of the exact same six bytes is never exempted.
            replay = data + b"\0" + found.group() + b"\0"
            self.assertIn("email-address-review", inspect(replay, path, False, True))
            # Other address/credential categories remain blocking next to the hash.
            address = b"owner@" + b"unlisted-domain.org"
            key = b"ma_" + b"q" * 43
            result = inspect(data + b"\0" + address + b"\0" + key, path, False, True)
            self.assertIn("email-address-review", result)
            self.assertIn("mail-archiver-key-shaped", result)

    def test_verified_unlisted_hash_and_changed_allowed_hash_stay_blocking(self):
        data, found, digest = self.synthetic()
        path = "Payload/Synthetic.app/Frameworks/App.framework/App"
        with patch("privacy_check.REVIEWED_CODE_PAGE_HASHES", frozenset({"0" * 64})):
            self.assertIn("email-address-review", inspect(data, path, False, True))
        with patch("privacy_check.REVIEWED_CODE_PAGE_HASHES", frozenset({digest})):
            changed = bytearray(data); changed[found.start()] ^= 1
            self.assertNotEqual(signature_origin(bytes(changed), match(found.start())), "verified-sha256-code-page-hash")
