"""Regression tests for tools/oa_lab_check.py against an in-process fake server.

The fake server is built from the demo fixtures (assets/demo/archive.json) and
behaves like Open Archiver v0.6.2 for the routes the checker uses. Each test
injects one fault and asserts the checker reports it: missing fixtures,
empty or malformed responses, inline payloads, leaking search results or
totals, and server text that must never reach the summary.
"""
import io
import json
import re
import unittest
import urllib.parse
from datetime import datetime
from email.message import EmailMessage

import oa_lab_check as lab
from export_demo_eml import DEMO

A, B, C, P = ("aaaaaaaa-0000-4000-8000-00000000000%d" % i for i in (1, 2, 3, 4))
ACCOUNT_SOURCE = {1: A, 2: B, 3: C}
SECRET = "sentinel-secret-host.internal/private/path?token=sk_live_SENTINEL"


def load_fixtures():
    archive = json.loads((DEMO / "archive.json").read_text(encoding="utf-8"))
    files = archive["attachmentFiles"]
    emails = {}
    for m in archive["messages"]:
        date = m["sentDate"] or m["receivedDate"]
        ts = int(datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp() * 1000) if date else None
        atts = []
        for a in m.get("attachments") or []:
            data = (DEMO / "attachments" / files[str(a["id"])]).read_bytes()
            atts.append({"id": "att-%d" % a["id"], "filename": a["fileName"], "mimeType": a["contentType"],
                         "sizeBytes": len(data), "storagePath": "%s/att-%d" % (ACCOUNT_SOURCE[m["accountId"]], a["id"]),
                         "_data": data,
                         "_text": re.sub(r"<[^>]+>", " ", data.decode("utf-8", "replace"))
                         if a["contentType"].startswith("text/") else ""})
        emails["e-%d" % m["id"]] = {
            "id": "e-%d" % m["id"], "ingestionSourceId": ACCOUNT_SOURCE[m["accountId"]],
            "subject": m["subject"], "hasAttachments": bool(atts), "timestamp": ts,
            "body": m.get("textBody") or "", "html": re.sub(r"<[^>]+>", " ", m.get("htmlBody") or ""),
            "attachments": atts,
        }
    return emails


FIXTURES = load_fixtures()


def searchable(e):
    """What Open Archiver indexes: subject, body text and extracted attachment text."""
    return " ".join([str(e["subject"]), e["body"], e["html"]] + [a["_text"] for a in e["attachments"]]).lower()


def stripped_eml(e, inline=False, full=False):
    msg = EmailMessage()
    msg["Subject"] = e["subject"] or ""
    msg.set_content(e["body"])
    if inline:
        msg.add_alternative('<p>hi <img src="cid:logo"></p>', subtype="html")
        msg.get_payload()[1].add_related(b"\x89PNG" + b"0" * 60, "image", "png", cid="<logo>")
    if full:
        for a in e["attachments"]:
            msg.add_attachment(a["_data"], maintype="application", subtype="octet-stream", filename=a["filename"])
    return msg.as_bytes()


