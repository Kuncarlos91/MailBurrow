import io
import json
import unittest
import urllib.parse
from pathlib import Path

import bichon_lab_check as lab

ROOT = Path(__file__).resolve().parents[1]
ALEX, BAKERY = 5415058806286270, 1323817549755429
TOKENS = {"admin": "admin-token", "reader": "reader-token", "revoked": "revoked-token", "expired": "expired-token"}


def demo():
    data = json.loads((ROOT / "assets/demo/archive.json").read_text(encoding="utf-8"))
    ids = {1: ALEX, 2: BAKERY}
    messages = []
    for i, m in enumerate(data["messages"]):
        if m["accountId"] not in ids:
            continue
        atts = [{"file_type": "application/pdf", "inline": False, "filename": "f%d.pdf" % n, "size": 100 + n,
                 "content_hash": "h%d-%d" % (i, n), "is_message": False, "extracted_is_ocr": False}
                for n in range(len(m.get("attachments") or []))]
        messages.append({"id": "env-%03d" % i, "account_id": ids[m["accountId"]], "subject": m["subject"],
                         "text": (m.get("textBody") or "") + " " + json.dumps(m), "attachments": atts,
                         "attachment_count": len(atts), "tags": []})
    return messages


class FakeBichon:
    """A minimal Bichon 2.4.1 stand-in with account-scoped read-only enforcement."""

    def __init__(self, leak=False, allow_raw=False, allow_tags=False, five_hundred_on_odd=False):
        self.messages = demo()
        self.leak, self.allow_raw, self.allow_tags = leak, allow_raw, allow_tags
        self.five_hundred_on_odd = five_hundred_on_odd
        self.methods = []

    def visible(self, role):
        return {ALEX, BAKERY} if role == "admin" or self.leak else {ALEX}

    def __call__(self, method, url, headers, body):
        self.methods.append((method, urllib.parse.urlsplit(url).path))
        parts = urllib.parse.urlsplit(url)
        path, query = parts.path.replace("/api/v1", "", 1), dict(urllib.parse.parse_qsl(parts.query))
        token = headers.get("Authorization", "").removeprefix("Bearer ")
        role = {v: k for k, v in TOKENS.items()}.get(token)
        if role not in ("admin", "reader"):
            return 401, {}, b'{"message":"unauthorized","code":401}'
        ok = lambda obj: (200, {"content-type": "application/json"}, json.dumps(obj).encode())
        deny = (403, {}, b'{"message":"forbidden","code":403}')
        seen = self.visible(role)
        if path == "/current-user":
            if role == "admin":
                return ok({"global_permissions": ["system:root"], "account_permissions": {}})
            return ok({"global_permissions": ["system:access"],
                       "account_permissions": {str(ALEX): ["data:read", "account:read_details"]}, "password": None})
        if path == "/minimal-account-list":
            accs = [{"id": ALEX, "email": "alex.rivera@example.com", "account_type": "NoSync"},
                    {"id": BAKERY, "email": "hello@maple-street-bakery.example", "account_type": "NoSync"}]
            return ok([a for a in accs if a["id"] in seen])
        if path == "/accounts":
            return ok({"items": [{"id": a} for a in seen], "total_items": len(seen)})
        if path.startswith("/list-mailboxes/"):
            acc = int(path.rsplit("/", 1)[1])
            return ok({"mailboxes": [{"id": 1, "name": "INBOX"}], "status": "ready"}) if acc in seen else deny
        if path == "/search-messages":
            req = json.loads(body)
            f = req["filter"]
            text = f.get("text", "")
            if self.five_hundred_on_odd and text.startswith('"'):
                return 500, {}, b"boom"
            pool = [m for m in self.messages if m["account_id"] in seen]
            if f.get("account_ids"):
                if any(a not in seen for a in f["account_ids"]):
                    return deny
                pool = [m for m in pool if m["account_id"] in f["account_ids"]]
            if text:
                pool = [m for m in pool if text.lower() in m["text"].lower()]
            if f.get("has_attachment"):
                pool = [m for m in pool if m["attachment_count"]]
            start = (req["page"] - 1) * req["page_size"]
            page = pool[start:start + req["page_size"]]
            return ok({"items": [{k: m[k] for k in ("id", "account_id", "subject", "attachment_count", "tags")}
                                 for m in page], "total_items": len(pool)})
        if path == "/update-tags":
            if role == "reader" and not self.allow_tags:
                return deny
            req = json.loads(body)
            for acc, envs in req["updates"].items():
                for m in self.messages:
                    if m["id"] in envs:
                        m["tags"] = (m["tags"] + req["tags"]) if req["action"] == "Add" else [
                            t for t in m["tags"] if t not in req["tags"]]
            return ok({})
        segs = path.strip("/").split("/")
        if len(segs) >= 3:
            kind, acc, env = segs[0], int(segs[1]), urllib.parse.unquote(segs[2])
            if acc not in seen:
                return deny
            msg = next((m for m in self.messages if m["id"] == env and m["account_id"] == acc), None)
            if msg is None:
                return 404, {}, b'{"message":"not found","code":404}'
            if kind == "message-content":
                return ok({"text": "body", "html": "<p>body</p>", "attachments": msg["attachments"],
                           "has_remote_content": False})
            if kind == "envelope":
                return ok({"id": msg["id"], "tags": msg["tags"]})
            if kind == "download-message":
                return (200, {}, b"raw") if self.allow_raw else deny
            if kind == "download-attachment":
                a = next((a for a in msg["attachments"] if a["content_hash"] == query.get("content_hash")), None)
                return (200, {}, b"x" * a["size"]) if a else (404, {}, b"{}")
        return 404, {}, b"{}"


