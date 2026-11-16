import io
import mailbox
import re
import tempfile
import unittest
from pathlib import Path

import bichon_fixtures as fx

RESERVED = re.compile(r"@([a-z0-9-]+\.)*(example|example\.com)>?$")


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.tmp.name) / "mailburrow-fixtures.mbox"
        out = io.StringIO()
        assert fx.main(["--out", str(cls.path)], out=out) == 0
        cls.box = list(mailbox.mbox(str(cls.path)))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_counts_and_bound(self):
        self.assertEqual(len(self.box), 2 + fx.SMALL_MESSAGES)
        self.assertLessEqual(self.path.stat().st_size, fx.MAX_OUTPUT_BYTES)

    def test_every_message_is_marked_and_fictional(self):
        ids = set()
        for msg in self.box:
            self.assertTrue(msg["Subject"].startswith(fx.MARKER + ": "))
            self.assertRegex(msg["Message-ID"], r"^<mailburrow-fixture-\d+@fixtures\.example>$")
            ids.add(msg["Message-ID"])
            for header in ("From", "To"):
                self.assertRegex(msg[header], RESERVED, header)
        self.assertEqual(len(ids), len(self.box), "Message-IDs are unique")

    def test_large_message_bodies(self):
        large = self.box[0]
        parts = {p.get_content_type(): p.get_payload(decode=True) for p in large.walk()
                 if not p.is_multipart()}
        self.assertEqual(len(parts["text/plain"].decode().rstrip("\n")), fx.LARGE_BODY_BYTES)
        self.assertEqual(len(parts["text/html"].decode().rstrip("\n")), fx.LARGE_BODY_BYTES)
        # Two bodies plus JSON framing must stay under the 8 MiB response limit.
        self.assertLess(2 * fx.LARGE_BODY_BYTES + 100_000, 8 * 1024 * 1024)

    def test_attachment_is_exactly_45_mib(self):
        files = [p for p in self.box[1].walk() if p.get_filename()]
        self.assertEqual([p.get_filename() for p in files], ["fixture-45mib.bin"])
        self.assertEqual(len(files[0].get_payload(decode=True)), 45 * 1024 * 1024)
        self.assertLess(fx.ATTACHMENT_BYTES, 50 * 1024 * 1024)

    def test_output_is_deterministic(self):
        again = Path(self.tmp.name) / "again.mbox"
        fx.main(["--out", str(again)], out=io.StringIO())
        self.assertEqual(again.read_bytes(), self.path.read_bytes())

    def test_rejects_non_mbox_name(self):
        out = io.StringIO()
        self.assertEqual(fx.main(["--out", str(Path(self.tmp.name) / "x.eml")], out=out), 2)


if __name__ == "__main__":
    unittest.main()
