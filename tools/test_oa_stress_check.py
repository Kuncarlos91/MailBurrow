import io
import email
from email.message import EmailMessage
from email.policy import SMTP
from unittest.mock import patch
import json
import unittest

import generate_stress_mail as stress
import oa_stress_check as check

SOURCE = "stress-source-1"
_BUILT = {}


def built(number, case, label, fill):
    if case not in _BUILT:
        _BUILT[case] = stress.build(number, case, label, fill)
    return _BUILT[case]


def detail(raw):
    return json.dumps({"id": "x", "raw": {"type": "Buffer", "data": list(raw)}}, separators=(",", ":")).encode()


class FakeServer:
    def __init__(self, change=None, omit=None):
        self.messages = {}
        for number, (case, label, fill) in enumerate(stress.CASES, start=1):
            if case == omit:
                continue
            raw = built(number, case, label, fill)
            if case == change:
                # A server that flattens the message to its first text part.
                raw = b"Subject: changed\r\nContent-Type: text/plain\r\n\r\nflattened"
            self.messages["m%02d" % number] = (f"Stress {number:02d} {case}: {label}", raw)
        self.requests = []

    def __call__(self, url, headers):
        self.requests.append(url)
        assert headers.get("X-API-KEY") == "reader-key"
        if "/archived-emails/ingestion-source/" + SOURCE in url:
            items = [{"id": mid, "subject": subject} for mid, (subject, _) in self.messages.items()]
            return 200, {"content-type": "application/json"}, json.dumps({"items": items, "total": len(items)}).encode()
        mid = url.rsplit("/", 1)[1]
        if mid in self.messages:
            return 200, {"content-type": "application/json"}, detail(self.messages[mid][1])
        return 404, {}, b"{}"


def run(server):
    out = io.StringIO()
    code = check.main(["https://lab.example:8443", "--source", SOURCE], key="reader-key", transport=server, out=out)
    return code, out.getvalue()


