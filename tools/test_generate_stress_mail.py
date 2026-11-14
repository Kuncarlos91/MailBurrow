import email
import re
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

    def test_structure_stays_inside_the_app_limits_except_size(self):
        def depth(part, level=0):
            if not part.is_multipart():
                return level
            return max(depth(child, level + 1) for child in part.iter_parts())
        nested = email.message_from_bytes(self.message("nested-30"), policy=policy.default)
        self.assertEqual(depth(nested), 30)
        many = email.message_from_bytes(self.message("many-parts-400"), policy=policy.default)
        self.assertEqual(sum(1 for p in many.walk() if not p.is_multipart()), 400)
        headers = self.message("large-headers-200k").split(b"\r\n\r\n", 1)[0]
        self.assertGreater(len(headers), 150 * 1024)
        self.assertLess(len(headers), 256 * 1024)

    def test_inline_images_are_valid_pngs_referenced_by_cid(self):
        msg = email.message_from_bytes(self.message("inline-images-6m"), policy=policy.default)
        images = [p for p in msg.walk() if p.get_content_type() == "image/png"]
        self.assertEqual(len(images), 6)
        html = next(p for p in msg.walk() if p.get_content_type() == "text/html").get_content()
        for image in images:
            self.assertTrue(image.get_content().startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertIn("cid:" + image["Content-ID"].strip("<>"), html)

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
