"""Bichon write-denial check for MailBurrow (Phase 0, task B02).

Checks that the reader token (member global role, account_viewer on the
Alex Rivera account) is denied the tested changes, using ONE sacrificial fictional
message instead of the demo mail. This is the separate procedure that the
routine, read-only tools/bichon_lab_check.py deliberately leaves out.

1. Make the probe message (no network):
       python tools\\bichon_write_denial.py --write-probe-eml build\\probe.eml
   Import build\\probe.eml into the Alex Rivera account, folder INBOX, with
   Bichon's Import page.
2. Run the check:
       python tools\\bichon_write_denial.py https://<test-server>:9443

The run touches only the message whose subject and sender are exactly the
probe's; if it does not find exactly one, it stops before sending any
change. It then:
- with the ADMIN token, adds and removes a tag on the probe, to prove the
  tag request is well formed (a refusal is only evidence if the same request
  works for someone allowed to make it);
- proves repair request shape with an ADMIN repair on the sacrificial probe;
- with the READER token, tries tag, repair and delete, expecting 403 each
  time; 401 is not permission evidence. The admin compares validated envelope
  snapshots after each attempt; any uncertainty stops further reader probes;
- finally deletes the probe with the ADMIN token, which proves the delete
  request is well formed and returns the Alex account to its 40 demo
  messages.

The summary holds only statuses and booleans, never tokens, addresses or
server text. Use only a disposable test server holding fictional mail.
"""
import argparse
import json
import sys
import time
import urllib.parse
from email.message import EmailMessage
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path

from bichon_lab_check import (EXPECT, MAX_BODY, Response, ask_key, is_int, items_of,
                              urllib_transport)

PROBE_SUBJECT = "MailBurrow write-denial probe"
PROBE_SENDER = "probe@write-denial.example"
PROBE_MESSAGE_ID = "<mailburrow-write-denial-probe@write-denial.example>"
# Bichon tags are Tantivy facets: update-tags validates each with
# Facet::from_text (a leading "/" is required) before checking permissions
# (crates/server/src/rest/api/message.rs, Bichon 2.4.2).
SHAPE_TAG = "/mailburrow-shape-check"
READER_TAG = "/mailburrow-reader-probe"
REFUSED = (401, 403)


def probe_eml():
    msg = EmailMessage()
    msg["From"] = "Write-denial Probe <%s>" % PROBE_SENDER
    msg["To"] = "Alex Rivera <%s>" % EXPECT["reader_email"]
    msg["Subject"] = PROBE_SUBJECT
    msg["Date"] = format_datetime(datetime(2026, 11, 14, 12, 0, tzinfo=timezone.utc))
    msg["Message-ID"] = PROBE_MESSAGE_ID
    msg.set_content("Fictional, sacrificial message for MailBurrow's Bichon write-denial check.\n"
                    "It is deleted by the check's final admin step.\n")
    return msg.as_bytes()


class Prober:
    """Sends only the requests this procedure needs, by role."""

    ALLOWED = {
        ("admin", "GET", "/minimal-account-list"),
        ("admin", "POST", "/search-messages"),
        ("admin", "GET", "/envelope"),
        ("admin", "POST", "/update-tags"),
        ("admin", "POST", "/delete-messages"),
        ("admin", "POST", "/repair-message"),
        ("reader", "GET", "/envelope"),
        ("reader", "POST", "/update-tags"),
        ("reader", "POST", "/repair-message"),
        ("reader", "POST", "/delete-messages"),
    }

    def __init__(self, base, transport, tokens):
        self.base, self.transport, self.tokens = base.rstrip("/") + "/api/v1", transport, tokens
        self.results, self.calls, self.redirects, self.errors = [], 0, 0, 0

    def send(self, role, method, path, payload=None, suffix=""):
        if (role, method, path) not in self.ALLOWED:
            raise ValueError("request not allowed")
        headers = {"Accept": "application/json", "User-Agent": "MailBurrow-bichon-write-denial/1",
                   "Authorization": "Bearer " + self.tokens[role]}
        body = None
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        self.calls += 1
        try:
            status, resp_headers, data = self.transport(method, self.base + path + suffix, headers, body)
        except Exception:
            self.errors += 1
            return Response(None, {}, b"")
        if not is_int(status) or not 100 <= status <= 599 or len(data) > MAX_BODY:
            self.errors += 1
            return Response(None, {}, b"")
        if 300 <= status < 400:
            self.redirects += 1
        return Response(status, resp_headers, data)

    def check(self, name, ok, detail=""):
        self.results.append(("PASS" if ok else "FAIL", name, detail))
        return ok

    def snapshot(self, account_id, env, role="admin"):
        """Return (status, normalized envelope or None, names of fields that failed validation).

        Bichon's Envelope schema makes `tags` optional, so an untagged message
        may omit it or send null; both are treated as no tags."""
        resp = self.send(role, "GET", "/envelope", suffix="/%d/%s" % (account_id, urllib.parse.quote(env, safe="")))
        obj = dict(resp.obj())
        tags = obj.get("tags")
        if tags is None:
            tags = []
        obj["tags"] = tags
        message_id = obj.get("message_id")
        checks = {
            "id": obj.get("id") == env,
            "account_id": obj.get("account_id") == account_id,
            "subject": obj.get("subject") == PROBE_SUBJECT,
            "from": obj.get("from") == PROBE_SENDER,
            "message_id": isinstance(message_id, str) and message_id.strip("<>") == PROBE_MESSAGE_ID.strip("<>"),
            "tags": isinstance(tags, list) and all(isinstance(t, str) for t in tags),
        }
        bad = [name for name, ok in checks.items() if not ok] if resp.status == 200 else []
        valid = resp.status == 200 and not bad
        return resp.status, (obj if valid else None), bad

    def tags(self, role, account_id, env, tag, action):
        return self.send(role, "POST", "/update-tags", {
            "updates": {str(account_id): [env]}, "tags": [tag], "action": action})