class FakeOpenArchiver:
    """Enough of Open Archiver's read API, with switchable faults."""

    def __init__(self, **faults):
        self.f = faults
        self.emails = dict(FIXTURES)
        self.sources = [A, B, C] + ([P] if faults.get("preserve") else [])
        if faults.get("preserve"):
            for e in list(FIXTURES.values()):
                if e["ingestionSourceId"] == C:
                    copy = dict(e, id="p" + e["id"], ingestionSourceId=P, attachments=[])
                    copy["_full"] = e
                    self.emails[copy["id"]] = copy
        if faults.get("b_no_attachments"):
            for k, e in list(self.emails.items()):
                if e["ingestionSourceId"] == B:
                    self.emails[k] = dict(e, hasAttachments=False, attachments=[])
        self.calls = 0
        self.reader_listings = 0

    def allowed(self, who):
        return set(self.sources) if who == "admin" else {A}

    def __call__(self, url, headers):
        self.calls += 1
        if self.f.get("down"):
            raise OSError("connection refused to " + SECRET)
        u = urllib.parse.urlparse(url)
        q = dict(urllib.parse.parse_qsl(u.query))
        path = u.path[len("/api/v1"):]
        key = headers.get("X-API-KEY")
        who = {"admin-key": "admin", "reader-key": "reader"}.get(key)
        if self.f.get("error_text"):
            return 500, {"content-type": "text/html", "x-debug": SECRET}, ("<h1>%s</h1>" % SECRET).encode()
        if not who:
            return self.json(401, {"message": "Unauthorized: " + SECRET})
        if path == "/ingestion-sources" and who == "reader":
            self.reader_listings += 1
        if self.f.get("rate_limit") and path == "/ingestion-sources" and who == "reader" and self.reader_listings > 99:
            return 429, {"retry-after": "47", "ratelimit-limit": "100"}, b'{"message":"Too many"}'
        allowed = self.allowed(who)
        if path == "/ingestion-sources":
            return self.json(200, [{"id": s, "name": "src", "preserveOriginalFile": s == P}
                                   for s in self.sources if s in allowed])
        if path.startswith("/archived-emails/ingestion-source/"):
            src = path.rsplit("/", 1)[1]
            rows = sorted((e for e in self.emails.values() if e["ingestionSourceId"] == src and src in allowed),
                          key=lambda e: -(e["timestamp"] or 0))
            page, limit = int(q.get("page", 1)), int(q.get("limit", 10))
            items = [self.public(e) for e in rows[(page - 1) * limit: page * limit]]
            return self.json(200, {"items": items, "total": len(rows), "page": page, "limit": limit})
        if path.startswith("/archived-emails/"):
            e = self.emails.get(path.rsplit("/", 1)[1])
            if not e or e["ingestionSourceId"] not in allowed:
                return self.json(404, {"message": "Not found " + SECRET})
            raw = stripped_eml(e.get("_full", e), inline=self.f.get("inline"), full="_full" in e)
            body = dict(self.public(e), raw={"type": "Buffer", "data": list(raw)},
                        attachments=[{k: v for k, v in a.items() if not k.startswith("_")} for a in e["attachments"]])
            return self.json(200, body)
        if path == "/storage/download":
            for e in self.emails.values():
                for a in e["attachments"]:
                    if a["storagePath"] == q.get("path") and e["ingestionSourceId"] in allowed:
                        return 200, {"content-type": a["mimeType"], "content-disposition": "attachment"}, a["_data"]
            return self.json(404, {"message": "File not found"})
        if path == "/search":
            return self.search(q, allowed)
        if path == "/dashboard/stats":
            return self.json(200 if who == "admin" else 403, {"message": "Forbidden"})
        return self.json(404, {"message": "Not found"})

    def search(self, q, allowed):
        if self.f.get("malformed_search"):
            return 200, {"content-type": "application/json"}, b"{not json"
        if self.f.get("empty_search"):
            return self.json(200, {})
        if self.f.get("search_finds_nothing"):
            return self.json(200, {"hits": [], "total": 0, "page": 1, "limit": 10})
        visible = allowed | ({B} if self.f.get("leak_search") else set())
        rows = [e for e in self.emails.values() if e["ingestionSourceId"] in visible]
        if q.get("sources"):
            rows = [e for e in rows if e["ingestionSourceId"] in q["sources"].split(",")]
        if q.get("hasAttachments") == "true":
            rows = [e for e in rows if e["hasAttachments"]]
        for bound, cmp in (("dateFrom", lambda t, d: t >= d), ("dateTo", lambda t, d: t < d + 86400000)):
            if q.get(bound):
                d = int(datetime.fromisoformat(q[bound] + "T00:00:00+00:00").timestamp() * 1000)
                rows = [e for e in rows if e["timestamp"] is not None and cmp(e["timestamp"], d)]
        kw = (q.get("keywords") or "").lower()
        if kw:
            if q.get("searchIn") == "attachment_content":
                rows = [e for e in rows if any(kw in a["_text"].lower() for a in e["attachments"])]
            else:
                rows = [e for e in rows if re.search(r"\b%s\b" % re.escape(kw), searchable(e))]
        rows.sort(key=lambda e: -(e["timestamp"] or 0))
        page, limit = int(q.get("page", 1)), int(q.get("limit", 10))
        total = len(rows)
        if self.f.get("leak_total") and q.get("sources") == B:
            total = 20
        hits = [dict(self.public(e), body=e["body"], timestamp=e["timestamp"],
                     attachments=[{"filename": a["filename"], "content": a["_text"]} for a in e["attachments"]])
                for e in rows[(page - 1) * limit: page * limit]]
        if self.f.get("leak_page2") and page == 2 and q.get("sources") == A:
            hits = [dict(h, ingestionSourceId=B) for h in hits]
        if self.f.get("duplicate_ids_page2") and page == 2 and q.get("sources") == A and hits:
            hits = [dict(h, id=hits[0]["id"]) for h in hits]
        if self.f.get("page2_total_mismatch") and page == 2 and q.get("sources") == A:
            total += 7
        return self.json(200, {"hits": hits, "total": total, "page": page, "limit": limit})

    @staticmethod
    def public(e):
        return {k: e[k] for k in ("id", "ingestionSourceId", "subject", "hasAttachments")}

    @staticmethod
    def json(status, obj):
        return status, {"content-type": "application/json; charset=utf-8", "ratelimit-limit": "100"}, \
            json.dumps(obj).encode()


