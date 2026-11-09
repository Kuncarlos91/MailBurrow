import unittest
from pathlib import Path
from configure_ios_signing import BLOCK, BUNDLE, configure

class ConfigureIOSSigningTests(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).resolve().parents[1] / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.team = 'TESTTEAM01'
        self.profile = '12345678-1234-1234-1234-123456789abc'

    def test_only_app_configs_change(self):
        changed = configure(self.text, self.team, self.profile)
        before = list(BLOCK.finditer(self.text)); after = list(BLOCK.finditer(changed))
        self.assertEqual(len(before), len(after))
        app_count = 0
        for a, b in zip(before, after):
            if 'PRODUCT_BUNDLE_IDENTIFIER = ' + BUNDLE + ';' in a[2]:
                app_count += 1
                self.assertIn('CODE_SIGN_STYLE = Manual;', b[2])
                self.assertIn('DEVELOPMENT_TEAM = ' + self.team + ';', b[2])
                self.assertIn('PROVISIONING_PROFILE_SPECIFIER = "' + self.profile + '";', b[2])
            else:
                self.assertEqual(a[0], b[0])
        self.assertEqual(app_count, 3)
        self.assertEqual(BLOCK.sub('', self.text), BLOCK.sub('', changed))

    def test_reapplying_does_not_duplicate_settings(self):
        changed = configure(self.text, self.team, self.profile)
        self.assertEqual(changed, configure(changed, self.team, self.profile))

    def test_invalid_values_rejected(self):
        for team, profile in [(self.team + ';', self.profile), (self.team, 'not-a-profile')]:
            with self.assertRaises(ValueError): configure(self.text, team, profile)

    def test_unexpected_project_layout_rejected(self):
        with self.assertRaises(ValueError): configure(self.text.replace(BUNDLE, 'different.bundle'), self.team, self.profile)

if __name__ == '__main__':
    unittest.main()
