import io
import json
import tempfile
import unittest
import urllib.parse
from email import message_from_bytes
from pathlib import Path

import bichon_write_denial as wd

ALEX, BAKERY = 5415058806286270, 1323817549755429
ADMIN, READER = "admin-token", "reader-token"
PROBE = "probe-env-uuid"


class FakeBichon:
    """Bichon stand-in: admin may write; the reader is refused unless a flaw is switched on."""

    def __init__(self, probes=1, reader_can=(), admin_tags_work=True, admin_delete_works=True, omit_empty_tags=False,
                 remove_failures=0):
        self.envs = {"env-%d" % i: {"id": "env-%d" % i, "account_id": ALEX, "subject": "Demo %d" % i,
                                    "from": "someone@example.com", "message_id": "<d%d@example.com>" % i,
                                    "tags": []} for i in range(3)}
        for n in range(probes):
            env = PROBE if n == 0 else "%s-%d" % (PROBE, n)
            self.envs[env] = {"id": env, "account_id": ALEX, "subject": wd.PROBE_SUBJECT, "from": wd.PROBE_SENDER,
                              "message_id": wd.PROBE_MESSAGE_ID.strip("<>"), "tags": ["/existing"]}
        self.reader_can, self.admin_tags_work, self.admin_delete_works = set(reader_can), admin_tags_work, admin_delete_works
        self.calls, self.omit_empty_tags, self.remove_failures = [], omit_empty_tags, remove_failures
        if omit_empty_tags:
            for e in self.envs.values():
                e["tags"] = []

    def __call__(self, method, url, headers, body):
        parts = urllib.parse.urlsplit(url)
        path = parts.path.replace("/api/v1", "", 1)
        role = {ADMIN: "admin", READER: "reader"}.get(headers.get("Authorization", "").removeprefix("Bearer "))
        self.calls.append((role, method, path))
        ok = lambda obj=None: (200, {}, json.dumps(obj if obj is not None else {}).encode())
        deny = (403, {}, b'{"message":"forbidden","code":403}')
        req = json.loads(body) if body else None
        allowed = role == "admin" or any(path.startswith("/" + w) for w in self.reader_can)
        if role is None:
            return 401, {}, b"{}"
        if path == "/update-tags" and not all(t.startswith("/") for t in req["tags"]):
            return 400, {}, b'{"message":"invalid facet","code":400}'  # before the permission check, as upstream
        if path == "/minimal-account-list":
            return ok([{"id": ALEX, "email": "alex.rivera@example.com"},
                       {"id": BAKERY, "email": "hello@maple-street-bakery.example"}])
        if path == "/search-messages":
            f = req["filter"]
            items = [e for e in self.envs.values() if e["account_id"] in f["account_ids"]
                     and f["subject"].lower() in e["subject"].lower()]
            return ok({"items": items, "total_items": len(items), "total_pages": 1})
        if path.startswith("/envelope/"):
            env = urllib.parse.unquote(path.rsplit("/", 1)[1])
            if env not in self.envs:
                return 404, {}, b"{}"
            e = dict(self.envs[env])
            if self.omit_empty_tags and not e["tags"]:
                del e["tags"]  # Bichon's Envelope schema does not require tags
            return ok(e)
        if not allowed:
            return deny
        if path == "/update-tags":
            if role == "admin" and not self.admin_tags_work:
                return 400, {}, b"{}"
            if req["action"] == "Remove" and self.remove_failures:
                self.remove_failures -= 1
                return 500, {}, b'{"message":"internal","code":500}'
            for env in req["updates"][str(ALEX)]:
                tags = self.envs[env]["tags"]
                if req["action"] == "Add":
                    tags.extend(t for t in req["tags"] if t not in tags)
                elif req["action"] == "Remove":
                    tags[:] = [t for t in tags if t not in req["tags"]]
            return ok()
        if path.startswith("/repair-message/"):
            return ok({"repaired": True})
        if path == "/delete-messages":
            if role == "admin" and not self.admin_delete_works:
                return 400, {}, b"{}"
            for env in req[str(ALEX)]:
                self.envs.pop(env, None)
            return ok()
        return 404, {}, b"{}"


def run(fake, argv=("https://lab.example:9443",), keys=(ADMIN, READER)):
    out = io.StringIO()
    from unittest.mock import patch
    with patch.object(wd.time, "sleep", lambda s: None):
        code = wd.main(list(argv), keys=keys, transport=fake, out=out)
    return code, out.getvalue()