def run(server, extra=(), keys=None):
    out = io.StringIO()
    code = lab.main(["https://lab.example:9443", *extra], keys=keys or (
        TOKENS["admin"], TOKENS["reader"], TOKENS["revoked"], TOKENS["expired"]), transport=server, out=out)
    return code, out.getvalue()


def line(text, name):
    return next(l for l in text.splitlines() if name in l)


class BichonLabCheckTest(unittest.TestCase):
    def test_expected_constants_match_demo_mail(self):
        msgs = demo()
        self.assertEqual(sum(m["account_id"] == ALEX for m in msgs), lab.EXPECT["reader_total"])
        self.assertEqual(sum(m["account_id"] == BAKERY for m in msgs), lab.EXPECT["other_total"])
        own = [m for m in msgs if lab.EXPECT["own_term"] in m["text"].lower()]
        self.assertEqual([m["account_id"] for m in own], [ALEX])
        other = [m for m in msgs if lab.EXPECT["other_term"] in m["text"].lower()]
        self.assertTrue(other and all(m["account_id"] == BAKERY for m in other))

    def test_correct_server_passes_without_leaking(self):
        server = FakeBichon()
        code, text = run(server)
        self.assertEqual(code, 0, text)
        self.assertIn("RESULT: all required checks passed", text)
        for secret in TOKENS.values():
            self.assertNotIn(secret, text)
        for private in ("example.com", "Harbor", "maple-street", "forbidden"):
            self.assertNotIn(private, text)
        self.assertEqual({m for m, _ in server.methods}, {"GET", "POST"})
        posts = {p for m, p in server.methods if m == "POST"}
        self.assertEqual(posts, {"/api/v1/search-messages"})

    def test_without_write_denial_only_search_is_posted(self):
        server = FakeBichon()
        code, text = run(server)
        self.assertEqual(code, 0, text)
        self.assertEqual({p for m, p in server.methods if m == "POST"}, {"/api/v1/search-messages"})
        self.assertIn("[SKIP] (optional) Write-denial enforcement", text)

    def test_cross_account_leak_fails(self):
        code, text = run(FakeBichon(leak=True))
        self.assertEqual(code, 1)
        self.assertTrue(line(text, "Reader minimal account list shows only Alex").startswith("[FAIL]"))
        self.assertTrue(line(text, "Reader refused a Bakery message").startswith("[FAIL]"))

    def test_raw_download_allowed_fails(self):
        code, text = run(FakeBichon(allow_raw=True))
        self.assertEqual(code, 1)
        self.assertTrue(line(text, "Reader refused raw EML download").startswith("[FAIL]"))

    def test_mutation_path_rejected_even_with_reader_or_admin(self):
        server = FakeBichon(allow_tags=True)
        l = lab.Lab("https://lab.example", "/api/v1", server)
        for role in ("admin", "reader"):
            with self.assertRaises(ValueError):
                l.request("POST", "/update-tags", TOKENS[role], payload={})
        self.assertEqual(server.methods, [])

    def test_server_error_on_odd_search_is_reported(self):
        code, text = run(FakeBichon(five_hundred_on_odd=True))
        self.assertTrue(line(text, "Unusual search text handled (11 chars)").startswith("[FAIL] (optional)"))

    def test_reused_tokens_are_refused_before_requests(self):
        def transport(*args):
            self.fail("no request expected")
        a, b, c = "tok-AAAA1111", "tok-BBBB2222", "tok-CCCC3333"
        for keys in ((a, a), (a, b, a), (a, b, c, c), (a, b, "", b)):
            code, text = run(transport, keys=keys)
            self.assertEqual(code, 2)
            self.assertIn("must be different", text)
            for key in (a, b, c):
                self.assertNotIn(key, text)

    def test_rejects_non_https_or_paths(self):
        for url in ("http://lab.example", "https://lab.example/api", "https://lab.example?x=1"):
            out = io.StringIO()
            self.assertEqual(lab.main([url], keys=("a", "b"), transport=lambda *a: self.fail(), out=out), 2)

    def test_hostile_server_values_are_not_reported(self):
        server = FakeBichon()
        marker = "private-server-value-DO-NOT-PRINT"
        def transport(method, url, headers, body):
            status, response_headers, data = server(method, url, headers, body)
            path = urllib.parse.urlsplit(url).path
            if path.endswith("/search-messages"):
                obj = json.loads(data)
                if "items" in obj:
                    obj["total_items"] = marker
                    data = json.dumps(obj).encode()
            return status, response_headers, data
        code, text = run(transport)
        self.assertEqual(code, 1)
        self.assertNotIn(marker, text)
        self.assertNotIn("private:secret", lab.perms(["private:secret", "data:read"]))

    def test_malformed_items_cannot_prove_empty_refusal(self):
        r = lab.Response(200, {}, b'{"items":["invalid"]}')
        self.assertIsNone(lab.items_of(r))
        self.assertFalse(lab.refused_or_empty(r))

    def test_empty_mailbox_object_is_not_authorization_evidence(self):
        server = FakeBichon()
        def transport(method, url, headers, body):
            if url.endswith("/list-mailboxes/%d" % BAKERY):
                return 200, {}, b"{}"
            return server(method, url, headers, body)
        code, text = run(transport)
        self.assertEqual(code, 1)
        self.assertTrue(line(text, "Reader refused Bakery mailboxes").startswith("[FAIL]"))

    def test_existing_foreign_attachment_leak_fails(self):
        server = FakeBichon()
        def transport(method, url, headers, body):
            if "/download-attachment/%d/" % BAKERY in url:
                headers = {**headers, "Authorization": "Bearer " + TOKENS["admin"]}
            return server(method, url, headers, body)
        code, text = run(transport)
        self.assertEqual(code, 1)
        self.assertTrue(line(text, "Reader refused a Bakery attachment download").startswith("[FAIL]"))

    def test_host_budget_rejects_overflow_instead_of_truncating(self):
        from unittest.mock import patch
        with patch.object(lab, "MAX_BODY", 4):
            self.assertEqual(lab.read_bounded(io.BytesIO(b"1234")), b"1234")
            with self.assertRaises(ValueError):
                lab.read_bounded(io.BytesIO(b"12345"))

    def test_bad_urls_and_prefix_make_no_requests(self):
        for args in (["https://user:pass@lab.example"], ["https://lab.example#fragment"],
                     ["https://lab.example:99999"], ["https://lab.example:bad"],
                     ["https://lab.example", "--api-prefix", "/../other"]):
            out = io.StringIO()
            self.assertEqual(lab.main(args, keys=("a", "b"),
                            transport=lambda *a: self.fail("no request expected"), out=out), 2)

    def test_only_allowlisted_posts(self):
        l = lab.Lab("https://lab.example", "/api/v1", lambda *a: (200, {}, b"{}"))
        with self.assertRaises(ValueError):
            l.request("POST", "/delete-messages", "t", payload={})
        with self.assertRaises(ValueError):
            lab.urllib_transport("DELETE", "https://lab.example", {}, None)


if __name__ == "__main__":
    unittest.main()
