"""Bundled native license bytes must be reproducible on Windows and Linux."""
import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class NativeNoticeProvenanceTests(unittest.TestCase):
    def test_guava_checkout_bytes_match_both_provenance_records(self):
        provenance = json.loads((ROOT / 'docs/development/guava-notice-provenance.json').read_text(encoding='utf-8'))
        evidence = json.loads((ROOT / 'docs/development/android-native-license-evidence.json').read_text(encoding='utf-8'))
        notice = (ROOT / provenance['asset']).read_bytes()
        self.assertNotIn(b'\r', notice, 'Bundled notice must retain canonical LF bytes on every build host')
        self.assertTrue(notice.endswith(b'\n'))
        digest = hashlib.sha256(notice).hexdigest()
        self.assertEqual(digest, provenance['asset_sha256'])
        self.assertEqual(digest, evidence['guava_asset_sha256'])
        self.assertEqual(provenance['source_archive_sha256'], evidence['guava_source_archive_sha256'])
        self.assertIn('LF', provenance['asset_hash_basis'])
        self.assertIn('LF', evidence['guava_asset_hash_basis'])

if __name__ == '__main__':
    unittest.main()
