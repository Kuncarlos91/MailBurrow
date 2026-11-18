import io
import json
import unittest
import urllib.parse

import bichon_fixture_cleanup as fc

ALEX, BAKERY, FOLDER_ID, INBOX_ID = 5415058806286270, 1323817549755429, 77, 11
ADMIN, READER = "admin-token", "reader-token"


def fixture_items():
    return [{"id": "fx-%d" % n, "account_id": ALEX, "mailbox_id": FOLDER_ID, "message_id": mid,
             "subject": subject, "from": fc.SENDER_ADDRESS}
            for n, (mid, subject) in enumerate(sorted(fc.expected().items()))]


class FakeBichon:
    def __init__(self, extra_in_folder=0, marked_outside=0, drop=None, folders=1, delete_status=200):
        self.demo = [{"id": "d-%d" % n, "account_id": ALEX, "mailbox_id": INBOX_ID, "message_id": "d%d@example.com" % n,
                      "subject": "Demo %d" % n, "from": "someone@example.com"} for n in range(40)]
        self.fixtures = fixture_items()
        if drop is not None:
            self.fixtures.pop(drop)
        self.demo += [{"id": "x-%d" % n, "account_id": ALEX, "mailbox_id": FOLDER_ID, "message_id": "x%d@example.com" % n,
                       "subject": "Unrelated %d" % n, "from": "someone@example.com"} for n in range(extra_in_folder)]
        self.demo += [{"id": "m-%d" % n, "account_id": ALEX, "mailbox_id": INBOX_ID, "message_id": "m%d@example.com" % n,
                       "subject": "%s: copy %d" % (fc.MARKER, n), "from": "someone@example.com"}
                      for n in range(marked_outside)]
        self.folders, self.delete_status = folders, delete_status
        self.calls, self.deleted = [], []

    def all(self):
        return self.demo + self.fixtures

    def __call__(self, method, url, headers, body):
        path = urllib.parse.urlsplit(url).path.replace("/api/v1", "", 1)
        role = {"Bearer " + ADMIN: "admin", "Bearer " + READER: "reader"}.get(headers.get("Authorization"))
        self.calls.append((role, method, path))
        payload = json.loads(body) if body else None
        if path == "/minimal-account-list":
            return 200, {}, json.dumps([{"id": ALEX, "email": "alex.rivera@example.com"},
                                        {"id": BAKERY, "email": "orders@bakery.example"}]).encode()
        if path == "/list-mailboxes/%d" % ALEX:
            boxes = [{"id": INBOX_ID, "name": "INBOX"}] + [{"id": FOLDER_ID + n, "name": fc.FOLDER}
                                                           for n in range(self.folders)]
            return 200, {}, json.dumps({"status": "ready", "mailboxes": boxes}).encode()
        if path == "/search-messages":
            f = payload["filter"]
            items = [i for i in self.all()
                     if ("account_ids" not in f or i["account_id"] in f["account_ids"])
                     and ("mailbox_ids" not in f or i["mailbox_id"] in f["mailbox_ids"])
                     and ("subject" not in f or f["subject"] in i["subject"])]
            page, size = payload["page"], payload["page_size"]
            return 200, {}, json.dumps({"items": items[(page - 1) * size:page * size],
                                        "total_items": len(items)}).encode()
        if path == "/delete-messages":
            if role != "admin":
                return 403, {}, b'{"code":403}'
            if self.delete_status != 200:
                return self.delete_status, {}, b"{}"
            ids = set(payload[str(ALEX)])
            self.deleted.append(sorted(ids))
            self.fixtures = [i for i in self.fixtures if i["id"] not in ids]
            self.demo = [i for i in self.demo if i["id"] not in ids]
            return 200, {}, b"{}"
        return 404, {}, b"{}"


def run(fake, delete=False, key=ADMIN):
    out = io.StringIO()
    argv = ["https://example.test:9443"] + (["--delete"] if delete else [])
    code = fc.main(argv, key=key, transport=fake, out=out, sleep=lambda _: None)
    return code, out.getvalue()