def run(server, deleted="", extra=None):
    out = io.StringIO()
    code = lab.main(["https://lab.example:8443"] + (extra or []),
                    keys=("admin-key", "reader-key", deleted), transport=server, out=out)
    return code, out.getvalue()


def line(output, name):
    found = [l for l in output.splitlines() if name in l]
    assert found, "no line for %r in:\n%s" % (name, output)
    return found[0]


class ExpectationsMatchFixtures(unittest.TestCase):
    def test_expect_constants_are_derived_from_the_demo_archive(self):
        alex = [e for e in FIXTURES.values() if e["ingestionSourceId"] == A]
        self.assertEqual(len(alex), lab.EXPECT["reader_total"])

        def has(e, word):
            return re.search(r"\b%s\b" % word, searchable(e))
        own = [e for e in FIXTURES.values() if has(e, lab.EXPECT["own_term"])]
        self.assertEqual([e["subject"] for e in own], [lab.EXPECT["own_term_subject"]])
        other = [e for e in FIXTURES.values() if has(e, lab.EXPECT["other_term"])]
        self.assertTrue(other and all(e["ingestionSourceId"] == B for e in other))
        att = [e for e in FIXTURES.values()
               if any(lab.EXPECT["attachment_term"] in a["_text"].lower() for a in e["attachments"])]
        self.assertEqual([e["subject"] for e in att], [lab.EXPECT["attachment_term_subject"]])
        filtered = [e["subject"] for e in alex if e["hasAttachments"] and e["timestamp"]
                    and lab.year_of(e["timestamp"]) == 2026]
        self.assertEqual(sorted(filtered), sorted(lab.EXPECT["filter_subjects"]))