class StressCheckTest(unittest.TestCase):
    def test_all_cases_kept(self):
        code, text = run(FakeServer())
        self.assertEqual(code, 0, text)
        self.assertIn("RESULT: all 10 stress cases kept their structure", text)
        self.assertEqual(sum(1 for l in text.splitlines() if "  kept " in l), 10)
        self.assertNotIn("reader-key", text)
        self.assertNotIn("stress.example", text)

    def test_a_changed_case_is_not_tested(self):
        code, text = run(FakeServer(change="many-parts-400"))
        self.assertEqual(code, 1)
        line = next(l for l in text.splitlines() if l.startswith("many-parts-400"))
        self.assertIn("changed", line)
        self.assertIn("1 case(s) missing or changed", text)

    def test_a_missing_case_is_reported(self):
        code, text = run(FakeServer(omit="nested-30"))
        self.assertEqual(code, 1)
        self.assertIn("MISSING", next(l for l in text.splitlines() if l.startswith("nested-30")))

    def test_boundary_responses_fit_the_wire_limit(self):
        server = FakeServer()
        _, text = run(server)
        for case in ("near-limit", "over-limit"):
            line = next(l for l in text.splitlines() if l.startswith(case))
            self.assertIn("kept", line)

    def test_rejects_bad_input(self):
        out = io.StringIO()
        self.assertEqual(check.main(["http://lab.example", "--source", SOURCE], key="k", out=out), 2)
        self.assertEqual(check.main(["https://lab.example", "--source", "../x"], key="k", out=out), 2)

    def test_unknown_mime_values_are_never_printed(self):
        secret = "sentinel-private-value"
        raw = ("Content-Type: text/plain; charset=" + secret + "\r\n"
               "Content-Transfer-Encoding: " + secret + "\r\n\r\nshort").encode()
        def transport(url, headers):
            if "ingestion-source" in url:
                return 200, {}, json.dumps({"items": [{"id": "m1", "subject": "Stress 01 text-1m: case"}]}).encode()
            return 200, {}, detail(raw)
        code, text = run(transport)
        self.assertEqual(code, 1)
        self.assertNotIn(secret, text)
        self.assertIn("other", text)

    def test_legacy_charsets_in_skipped_parts_do_not_pass(self):
        msg = EmailMessage(policy=SMTP)
        msg.set_content("First selected UTF-8 body", charset="utf-8")
        for charset in ("iso-8859-1", "windows-1252"):
            msg.add_attachment("later".encode(), maintype="text", subtype="plain",
                               params={"charset": charset})
        facts = check.structure(msg.as_bytes())
        self.assertFalse(check.EXPECTED["legacy-charsets"][1](facts))

    def test_bodies_inside_an_ignored_rfc822_part_do_not_pass(self):
        inner = EmailMessage(policy=SMTP)
        inner.set_content("café", charset="iso-8859-1")
        inner.add_alternative("<p>€</p>", subtype="html", charset="windows-1252")
        outer = EmailMessage(policy=SMTP)
        outer.set_type("message/rfc822")
        outer.set_payload([inner])
        self.assertFalse(check.EXPECTED["legacy-charsets"][1](check.structure(outer.as_bytes())))

    def test_tiny_unreferenced_images_do_not_pass(self):
        msg = EmailMessage(policy=SMTP)
        msg.set_content("No image references")
        for i in range(6):
            msg.add_attachment(b"tiny", maintype="image", subtype="png",
                               disposition="inline", cid=f"<img-{i}>")
        self.assertFalse(check.EXPECTED["inline-images-6m"][1](check.structure(msg.as_bytes())))

    def test_structures_beyond_app_limits_are_invalid(self):
        for depth in (33, 60):
            msg = EmailMessage(policy=SMTP)
            msg.set_content("leaf")
            for i in range(depth):
                parent = EmailMessage(policy=SMTP)
                parent.make_mixed()
                parent.attach(msg)
                msg = parent
            self.assertFalse(check.structure(msg.as_bytes())["valid"])

    def test_bad_listing_does_not_count_as_success(self):
        for status, body in [(401, b"{}"), (200, b'{"items":[null]}')]:
            code, text = run(lambda url, headers: (status, {}, body))
            self.assertEqual(code, 1)
            self.assertIn("not tested", text)

    def test_rejects_unsafe_base_urls_before_contact(self):
        for url in ("https://user:pass@lab.example", "https://lab.example#fragment",
                    "https://lab.example?query=1", "https://lab.example:bad"):
            def transport(*args):
                self.fail("must not contact the server")
            self.assertEqual(check.main([url, "--source", SOURCE], key="k",
                                        transport=transport, out=io.StringIO()), 2)

    def test_invalid_raw_bytes_and_duplicate_cases_fail_safely(self):
        for duplicate in (False, True):
            requests = []
            def transport(url, headers):
                requests.append(url)
                if "ingestion-source" in url:
                    item = {"id": "m1", "subject": "Stress 01 text-1m: case"}
                    return 200, {}, json.dumps({"items": [item] * (2 if duplicate else 1)}).encode()
                return 200, {}, b'{"raw":{"type":"Buffer","data":[true]}}'
            code, text = run(transport)
            self.assertEqual(code, 1)
            self.assertIn("ERROR", text)
            if duplicate:
                self.assertEqual(len(requests), 1)

    def test_transport_caps_reads_and_rejects_oversize(self):
        class Response:
            code = 200
            headers = {}
            def __init__(self, oversized):
                self.oversized = oversized
                self.read_size = None
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                self.read_size = size
                return b"x" * (size if self.oversized else 1)
        class Opener:
            def __init__(self, response):
                self.response = response
            def open(self, request, timeout):
                self.method = request.get_method()
                return self.response
        for oversized in (False, True):
            response = Response(oversized)
            opener = Opener(response)
            with patch.object(check, "MIB", 16), patch.object(check, "WIRE_LIMIT", 100), \
                 patch.object(check.urllib.request, "build_opener", return_value=opener):
                if oversized:
                    with self.assertRaises(ValueError):
                        check.bounded_transport("https://lab.example", {})
                else:
                    self.assertEqual(check.bounded_transport("https://lab.example", {})[2], b"x")
            self.assertEqual(response.read_size, 117)
            self.assertEqual(opener.method, "GET")

    def test_deep_json_fails_without_a_traceback_or_server_text(self):
        body = b'{"items":' + b'[' * 1200 + b'0' + b']' * 1200 + b'}'
        code, text = run(lambda url, headers: (200, {}, body))
        self.assertEqual(code, 1)
        self.assertIn("not tested", text)

    def test_case_names_from_subjects(self):
        self.assertEqual(check.case_of("Stress 03 base64-text-1m: 1 MiB base64 text"), "base64-text-1m")
        self.assertIsNone(check.case_of("Something else"))
        self.assertIsNone(check.case_of(None))


if __name__ == "__main__":
    unittest.main()
