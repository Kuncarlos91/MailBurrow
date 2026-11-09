import tempfile
import unittest
from pathlib import Path
from check_docs import check_documents


class DocumentationLinkTests(unittest.TestCase):
    def test_relative_paths_headings_and_duplicate_headings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "README.md").write_text("[Guide](docs/guide.md#setup-1)", encoding="utf-8")
            (root / "docs/guide.md").write_text("# Setup\n# Setup\n[Back](../README.md)", encoding="utf-8")
            count, errors = check_documents(root)
            self.assertEqual(count, 2)
            self.assertEqual(errors, [])

    def test_reports_missing_destination_heading_and_path_escape_without_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("[a](missing-secret.md) [b](#missing) [c](../outside.md)", encoding="utf-8")
            _, errors = check_documents(root)
            self.assertEqual(len(errors), 3)
            self.assertNotIn("missing-secret", str(errors))
            self.assertEqual({e[2] for e in errors}, {
                "missing local destination", "missing local heading", "destination escapes repository"})

    def test_skips_external_links_code_examples_and_upstream_notice_bodies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("[Web](https://example.com)\n```md\n[Example](absent.md)\n```\n", encoding="utf-8")
            (root / "THIRD_PARTY_NOTICES.md").write_text("[Upstream](upstream-only.md)", encoding="utf-8")
            self.assertEqual(check_documents(root), (0, []))

    def test_utf8_and_percent_encoded_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide one.md").write_text("# Setup", encoding="utf-8")
            (root / "README.md").write_text("[Guide](guide%20one.md#setup)", encoding="utf-8")
            self.assertEqual(check_documents(root), (1, []))
            (root / "README.md").write_bytes(bytes([255]))
            self.assertEqual(check_documents(root)[1][0][2], "not UTF-8")


if __name__ == "__main__":
    unittest.main()
