import io
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

    def test_case_names_from_subjects(self):
        self.assertEqual(check.case_of("Stress 03 base64-text-1m: 1 MiB base64 text"), "base64-text-1m")
        self.assertIsNone(check.case_of("Something else"))
        self.assertIsNone(check.case_of(None))


if __name__ == "__main__":
    unittest.main()
