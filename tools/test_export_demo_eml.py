"""Tests for tools/export_demo_eml.py (fictional demo mail as zipped .eml)."""
import email
import hashlib
import json
import tempfile
import unittest
import zipfile
from email import policy
from pathlib import Path

from export_demo_eml import DEMO, export


class ExportDemoEmlTests(unittest.TestCase):
    def setUp(self):
        self.archive = json.loads((DEMO / "archive.json").read_text(encoding="utf-8"))
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)
        self.written = export(self.out)

    def test_one_zip_per_account_with_every_message_and_attachment(self):
        self.assertEqual(len(self.written), len(self.archive["accounts"]))
        self.assertEqual(sum(count for _, _, count, _ in self.written), len(self.archive["messages"]))
        expected = sum(len(m.get("attachments") or []) for m in self.archive["messages"])
        self.assertEqual(sum(n for _, _, _, n in self.written), expected)

    def test_messages_parse_and_keep_folders_subjects_and_attachments(self):
        by_id = {m["id"]: m for m in self.archive["messages"]}
        for path, _, _, _ in self.written:
            with zipfile.ZipFile(path) as archive_zip:
                for name in archive_zip.namelist():
                    message = email.message_from_bytes(archive_zip.read(name), policy=policy.default)
                    source = by_id[int(name.rsplit("-", 1)[1].split(".")[0])]
                    self.assertEqual(name.rsplit("/", 1)[0], source["folderName"])
                    self.assertEqual(message["Subject"], source["subject"])  # None when the demo has no subject
                    self.assertEqual(message["X-MailBurrow-Demo"], "fictional sample message")
                    names = [part.get_filename() for part in message.iter_attachments()]
                    self.assertEqual(names, [a["fileName"] for a in source.get("attachments") or []])

    def test_only_reserved_example_domains(self):
        for path, _, _, _ in self.written:
            with zipfile.ZipFile(path) as archive_zip:
                for name in archive_zip.namelist():
                    message = email.message_from_bytes(archive_zip.read(name), policy=policy.default)
                    for header in ("From", "To"):
                        domain = str(message[header]).rsplit("@", 1)[1].rstrip(">").lower()
                        self.assertTrue(domain in ("example.com", "example.net", "example.org")
                                        or domain.endswith(".example"), domain)

    def test_output_is_reproducible(self):
        first = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p, _, _, _ in self.written}
        again = export(self.out / "again")
        second = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p, _, _, _ in again}
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
