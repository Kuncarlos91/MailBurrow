"""Tests for tools/export_demo_eml.py (fictional demo mail as zipped .eml).

Every check compares the exported files with the source fixtures
(assets/demo/archive.json and assets/demo/attachments/) independently of the
counts the exporter reports about itself.
"""
import email
import hashlib
import json
import tempfile
import unittest
import zipfile
from datetime import datetime
from email import policy
from email.utils import parsedate_to_datetime
from pathlib import Path

from export_demo_eml import DEMO, SLUGS, export


def normalize(text):
    """MIME serialization uses CRLF and may add a final newline."""
    return (text or "").replace("\r\n", "\n").rstrip("\n")


class ExportDemoEmlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive = json.loads((DEMO / "archive.json").read_text(encoding="utf-8"))
        cls.by_id = {m["id"]: m for m in cls.archive["messages"]}
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.written = export(cls.out)
        # Parse every ZIP entry once: {zip name: {entry name: parsed message}}
        cls.parsed = {}
        for path, _, _, _ in cls.written:
            with zipfile.ZipFile(path) as archive_zip:
                cls.parsed[path.name] = {
                    name: email.message_from_bytes(archive_zip.read(name), policy=policy.default)
                    for name in archive_zip.namelist()
                }

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def source_for(self, entry_name):
        return self.by_id[int(entry_name.rsplit("-", 1)[1].split(".")[0])]

    def test_every_message_exactly_once_in_its_account_zip(self):
        expected_zips = {SLUGS[a["emailAddress"]] + ".zip": a["id"] for a in self.archive["accounts"]}
        self.assertEqual(set(self.parsed), set(expected_zips))
        seen = []
        for zip_name, entries in self.parsed.items():
            for name in entries:
                source = self.source_for(name)
                self.assertEqual(source["accountId"], expected_zips[zip_name], name)
                seen.append(source["id"])
        self.assertEqual(sorted(seen), sorted(self.by_id))  # each once, none missing

    def test_message_ids_are_unique_and_deterministic(self):
        ids = []
        for entries in self.parsed.values():
            for name, message in entries.items():
                self.assertEqual(message["Message-ID"],
                                 "<demo-%d@mailburrow.example>" % self.source_for(name)["id"])
                ids.append(message["Message-ID"])
        self.assertEqual(len(ids), len(set(ids)))

    def test_headers_match_the_fixtures(self):
        for entries in self.parsed.values():
            for name, message in entries.items():
                source = self.source_for(name)
                self.assertEqual(name.rsplit("/", 1)[0], source["folderName"], name)
                self.assertEqual(message["Subject"], source["subject"], name)  # None if no subject
                self.assertEqual(str(message["From"]), source["from"], name)
                self.assertEqual(str(message["To"]), source["to"], name)
                self.assertEqual(message["X-MailBurrow-Demo"], "fictional sample message")
                date = source["sentDate"] or source["receivedDate"]
                if date:
                    expected = datetime.fromisoformat(date.replace("Z", "+00:00"))
                    self.assertEqual(parsedate_to_datetime(message["Date"]), expected, name)
                else:
                    self.assertIsNone(message["Date"], name)

    def test_bodies_match_the_fixtures(self):
        for entries in self.parsed.values():
            for name, message in entries.items():
                source = self.source_for(name)
                plain = message.get_body(("plain",))
                self.assertEqual(normalize(plain.get_content() if plain else ""),
                                 normalize(source["textBody"]), name)
                html = message.get_body(("html",))
                if source.get("htmlBody"):
                    self.assertIsNotNone(html, name)
                    self.assertEqual(normalize(html.get_content()), normalize(source["htmlBody"]), name)
                else:
                    self.assertIsNone(html, name)

    def test_attachments_match_names_types_and_exact_bytes(self):
        files = self.archive["attachmentFiles"]
        total = 0
        for entries in self.parsed.values():
            for name, message in entries.items():
                parts = list(message.iter_attachments())
                expected = self.source_for(name).get("attachments") or []
                self.assertEqual(len(parts), len(expected), name)
                for part, attachment in zip(parts, expected):
                    self.assertEqual(part.get_filename(), attachment["fileName"], name)
                    self.assertEqual(part.get_content_type(), attachment["contentType"], name)
                    original = (DEMO / "attachments" / files[str(attachment["id"])]).read_bytes()
                    self.assertEqual(part.get_payload(decode=True), original, name)
                total += len(parts)
        self.assertEqual(total, sum(len(m.get("attachments") or []) for m in self.archive["messages"]))

    def test_reported_counts_match_the_zip_contents(self):
        for path, _, count, attachments in self.written:
            entries = self.parsed[path.name]
            self.assertEqual(count, len(entries))
            self.assertEqual(attachments, sum(len(list(m.iter_attachments())) for m in entries.values()))

    def test_only_reserved_example_domains(self):
        for entries in self.parsed.values():
            for message in entries.values():
                for header in ("From", "To"):
                    domain = str(message[header]).rsplit("@", 1)[1].rstrip(">").lower()
                    self.assertTrue(domain in ("example.com", "example.net", "example.org")
                                    or domain.endswith(".example"), domain)

    def test_output_is_reproducible(self):
        first = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p, _, _, _ in self.written}
        with tempfile.TemporaryDirectory() as again_dir:
            again = export(Path(again_dir))
            second = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p, _, _, _ in again}
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
