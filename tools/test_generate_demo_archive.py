"""Checks for the bundled demo archive: current, fictional and complete."""
import json
from pathlib import Path
import re
import unittest

import generate_demo_archive as generator

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "assets" / "demo" / "archive.json"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")


class DemoArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = ARCHIVE.read_bytes()
        cls.data = json.loads(cls.raw)

    def test_committed_files_match_generator(self):
        self.assertEqual(generator.main(["--check"]), 0)

    def test_generation_is_deterministic(self):
        first, second = generator.build(), generator.build()
        self.assertEqual(first, second)

    def test_only_reserved_example_domains(self):
        texts = [self.raw.decode("utf-8")]
        texts += [p.read_text(encoding="utf-8") for p in generator.ATTACH.iterdir() if p.suffix in {".txt", ".html"}]
        for text in texts:
            for domain in EMAIL.findall(text):
                domain = domain.lower().rstrip(".")
                self.assertTrue(
                    domain in {"example.com", "example.org", "example.net"} or domain.endswith(".example"),
                    domain)
        for url in re.findall(r"https?://([A-Za-z0-9.-]+)", self.raw.decode("utf-8")):
            self.assertTrue(url.endswith((".example", "example.com", "example.org", "example.net")), url)

    def test_no_credentials_or_carriage_returns(self):
        text = self.raw.decode("utf-8")
        self.assertNotIn("\r", text)
        self.assertNotRegex(text, r"\bma_[A-Za-z0-9_-]{20,}")
        self.assertNotRegex(text, r"(?i)\b(?:api[_ ]?key|password|bearer)\s*[:=]")

    def test_ids_folders_and_attachments_are_consistent(self):
        messages = self.data["messages"]
        ids = [m["id"] for m in messages]
        self.assertEqual(len(ids), len(set(ids)))
        account_ids = {a["id"] for a in self.data["accounts"]}
        attachment_ids = []
        for mail in messages:
            self.assertIn(mail["accountId"], account_ids)
            self.assertIn(mail["folderName"], generator.FOLDERS[mail["accountId"]])
            self.assertEqual(mail["hasAttachments"], bool(mail["attachments"]))
            for file in mail["attachments"]:
                attachment_ids.append(file["id"])
                path = generator.ATTACH / file["fileName"]
                self.assertTrue(path.is_file(), file["fileName"])
                self.assertEqual(path.stat().st_size, file["size"])
                self.assertEqual(self.data["attachmentFiles"][str(file["id"])], file["fileName"])
        self.assertEqual(len(attachment_ids), len(set(attachment_ids)))

    def test_covers_the_features_the_demo_shows(self):
        messages = self.data["messages"]
        html = [m["htmlBody"] or "" for m in messages]
        self.assertTrue(any("<img" in body and "https://" in body for body in html), "blocked remote image")
        self.assertTrue(any('href="http://' in body for body in html), "unencrypted link warning")
        self.assertTrue(any("<table" in body for body in html), "complex table")
        self.assertTrue(any(m["folderName"] == "Junk" for m in messages), "caution folder")
        self.assertTrue(any(m["isOutgoing"] for m in messages), "outgoing mail")
        self.assertTrue(any(m["subject"] is None for m in messages), "missing subject")
        self.assertTrue(any(m["sentDate"] == "" for m in messages), "missing date")
        self.assertTrue(any(len(m["sentDate"]) == 19 for m in messages), "date without time zone")
        self.assertTrue(any(len(m["textBody"]) > 5000 for m in messages), "long message")
        names = [f["fileName"] for m in messages for f in m["attachments"]]
        self.assertTrue(any(n.endswith(".html") for n in names), "risky attachment caution")
        self.assertTrue(any(n.endswith(".pdf") for n in names) and any(n.endswith(".png") for n in names))
        per_account = {}
        for mail in messages:
            per_account[mail["accountId"]] = per_account.get(mail["accountId"], 0) + 1
        self.assertGreater(per_account[1], 25, "first account needs more than one page")
        self.assertEqual(len(per_account), 3)
        for mail in messages:
            if mail["folderName"].endswith("/2021"):
                self.assertTrue(mail["sentDate"].startswith("2021-"), mail["subject"])

    def test_assets_are_declared_and_small(self):
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertIn("    - assets/demo/\n", pubspec)
        self.assertIn("    - assets/demo/attachments/\n", pubspec)
        total = ARCHIVE.stat().st_size + sum(p.stat().st_size for p in generator.ATTACH.iterdir())
        self.assertLess(total, 250_000)


if __name__ == "__main__":
    unittest.main()