class CheckerTests(unittest.TestCase):
    def test_correct_server_passes_and_discloses_optional_skips(self):
        code, out = run(FakeOpenArchiver())
        self.assertEqual(code, 0, out)
        self.assertIn("RESULT: all required checks passed", out)
        self.assertIn("[SKIP] (optional) Deleted key refused", out)
        self.assertIn("[SKIP] (optional) Preserve-original source", out)
        self.assertIn("[SKIP] (optional) Rate limit answers 429", out)
        self.assertNotIn("[FAIL]", out)

    def test_optional_fixtures_run_when_present(self):
        code, out = run(FakeOpenArchiver(preserve=True, rate_limit=True), deleted="deleted-key",
                        extra=["--rate-limit"])
        self.assertEqual(code, 0, out)
        self.assertIn("[PASS] (optional) Preserve-original source keeps attachments inside raw", out)
        self.assertIn("[PASS] (optional) Rate limit answers 429", out)
        self.assertIn("[PASS] (optional) Deleted key refused on /search", out)

    def test_missing_required_fixture_is_skipped_and_fails_the_run(self):
        code, out = run(FakeOpenArchiver(b_no_attachments=True))
        self.assertEqual(code, 1)
        self.assertIn("[SKIP] Reader refused other source's attachment", out)
        self.assertIn("NOT PROVEN", out)

    def test_leaking_search_results_fail(self):
        code, out = run(FakeOpenArchiver(leak_search=True))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL]", line(out, "Reader search cannot find another source's term"))
        self.assertIn("[FAIL]", line(out, "Reader filter-search on other source returns nothing"))

    def test_leaking_total_with_empty_hits_fails(self):
        code, out = run(FakeOpenArchiver(leak_total=True))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL]", line(out, "Reader filter-search on other source returns nothing"))

    def test_empty_and_malformed_search_responses_fail(self):
        for fault in ("empty_search", "malformed_search"):
            code, out = run(FakeOpenArchiver(**{fault: True}))
            self.assertEqual(code, 1, fault)
            self.assertIn("[FAIL]", line(out, "Reader search finds a known own message"), fault)
            self.assertIn("[FAIL]", line(out, "Filter-only search returns exactly"), fault)
            self.assertIn("[FAIL]", line(out, "Attachment-text search finds the known attachment"), fault)

    def test_search_that_finds_nothing_is_not_counted_as_working(self):
        code, out = run(FakeOpenArchiver(search_finds_nothing=True))
        self.assertEqual(code, 1)
        for name in ("Reader search finds a known own message", "Attachment-text search finds the known attachment",
                     "Filter-only search returns exactly", "Search pages are distinct, own-source only"):
            self.assertIn("[FAIL]", line(out, name), name)
        # With no admin control hit, the isolation test cannot be proven either way.
        self.assertIn("[SKIP]", line(out, "Reader search cannot find another source's term"))

    def test_other_source_term_may_also_match_own_mail(self):
        # Regression: "sourdough" is in a bakery email and in the receipt attachment of
        # an Alex Rivera email. The reader's own hit is not a leak.
        original = lab.EXPECT["other_term"]
        lab.EXPECT["other_term"] = "sourdough"
        try:
            code, out = run(FakeOpenArchiver())
        finally:
            lab.EXPECT["other_term"] = original
        self.assertEqual(code, 0, out)
        self.assertIn("1 hits (0 from other sources)", line(out, "Reader search cannot find another source's term"))

    def test_second_search_page_faults_fail(self):
        # Review regression: only page 2 leaks another source (IDs and counts unchanged).
        for fault in ("leak_page2", "duplicate_ids_page2", "page2_total_mismatch"):
            code, out = run(FakeOpenArchiver(**{fault: True}))
            self.assertEqual(code, 1, fault)
            self.assertIn("[FAIL]", line(out, "Search pages are distinct, own-source only"), fault)

    def test_inline_payload_is_counted_separately(self):
        code, out = run(FakeOpenArchiver(inline=True))
        self.assertEqual(code, 0, out)
        self.assertIn("[PASS]", line(out, "raw has no attachment parts"))
        self.assertRegex(line(out, "Inline binary payload in raw"), r": 1 inline parts, \d+ bytes")

    def test_mime_payloads_classifies_inline_and_attachment_parts(self):
        msg = EmailMessage()
        msg.set_content("text")
        msg.add_alternative('<img src="cid:x">', subtype="html")
        msg.get_payload()[1].add_related(b"\x89PNG1234", "image", "png", cid="<x>")
        msg.add_attachment(b"%PDF-1", maintype="application", subtype="pdf", filename="a.pdf")
        counts = lab.mime_payloads(msg.as_bytes())
        self.assertEqual(counts["attachment"], [1, 6])
        self.assertEqual(counts["inline"], [1, 8])

    def test_server_text_never_reaches_the_summary(self):
        for fault in ("error_text", "down"):
            code, out = run(FakeOpenArchiver(**{fault: True}))
            self.assertEqual(code, 1, fault)
            self.assertNotIn("sentinel", out.lower(), fault)
            self.assertNotIn("SENTINEL", out, fault)
            self.assertNotIn("x-debug", out, fault)
        # Error bodies on a working server carry the sentinel too (401/404 messages).
        code, out = run(FakeOpenArchiver(), deleted="deleted-key")
        self.assertNotIn("sentinel", out.lower())
        self.assertNotIn("lab.example", out)
        self.assertNotIn("reader-key", out)
        self.assertNotIn("admin-key", out)

    def test_unknown_field_names_are_counted_not_printed(self):
        self.assertEqual(lab.names(["subject", "x-secret-field", SECRET]), "subject (+2 other)")

    def test_plain_http_is_refused(self):
        out = io.StringIO()
        self.assertEqual(lab.main(["http://lab.example"], keys=("a", "b", ""), transport=FakeOpenArchiver(),
                                  out=out), 2)


if __name__ == "__main__":
    unittest.main()