class CleanupTests(unittest.TestCase):
    def test_expected_set_is_the_generator(self):
        self.assertEqual(len(fc.expected()), 32)

    def test_dry_run_changes_nothing(self):
        fake = FakeBichon()
        code, out = run(fake)
        self.assertEqual(code, 0)
        self.assertIn("RESULT: ready to delete", out)
        self.assertFalse(any(m == "POST" and p == "/delete-messages" for _, m, p in fake.calls))

    def test_delete_removes_exactly_the_fixtures(self):
        fake = FakeBichon()
        code, out = run(fake, delete=True)
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.deleted, [sorted(i["id"] for i in fixture_items())])
        self.assertEqual(len(fake.demo), 40)
        self.assertIn("RESULT: fixtures removed", out)
        code, out = run(fake, delete=True)
        self.assertEqual(code, 0, out)
        self.assertIn("RESULT: nothing to remove", out)
        self.assertEqual(len(fake.deleted), 1)

    def test_refuses_when_anything_differs(self):
        cases = {"other mail in folder": FakeBichon(extra_in_folder=1),
                 "marked copy elsewhere": FakeBichon(marked_outside=1),
                 "one fixture missing": FakeBichon(drop=3),
                 "two fixture folders": FakeBichon(folders=2)}
        for name, fake in cases.items():
            with self.subTest(name):
                code, out = run(fake, delete=True)
                self.assertEqual(code, 1)
                self.assertIn("STOPPED", out)
                self.assertEqual(fake.deleted, [])

    def test_reader_delete_is_refused_and_reported(self):
        fake = FakeBichon()
        code, out = run(fake, delete=True, key=READER)
        self.assertEqual(code, 1)
        self.assertIn("Delete accepted (admin): status 403", out)
        self.assertEqual(len(fake.fixtures), 32)

    def test_summary_holds_no_token_or_address(self):
        code, out = run(FakeBichon(), delete=True)
        for secret in (ADMIN, "example.test", "alex.rivera@example.com", "fx-0"):
            self.assertNotIn(secret, out)

    def test_unexpected_baseline_stops_before_delete_and_noop_success(self):
        fake = FakeBichon()
        fake.demo.pop()
        code, out = run(fake, delete=True)
        self.assertEqual(code, 1)
        self.assertEqual(fake.deleted, [])
        fake.fixtures = []
        code, out = run(fake, delete=True)
        self.assertEqual(code, 1)
        self.assertNotIn("RESULT: nothing to remove", out)

    def test_duplicate_envelope_ids_are_refused(self):
        fake = FakeBichon()
        fake.fixtures[1]["id"] = fake.fixtures[0]["id"]
        code, _ = run(fake, delete=True)
        self.assertEqual(code, 1)
        self.assertEqual(fake.deleted, [])

    def test_cross_account_copy_cannot_hide_behind_same_envelope_id(self):
        fake = FakeBichon()
        fake.demo.append({**fake.fixtures[0], "account_id": BAKERY, "mailbox_id": INBOX_ID})
        code, _ = run(fake, delete=True)
        self.assertEqual(code, 1)
        self.assertEqual(fake.deleted, [])

    def test_inconsistent_pages_and_oversized_pages_are_refused(self):
        for defect in ("changed total", "repeated page", "oversized page", "wrong scope"):
            fake = FakeBichon()
            def transport(method, url, headers, body):
                status, response_headers, raw = fake(method, url, headers, body)
                if urllib.parse.urlsplit(url).path.endswith("/search-messages"):
                    payload, data = json.loads(body), json.loads(raw)
                    if defect == "changed total" and payload["page"] == 2:
                        data["total_items"] += 1
                    elif defect == "repeated page" and payload["page"] == 2:
                        data["items"] = fake.fixtures[:7]
                    elif defect == "oversized page" and payload["page"] == 1:
                        data["items"] += [fake.fixtures[-1]]
                    elif defect == "wrong scope" and data["items"]:
                        data["items"][0]["account_id"] = BAKERY
                    raw = json.dumps(data).encode()
                return status, response_headers, raw
            with self.subTest(defect=defect):
                code, _ = run(transport, delete=True)
                self.assertEqual(code, 1)
                self.assertEqual(fake.deleted, [])

    def test_mailbox_list_must_be_ready(self):
        fake = FakeBichon()
        def transport(method, url, headers, body):
            status, response_headers, raw = fake(method, url, headers, body)
            if "/list-mailboxes/" in url:
                data = json.loads(raw)
                data["status"] = "fetching"
                raw = json.dumps(data).encode()
            return status, response_headers, raw
        code, _ = run(transport, delete=True)
        self.assertEqual(code, 1)
        self.assertEqual(fake.deleted, [])

    def test_rejects_non_https(self):
        out = io.StringIO()
        self.assertEqual(fc.main(["http://example.test:9443"], key=ADMIN, transport=FakeBichon(), out=out), 2)


if __name__ == "__main__":
    unittest.main()
