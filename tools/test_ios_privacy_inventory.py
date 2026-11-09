import contextlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile
from ios_privacy_inventory import inventory, main


class PrivacyInventoryTests(unittest.TestCase):
    def make(self, root, data, raw=None):
        path = Path(root) / 'fixture.ipa'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Runner.app/Frameworks/Flutter.framework/PrivacyInfo.xcprivacy', raw if raw is not None else plistlib.dumps(data))
            archive.writestr('Payload/Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z', b'fixture')
        return path

    def test_inventory_counts_resources_without_exposing_domains_or_payloads(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.make(root, {'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': ['private.invalid'],
                'NSPrivacyCollectedDataTypes': [{'private': 'unreviewed value'}],
                'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]})
            result = inventory(path)
            self.assertEqual(result['manifest_count'], 1)
            self.assertEqual(result['bundled_notice_asset_count'], 1)
            self.assertFalse(result['compliance_verified'])
            self.assertEqual(result['manifests'][0]['component'], 'Flutter')
            self.assertEqual(result['manifests'][0]['tracking_domain_count'], 1)
            text = json.dumps(result)
            for withheld in ('private.invalid', 'unreviewed value', 'Payload/', root):
                self.assertNotIn(withheld, text)

    def test_omitted_tracking_declaration_remains_unknown(self):
        with tempfile.TemporaryDirectory() as root:
            result = inventory(self.make(root, {}))
            self.assertIsNone(result['manifests'][0]['tracking'])
            self.assertFalse(result['compliance_verified'])

    def test_missing_manifest_is_reported_without_compliance_signoff(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'fixture.ipa'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('Payload/Runner.app/Info.plist', b'fixture')
            result = inventory(path)
            self.assertEqual(result['manifest_count'], 0)
            self.assertFalse(result['compliance_verified'])

    def test_malformed_manifest_reports_only_fixed_error(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.make(root, {}, raw=b'private fixture contents')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(path)]), 2)
            self.assertNotIn(root, output.getvalue())
            self.assertNotIn('private fixture contents', output.getvalue())

    def test_untrusted_reason_text_is_not_echoed(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.make(root, {'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['private fixture contents']}]})
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(path)]), 2)
            self.assertNotIn('private fixture contents', output.getvalue())