def st(resp):
    return "status %s" % (resp.status if resp.status is not None else "none (connection error)")


def find_probe(p):
    resp = p.send("admin", "GET", "/minimal-account-list")
    accounts = resp.json if isinstance(resp.json, list) else []
    matches = [a.get("id") for a in accounts if isinstance(a, dict)
               and a.get("email") == EXPECT["reader_email"] and is_int(a.get("id"))]
    alex = matches[0] if resp.status == 200 and len(matches) == 1 else None
    if alex is None:
        return None, None, "Alex Rivera account not found"
    found = p.send("admin", "POST", "/search-messages", {
        "filter": {"account_ids": [alex], "subject": PROBE_SUBJECT}, "page": 1, "page_size": 10,
        "sort_by": "DATE", "desc": True})
    items = items_of(found)
    if found.status != 200 or items is None:
        return alex, None, "probe search failed (%s)" % st(found)
    total = found.obj().get("total_items")
    if not is_int(total) or total != len(items) or len(items) > 10:
        return alex, None, "probe search incomplete or invalid; no writes allowed"
    exact = [i for i in items if i.get("subject") == PROBE_SUBJECT and i.get("from") == PROBE_SENDER
             and isinstance(i.get("message_id"), str)
             and i["message_id"].strip("<>") == PROBE_MESSAGE_ID.strip("<>")
             and i.get("account_id") == alex and isinstance(i.get("id"), str)]
    if len(exact) != 1:
        return alex, None, "%d probe messages found; import exactly one" % len(exact)
    return alex, exact[0]["id"], ""


