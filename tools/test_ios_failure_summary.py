import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from ios_failure_summary import classify, main

class IOSFailureSummaryTests(unittest.TestCase):
    def test_unsupported_target_profile(self):
        self.assertEqual(classify('Target ExamplePod does not support provisioning profiles.'),
                         ['profile-applied-to-unsupported-target'])

    def test_certificate_mismatch(self):
        self.assertEqual(classify('Provisioning profile "Synthetic Profile" doesn\'t include signing certificate "Synthetic Owner".'),
                         ['profile-certificate-mismatch'])

    def test_unknown_error_does_not_echo_private_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private.log'
            path.write_text('private-marker-987 error: unknown failure', encoding='utf-8')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(path)]), 0)
            self.assertNotIn('private-marker-987', output.getvalue())
            self.assertNotIn(str(path), output.getvalue())
            self.assertIn('unclassified-native-failure', output.getvalue())

    def test_missing_log_does_not_echo_path(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(['missing-private-marker.log']), 2)
        self.assertNotIn('missing-private-marker', output.getvalue())

if __name__ == '__main__':
    unittest.main()
