import hashlib
import json
import mailbox
from pathlib import Path
import tempfile
import unittest
from email import policy
from email.parser import BytesParser
from generate_demo_mail import generate, ROOT
from privacy_check import inspect


class SyntheticReviewMailTests(unittest.TestCase):
    def test_roundtrip_accounts_folders_pagination_mime_and_privacy(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "dataset"
            manifest = generate(output)
            self.assertTrue(manifest["synthetic_only"])
            ids, messages = set(), []
            for account in manifest["accounts"]:
                other = "BETA" if account["label"] == "ALPHA" else "ALPHA"
                self.assertEqual([f["messages"] for f in account["folders"]], [60, 6, 6])
                for folder in account["folders"]:
                    path = output / folder["file"]
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), folder["sha256"])
                    self.assertFalse(inspect(path.read_bytes(), check_path=False))
                    box = mailbox.mbox(path, factory=lambda f: BytesParser(policy=policy.default).parse(f))
                    try:
                        self.assertEqual(len(box), folder["messages"])
                        for msg in box:
                            self.assertNotIn(msg["Message-ID"], ids)
                            ids.add(msg["Message-ID"])
                            self.assertIn(account["label"], msg["Subject"])
                            self.assertNotIn(other, msg["Subject"])
                            text = msg.get_body(preferencelist=("plain",)).get_content()
                            self.assertIn("From this line onward", text)
                            self.assertNotIn(other, text)
                            self.assertTrue(all("example.invalid" in str(msg[h]) for h in ("From", "To", "Message-ID")))
                            messages.append(msg)
                    finally:
                        box.close()
            self.assertEqual(len(ids), 144)
            self.assertEqual(sum(1 for m in messages if m.get_body(preferencelist=("html",)) is not None), 6)
            self.assertTrue(any("日本語" in m["Subject"] for m in messages))
            self.assertTrue(any(len(m.get_body(preferencelist=("plain",)).get_content()) > 20000 for m in messages))
            attachments = [part for m in messages for part in m.iter_attachments()]
            self.assertEqual(len(attachments), 4)
            self.assertEqual(set(p.get_content_type() for p in attachments), {"text/plain", "text/csv"})
            self.assertTrue(all(p.get_payload(decode=True) for p in attachments))

    def test_outputs_are_reproducible_and_existing_data_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            first, second = Path(temp) / "one", Path(temp) / "two"
            a, b = generate(first), generate(second)
            self.assertEqual(a, b)
            self.assertEqual((first / "manifest.json").read_bytes(), (second / "manifest.json").read_bytes())
            before = (first / "alpha/INBOX.mbox").read_bytes()
            with self.assertRaises(ValueError): generate(first)
            self.assertEqual(before, (first / "alpha/INBOX.mbox").read_bytes())

    def test_repository_output_is_rejected_without_writing(self):
        with self.assertRaises(ValueError): generate(ROOT)
        target = ROOT / "never-created-demo-mail"
        self.assertFalse(target.exists())
        with self.assertRaises(ValueError): generate(target)
        self.assertFalse(target.exists())
