import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from check_pr_text import MAX_INPUT_BYTES, event_text, findings, main


class PrTextTests(unittest.TestCase):
    def test_private_references_are_rejected(self):
        for value in (
            "MailShelf run 12345678901 failed before signing.",
            "MailShelf PR #123",
            "private workflow run #12345",
            "https://github.com/example-owner/MailShelf/actions/runs/12345",
            "https://api.github.com/repos/example-owner/MailShelf/pulls/123",
            "example-owner/MailShelf#123",
        ):
            with self.subTest(value=value):
                self.assertTrue(findings("", value))

    def test_internal_distribution_details_are_rejected(self):
        for value in (
            "After merge, the owner approved restarting TestFlight build 99.",
            "Maintainer-approved signing workflow run.",
            "Approved by the owner: restart TestFlight.",
            "Build 99 was not consumed.",
        ):
            with self.subTest(value=value):
                self.assertTrue(findings("", value))

    def test_public_compatibility_and_legacy_names_are_allowed(self):
        self.assertFalse(findings(
            "Platform-aware certificate tests",
            "macOS host tests reject over-limit chains; iOS device checks remain pending.\n"
            "Linux CI passed: https://github.com/example-owner/MailBurrow/actions/runs/12345\n"
            "MailShelf was the app's former name. Keep MAILSHELF_BUILD_VERSION unchanged.\n"
            "A synthetic converter is example-owner/MailShelf-tools.\n"
            "The maintainer approved the new trust-warning wording.\n"
            "Android 0.6.0 build 33. No signing or upload was performed.",
        ))

    def test_title_and_body_both_use_the_existing_secret_classifier(self):
        token = "gh" + "p_" + "q" * 36
        self.assertIn("provider-token-shaped", findings(token, ""))
        self.assertIn("provider-token-shaped", findings("", token))
        self.assertIn("private-run-reference", findings("MailShelf run 12345", ""))

    def test_null_body_is_valid_but_missing_or_non_text_fields_fail(self):
        self.assertEqual(event_text('{"pull_request":{"title":"Fix","body":null}}'), ("Fix", ""))
        for value in ('[]', '{}', '{"pull_request":{"title":123}}',
                      '{"pull_request":{"title":"Fix","body":[]}}'):
            with self.assertRaises(ValueError):
                event_text(value)

    def invoke(self, value, *, event=True, title=""):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "input"
            path.write_bytes(value)
            output = io.StringIO()
            args = ["--event" if event else "--body-file", str(path)]
            if title:
                args.extend(["--title", title])
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                code = main(args)
            return code, output.getvalue()

    def test_failure_output_never_echoes_private_text(self):
        private = "MailShelf run 98765432109"
        token = "gh" + "p_" + "q" * 36
        payload = json.dumps({"pull_request": {"title": private, "body": token}}).encode()
        code, output = self.invoke(payload)
        self.assertEqual(code, 1)
        self.assertIn("private-run-reference", output)
        self.assertNotIn(private, output)
        self.assertNotIn(token, output)

    def test_malformed_and_oversized_events_fail_without_echoing(self):
        for value in (b'{"private payload"', b'\xff', b'x' * (MAX_INPUT_BYTES + 1)):
            code, output = self.invoke(value)
            self.assertEqual(code, 2)
            self.assertNotIn("private payload", output)

    def test_local_body_file_preflight_and_event_use_same_rules(self):
        self.assertEqual(self.invoke(b"Verified compatibility facts.", event=False, title="Fix")[0], 0)
        self.assertEqual(self.invoke(b"MailShelf run 12345", event=False)[0], 1)
        self.assertEqual(self.invoke(b"Fix", event=False, title="MailShelf run 12345")[0], 1)


if __name__ == "__main__":
    unittest.main()