class WriteDenialTests(unittest.TestCase):
    def test_secure_server_passes_and_probe_is_removed(self):
        fake = FakeBichon()
        code, out = run(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("RESULT: reader writes refused", out)
        self.assertNotIn(PROBE, fake.envs)
        self.assertEqual(len(fake.envs), 3)
        for role, method, path in fake.calls:
            self.assertIn((role, method, path.split("/")[1] and "/" + path.split("/")[1]),
                          wd.Prober.ALLOWED)

    def test_transient_remove_error_is_retried(self):
        fake = FakeBichon(remove_failures=1)
        code, out = run(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("[INFO] Admin tag removal", out)
        self.assertIn("status 200 after 2 attempt(s); control tag gone True", out)
        self.assertNotIn(PROBE, fake.envs)

    def test_persistent_remove_error_does_not_block_reader_checks(self):
        fake = FakeBichon(remove_failures=99)
        code, out = run(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("status 500 after 3 attempt(s); control tag gone False", out)
        for name in ("Reader tag change refused", "Reader repair refused", "Reader delete refused"):
            self.assertIn("[PASS] " + name, out)
        self.assertNotIn(PROBE, fake.envs)

    def test_invisible_admin_add_fails_shape_control(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            status, h, data = fake(method, url, headers, body)
            if "/envelope/" in url and status == 200:
                obj = json.loads(data)
                obj["tags"] = [t for t in obj.get("tags", []) if t != wd.SHAPE_TAG]
                data = json.dumps(obj).encode()
            return status, h, data
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Tag request is well formed", out)
        self.assertFalse([c for c in fake.calls if c[0] == "reader" and c[2] != "/envelope/%d/%s" % (ALEX, PROBE)
                          and not c[2].startswith("/envelope/")])
        self.assertNotIn(PROBE, fake.envs)

    def test_control_tags_are_facet_paths(self):
        self.assertTrue(wd.SHAPE_TAG.startswith("/") and wd.READER_TAG.startswith("/"))

    def test_untagged_probe_without_tags_field_passes(self):
        fake = FakeBichon(omit_empty_tags=True)
        code, out = run(fake)
        self.assertEqual(code, 0, out)
        self.assertNotIn(PROBE, fake.envs)

    def test_null_tags_normalize_like_missing_tags(self):
        fake = FakeBichon(omit_empty_tags=True)
        def transport(method, url, headers, body):
            status, response_headers, data = fake(method, url, headers, body)
            if "/envelope/" in url and status == 200:
                obj = json.loads(data)
                if "tags" not in obj:
                    obj["tags"] = None
                data = json.dumps(obj).encode()
            return status, response_headers, data
        code, out = run(transport)
        self.assertEqual(code, 0, out)
        self.assertNotIn(PROBE, fake.envs)

    def test_invalid_tag_shapes_fail_before_writes_without_values(self):
        for tags in ("private-tag-value", {"private-tag-value": True}, ["ok", 42]):
            fake = FakeBichon()
            def transport(method, url, headers, body):
                status, response_headers, data = fake(method, url, headers, body)
                if "/envelope/" in url and status == 200:
                    obj = json.loads(data)
                    obj["tags"] = tags
                    data = json.dumps(obj).encode()
                return status, response_headers, data
            code, out = run(transport)
            self.assertEqual(code, 1)
            self.assertIn("unexpected fields tags", out)
            self.assertNotIn("private-tag-value", out)
            self.assertIn(PROBE, fake.envs)
            self.assertFalse(any(c[2] == "/update-tags" for c in fake.calls))

    def test_post_write_validation_failure_still_attempts_cleanup(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            status, response_headers, data = fake(method, url, headers, body)
            if "/envelope/" in url and status == 200 and any(c[2] == "/update-tags" for c in fake.calls):
                obj = json.loads(data)
                obj["tags"] = "invalid-private-value"
                data = json.dumps(obj).encode()
            return status, response_headers, data
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertNotIn("invalid-private-value", out)
        self.assertNotIn(PROBE, fake.envs)
        self.assertTrue(any(c[0] == "admin" and c[2] == "/delete-messages" for c in fake.calls))

    def test_envelope_mismatch_names_only_the_field(self):
        fake = FakeBichon()
        real = fake.__call__
        def wrong_sender(method, url, headers, body):
            status, h, data = real(method, url, headers, body)
            if "/envelope/" in url and status == 200:
                obj = json.loads(data)
                obj["from"] = "someone-else@example.com"
                data = json.dumps(obj).encode()
            return status, h, data
        code, out = run(wrong_sender)
        self.assertEqual(code, 1)
        self.assertIn("unexpected fields from", out)
        self.assertNotIn("someone-else", out)
        self.assertFalse([c for c in fake.calls if c[2] == "/update-tags" or c[2].startswith("/repair-message")])

    def test_summary_holds_no_secrets_or_identifiers(self):
        code, out = run(FakeBichon())
        for secret in (ADMIN, READER, PROBE, str(ALEX), "alex.rivera", wd.PROBE_SENDER, "forbidden"):
            self.assertNotIn(secret, out)

    def test_reader_tag_write_fails_and_is_reverted(self):
        fake = FakeBichon(reader_can={"update-tags"})
        code, out = run(fake)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Reader tag change refused", out)
        self.assertNotIn(wd.READER_TAG, fake.envs.get(PROBE, {"tags": []})["tags"])

    def test_reader_repair_fails(self):
        code, out = run(FakeBichon(reader_can={"repair-message"}))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Reader repair refused", out)

    def test_reader_delete_fails(self):
        code, out = run(FakeBichon(reader_can={"delete-messages"}))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Reader delete refused", out)

    def test_unproven_tag_shape_cannot_pass(self):
        code, out = run(FakeBichon(admin_tags_work=False))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Tag request is well formed", out)

    def test_failed_cleanup_fails(self):
        code, out = run(FakeBichon(admin_delete_works=False))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Delete request is well formed", out)

    def test_no_probe_or_two_probes_stop_before_any_write(self):
        for probes in (0, 2):
            fake = FakeBichon(probes=probes)
            code, out = run(fake)
            self.assertEqual(code, 1)
            self.assertIn("NOT PROVEN", out)
            self.assertFalse([c for c in fake.calls if c[2] in ("/update-tags", "/delete-messages")
                              or c[2].startswith("/repair-message")])

    def test_rejects_bad_urls_and_equal_tokens(self):
        for url in ("http://lab.example", "https://lab.example/api", "https://u:p@lab.example",
                    "https://lab.example?x=1", "https://lab.example:99999"):
            self.assertEqual(run(FakeBichon(), argv=(url,))[0], 2, url)
        self.assertEqual(run(FakeBichon(), keys=(ADMIN, ADMIN))[0], 2)

    def test_refuses_unlisted_requests(self):
        p = wd.Prober("https://lab.example", FakeBichon(), {"admin": ADMIN, "reader": READER})
        with self.assertRaises(ValueError):
            p.send("reader", "GET", "/accounts")
        with self.assertRaises(ValueError):
            p.send("reader", "POST", "/restore-messages")

    def test_invalid_reader_token_cannot_prove_permission_denial(self):
        fake = FakeBichon()
        code, out = run(fake, keys=(ADMIN, "invalid-reader"))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Reader token can read", out)
        self.assertFalse(any(c[2] in ("/update-tags", "/delete-messages") for c in fake.calls))

    def test_partial_probe_identity_is_not_selected(self):
        for field, value in (("from", "prefix-" + wd.PROBE_SENDER),
                             ("message_id", "mailburrow-write-denial-probe@other.example")):
            fake = FakeBichon()
            fake.envs[PROBE][field] = value
            code, out = run(fake)
            self.assertEqual(code, 1)
            self.assertFalse(any(c[2] in ("/update-tags", "/delete-messages") for c in fake.calls))

    def test_truncated_search_cannot_prove_unique_probe(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            status, response_headers, data = fake(method, url, headers, body)
            if url.endswith("/search-messages"):
                obj = json.loads(data)
                obj["total_items"] = 11
                return status, response_headers, json.dumps(obj).encode()
            return status, response_headers, data
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertFalse(any(c[2] in ("/update-tags", "/delete-messages") for c in fake.calls))

    def test_failed_search_after_cleanup_is_not_absence(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            if PROBE not in fake.envs and url.endswith("/search-messages"):
                return 500, {}, b"{}"
            return fake(method, url, headers, body)
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Delete request is well formed", out)

    def test_repair_requires_successful_admin_control(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            if "/repair-message/" in url and headers["Authorization"] == "Bearer " + ADMIN:
                return 400, {}, b"{}"
            return fake(method, url, headers, body)
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Repair request is well formed", out)
        self.assertNotIn(PROBE, fake.envs)
        self.assertFalse(any(c[0] == "reader" and c[1] == "POST" for c in fake.calls))

    def test_403_with_changed_metadata_fails_and_cleans_up(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            if url.endswith("/update-tags") and headers["Authorization"] == "Bearer " + READER:
                fake.envs[PROBE]["preview"] = "changed"
                return 403, {}, b"{}"
            return fake(method, url, headers, body)
        code, out = run(transport)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] Reader tag change refused", out)
        self.assertNotIn(PROBE, fake.envs)

    def test_probe_eml_is_fictional(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "probe.eml"
            code, _ = run(FakeBichon(), argv=("--write-probe-eml", str(path)))
            self.assertEqual(code, 0)
            msg = message_from_bytes(path.read_bytes())
        self.assertEqual(msg["Subject"], wd.PROBE_SUBJECT)
        for header in ("From", "To", "Message-ID"):
            self.assertRegex(msg[header], r"@([a-z.-]+\.example|example\.com)>?$")


if __name__ == "__main__":
    unittest.main()