def run(p):
    alex, env, problem = find_probe(p)
    if not p.check("Exactly one probe message in the Alex account", env is not None, problem or "found"):
        return
    status, before, bad = p.snapshot(alex, env)
    if not p.check("Admin reads the probe envelope", status == 200 and before is not None,
                   "status %s%s" % (status, "; unexpected fields " + ", ".join(bad) if bad else "")):
        return
    if not p.check("Probe tags do not collide with control tags",
                   SHAPE_TAG not in before["tags"] and READER_TAG not in before["tags"]):
        return
    status, reader_before, bad = p.snapshot(alex, env, role="reader")
    if not p.check("Reader token can read the probe before write tests", status == 200 and reader_before == before,
                   "status %s%s" % (status, "; unexpected fields " + ", ".join(bad) if bad else "")):
        return

    # Once a verified sacrificial probe is selected, attempt cleanup even if
    # a malformed response interrupts the experiment. Never broaden its ID.
    try:
        add = p.tags("admin", alex, env, SHAPE_TAG, "Add")
        added_status, with_tag, _ = p.snapshot(alex, env)
        remove = p.tags("admin", alex, env, SHAPE_TAG, "Remove")
        restored_status, restored, _ = p.snapshot(alex, env)
        shape_ok = p.check("Tag request is well formed (admin add and remove work)",
                           add.status == 200 and remove.status == 200 and added_status == 200
                           and with_tag is not None and SHAPE_TAG in with_tag["tags"]
                           and restored_status == 200 and restored == before,
                           "add %s, remove %s" % (st(add), st(remove)))
        if not shape_ok:
            return

        suffix = "/%d/%s" % (alex, urllib.parse.quote(env, safe=""))
        repair_control = p.send("admin", "POST", "/repair-message", suffix=suffix)
        status, before, _ = p.snapshot(alex, env)
        if not p.check("Repair request is well formed (admin control)",
                       repair_control.status == 200 and status == 200 and before is not None,
                       st(repair_control)):
            return

        attempt = p.tags("reader", alex, env, READER_TAG, "Add")
        status, after, _ = p.snapshot(alex, env)
        p.check("Reader tag change refused and nothing changed",
                attempt.status == 403 and status == 200 and after == before,
                "%s; envelope unchanged %s" % (st(attempt), after == before))
        # Stop further reader probes after any accepted or uncertain change.
        if attempt.status != 403 or status != 200 or after != before:
            return

        repair = p.send("reader", "POST", "/repair-message", suffix=suffix)
        status, after, _ = p.snapshot(alex, env)
        p.check("Reader repair refused and the probe is unchanged",
                repair.status == 403 and status == 200 and after == before,
                "%s; probe status %s" % (st(repair), status))
        if repair.status != 403 or status != 200 or after != before:
            return

        delete = p.send("reader", "POST", "/delete-messages", {str(alex): [env]})
        status, after, _ = p.snapshot(alex, env)
        p.check("Reader delete refused and the probe still exists",
                delete.status == 403 and status == 200 and after == before,
                "%s; probe status %s" % (st(delete), status))
    finally:
        cleanup = p.send("admin", "POST", "/delete-messages", {str(alex): [env]})
        gone = False
        for _ in range(5):
            status, _, _ = p.snapshot(alex, env)
            account, found_env, problem = find_probe(p)
            # A failed/ambiguous search is never proof of absence.
            gone = (status == 404 and account == alex and found_env is None
                    and problem == "0 probe messages found; import exactly one")
            if gone:
                break
            time.sleep(1)
        p.check("Delete request is well formed (admin deletes the probe)", cleanup.status == 200 and gone,
                "%s; probe removed %s" % (st(cleanup), gone))
        p.check("No redirects", p.redirects == 0, "%d" % p.redirects)
        p.check("No connection errors", p.errors == 0, "%d" % p.errors)


def report(p, out):
    print("\nBichon write-denial check v1 (paste this summary; it holds no keys, addresses or server text)", file=out)
    print("Python %s, %s" % (sys.version.split()[0], time.strftime("%Y-%m-%d %H:%M")), file=out)
    for status, name, detail in p.results:
        print("[%s] %s%s" % (status, name, (": " + detail) if detail else ""), file=out)
    failed = sum(1 for r in p.results if r[0] == "FAIL")
    ok = failed == 0 and len(p.results) >= 9
    print("%d checks, %d failed; %d requests" % (len(p.results), failed, p.calls), file=out)
    print("RESULT: %s" % ("reader writes refused" if ok else
                          "NOT PROVEN: a check failed or the run stopped early"), file=out)
    return ok


def main(argv=None, keys=None, transport=None, out=None):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description="Bichon write-denial check (one sacrificial message).")
    parser.add_argument("url", nargs="?", help="Test server base URL, e.g. https://<host>:9443")
    parser.add_argument("--write-probe-eml", metavar="PATH", help="Write the probe message and exit (no network)")
    args = parser.parse_args(argv)
    if args.write_probe_eml:
        Path(args.write_probe_eml).parent.mkdir(parents=True, exist_ok=True)
        Path(args.write_probe_eml).write_bytes(probe_eml())
        print("Wrote the probe message. Import it into the Alex Rivera account, folder INBOX.", file=out)
        return 0
    if not args.url:
        parser.print_usage(out)
        return 2
    try:
        parsed = urllib.parse.urlsplit(args.url)
        port = parsed.port
    except ValueError:
        print("Invalid HTTPS base address", file=out)
        return 2
    if parsed.scheme != "https" or not parsed.hostname or parsed.path not in ("", "/") or parsed.query \
            or parsed.fragment or parsed.username is not None or parsed.password is not None \
            or (port is not None and not 1 <= port <= 65535):
        print("Use the HTTPS base address, for example https://<host>:9443", file=out)
        return 2
    if keys is None:
        keys = (ask_key("Admin token: "), ask_key("Reader token: "))
    if not keys[0] or not keys[1]:
        return 2
    if keys[0] == keys[1]:
        print("The admin and reader tokens must be different.", file=out)
        return 2
    p = Prober(args.url, transport or urllib_transport, {"admin": keys[0], "reader": keys[1]})
    try:
        run(p)
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, OverflowError):
        p.check("Response contracts valid", False, "malformed response; no server values displayed")
    return 0 if report(p, out) else 1


if __name__ == "__main__":
    sys.exit(main())
