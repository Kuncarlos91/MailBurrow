import email
import re
import struct
import zlib
import tempfile
import unittest
import zipfile
from email import policy
from pathlib import Path

import generate_stress_mail as stress


class StressMailTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.path, cls.summary = stress.export(Path(cls.tmp.name))
        cls.zip = zipfile.ZipFile(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.zip.close()
        cls.tmp.cleanup()

    def message(self, case):
        name = next(n for n in self.zip.namelist() if n.endswith(f"-{case}.eml"))
        return self.zip.read(name)

    def test_every_case_is_written_once_in_inbox(self):
        names = self.zip.namelist()
        self.assertEqual(len(names), len(stress.CASES))
        self.assertTrue(all(n.startswith("INBOX/stress-") and n.endswith(".eml") for n in names))

    def test_output_is_deterministic(self):
        with tempfile.TemporaryDirectory() as other:
            again, _ = stress.export(Path(other))
            self.assertEqual(self.path.read_bytes(), again.read_bytes())

    def test_sizes_straddle_the_message_limit(self):
        sizes = {case: size for _, case, size in self.summary}
        self.assertLess(sizes["near-limit"], stress.MESSAGE_LIMIT)
        self.assertGreater(sizes["near-limit"], stress.MESSAGE_LIMIT - stress.MIB)
        self.assertGreater(sizes["over-limit"], stress.MESSAGE_LIMIT)
        # Exact compact Buffer-array expansion, without allocating a huge list.
        for case in ("near-limit", "over-limit"):
            data = self.message(case)
            wire = len('{"raw":{"type":"Buffer","data":[]}}') + sum(len(str(b)) + 1 for b in data) - 1
            self.assertLess(wire, 40 * stress.MIB, case)

    def test_structure_stays_inside_the_app_limits_except_size(self):
        def depth(part, level=0):
            if not part.is_multipart():
                return level
            return max(depth(child, level + 1) for child in part.iter_parts())
        nested = email.message_from_bytes(self.message("nested-30"), policy=policy.default)
        self.assertEqual(depth(nested), 30)
        many = email.message_from_bytes(self.message("many-parts-400"), policy=policy.default)
        self.assertEqual(sum(1 for p in many.walk() if not p.is_multipart()), 400)
        self.assertTrue(all(p.get_filename() is None and p.get_content_disposition() is None
                            for p in many.walk() if not p.is_multipart()))
        headers = self.message("large-headers-200k").split(b"\r\n\r\n", 1)[0]
        self.assertGreater(len(headers), 150 * 1024)
        self.assertLess(len(headers), 256 * 1024)

    def test_inline_images_are_valid_pngs_referenced_by_cid(self):
        msg = email.message_from_bytes(self.message("inline-images-6m"), policy=policy.default)
        images = [p for p in msg.walk() if p.get_content_type() == "image/png"]
        self.assertEqual(len(images), 6)
        html = next(p for p in msg.walk() if p.get_content_type() == "text/html").get_content()
        for image in images:
            self.assertEqual(image.get_content_disposition(), "inline")
            data = image.get_content()
            self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
            at, compressed = 8, bytearray()
            while at < len(data):
                size = struct.unpack(">I", data[at:at + 4])[0]
                kind = data[at + 4:at + 8]
                payload = data[at + 8:at + 8 + size]
                crc = struct.unpack(">I", data[at + 8 + size:at + 12 + size])[0]
                self.assertEqual(crc, zlib.crc32(kind + payload))
                if kind == b"IDAT":
                    compressed.extend(payload)
                at += size + 12
            self.assertEqual(at, len(data))
            self.assertEqual(len(zlib.decompress(compressed)), 512 * (1 + 512 * 3))
            self.assertIn("cid:" + image["Content-ID"].strip("<>"), html)

    def test_legacy_charsets_are_the_selected_body_alternatives(self):
        msg = email.message_from_bytes(self.message("legacy-charsets"), policy=policy.default)
        plain = msg.get_body(preferencelist=("plain",))
        html = msg.get_body(preferencelist=("html",))
        self.assertEqual(plain.get_content_charset(), "iso-8859-1")
        self.assertEqual(html.get_content_charset(), "windows-1252")
        self.assertIn("señor", plain.get_content())
        self.assertIn("€ euro", html.get_content())

    def test_only_reserved_example_addresses(self):
        for name in self.zip.namelist():
            msg = email.message_from_bytes(self.zip.read(name), policy=policy.default)
            texts = []
            for part in msg.walk():
                texts += [str(value) for value in part.values()]
                if part.get_content_maintype() == "text":
                    texts.append(part.get_content())
            for address in re.findall(r"[\w.+-]+@[\w.-]+\w", "\n".join(texts)):
                self.assertTrue(address.endswith(".example"), (name, address))


if __name__ == "__main__":
    unittest.main()
