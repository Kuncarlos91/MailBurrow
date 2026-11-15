"""Bichon write-denial check for MailBurrow (Phase 0, task B02).

Proves that the reader token (member global role, account_viewer on the
Alex Rivera account) cannot change mail, using ONE sacrificial fictional
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
- with the READER token, tries to add a tag, repair the probe and delete it,
  expecting 401 or 403 each time, and checks with the admin token after each
  attempt that the probe still exists and its tags did not change (removing
  the reader's tag again if the server wrongly accepted it);
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
SHAPE_TAG = "mailburrow-shape-check"
READER_TAG = "mailburrow-reader-probe"
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

    def envelope(self, account_id, env):
        resp = self.send("admin", "GET", "/envelope", suffix="/%d/%s" % (account_id, urllib.parse.quote(env, safe="")))
        tags = resp.obj().get("tags")
        return resp.status, (sorted(t for t in tags if isinstance(t, str)) if isinstance(tags, list) else None)

    def tags(self, role, account_id, env, tag, action):
        return self.send(role, "POST", "/update-tags", {
            "updates": {str(account_id): [env]}, "tags": [tag], "action": action})


def st(resp):
    return "status %s" % (resp.status if resp.status is not None else "none (connection error)")


def find_probe(p):
    resp = p.send("admin", "GET", "/minimal-account-list")
    accounts = resp.json if isinstance(resp.json, list) else []
    alex = next((a.get("id") for a in accounts if isinstance(a, dict)
                 and a.get("email") == EXPECT["reader_email"] and is_int(a.get("id"))), None)
    if alex is None:
        return None, None, "Alex Rivera account not found"
    found = p.send("admin", "POST", "/search-messages", {
        "filter": {"account_ids": [alex], "subject": PROBE_SUBJECT}, "page": 1, "page_size": 10,
        "sort_by": "DATE", "desc": True})
    items = items_of(found)
    if found.status != 200 or items is None:
        return alex, None, "probe search failed (%s)" % st(found)
    exact = [i for i in items if i.get("subject") == PROBE_SUBJECT and PROBE_SENDER in str(i.get("from", ""))
             and "mailburrow-write-denial-probe@" in str(i.get("message_id", ""))
             and i.get("account_id") == alex and isinstance(i.get("id"), str)]
    if len(exact) != 1:
        return alex, None, "%d probe messages found; import exactly one" % len(exact)
    return alex, exact[0]["id"], ""


def run(p):
    alex, env, problem = find_probe(p)
    if not p.check("Exactly one probe message in the Alex account", env is not None, problem or "found"):
        return
    status, before = p.envelope(alex, env)
    if not p.check("Admin reads the probe envelope", status == 200 and before is not None, "status %s" % status):
        return

    add = p.tags("admin", alex, env, SHAPE_TAG, "Add")
    _, with_tag = p.envelope(alex, env)
    remove = p.tags("admin", alex, env, SHAPE_TAG, "Remove")
    _, restored = p.envelope(alex, env)
    shape_ok = p.check("Tag request is well formed (admin add and remove work)",
                       add.status == 200 and remove.status == 200 and SHAPE_TAG in (with_tag or [])
                       and restored == before, "add %s, remove %s" % (st(add), st(remove)))

    attempt = p.tags("reader", alex, env, READER_TAG, "Add")
    status, after = p.envelope(alex, env)
    changed = READER_TAG in (after or [])
    if changed:
        p.tags("admin", alex, env, READER_TAG, "Remove")
    p.check("Reader tag change refused and nothing changed",
            shape_ok and attempt.status in REFUSED and not changed and after == before,
            "%s; tags changed %s%s" % (st(attempt), changed, "" if shape_ok else "; request shape unproven"))

    repair = p.send("reader", "POST", "/repair-message", suffix="/%d/%s" % (alex, urllib.parse.quote(env, safe="")))
    status, after = p.envelope(alex, env)
    p.check("Reader repair refused and the probe is unchanged", repair.status in REFUSED and status == 200
            and after == before, "%s; probe status %s" % (st(repair), status))

    delete = p.send("reader", "POST", "/delete-messages", {str(alex): [env]})
    status, _ = p.envelope(alex, env)
    p.check("Reader delete refused and the probe still exists", delete.status in REFUSED and status == 200,
            "%s; probe status %s" % (st(delete), status))

    cleanup = p.send("admin", "POST", "/delete-messages", {str(alex): [env]})
    gone = None
    for _ in range(5):
        _, gone_env, _ = find_probe(p)
        gone = gone_env is None
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
