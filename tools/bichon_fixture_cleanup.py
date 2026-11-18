"""Remove the MailBurrow Bichon measurement fixtures from a test server.

Undoes tools/bichon_fixtures.py: after the phone measurements, the Alex
Rivera account goes back to its 40 demo messages, so tools/bichon_lab_check.py
passes again.

    python tools\\bichon_fixture_cleanup.py https://<test-server>:9443
    python tools\\bichon_fixture_cleanup.py https://<test-server>:9443 --delete

Without --delete it only checks and reports. It selects messages by exact
Message-ID, subject and sender from the generator, all in the Alex Rivera
account and the single folder named "mailburrow-fixtures". It refuses to
delete anything unless that folder holds exactly the 32 fixtures and no
other mail, and no fixture-marked message exists outside it. Then, with
--delete, it deletes those 32 with the ADMIN token (a reader is refused) and
waits until the folder is empty. Remove the empty folder afterwards in
Bichon's interface, if you want; this tool deletes no folders.

The summary holds only counts and statuses, never tokens, addresses or
server text. Use only a disposable test server holding fictional mail.
"""
import argparse
import functools
import json
import sys
import time
import urllib.parse
from email.utils import parseaddr

from bichon_fixtures import MARKER, SENDER, messages
from bichon_lab_check import EXPECT, MAX_BODY, Response, ask_key, is_int, items_of, urllib_transport

FOLDER = "mailburrow-fixtures"
PAGE = 25
MAX_PAGES = 4  # far above the 32 fixtures; more means something else matched
WAIT_SECONDS = 120
SENDER_ADDRESS = parseaddr(SENDER)[1]  # envelopes carry the address; the name is separate


@functools.lru_cache(maxsize=1)
def expected():
    """Message-ID (without brackets) -> subject, from the generator itself."""
    return {m["Message-ID"].strip("<>"): str(m["Subject"]) for m in messages()}


class Cleaner:
    ALLOWED = {("GET", "/minimal-account-list"), ("GET", "/list-mailboxes"),
               ("POST", "/search-messages"), ("POST", "/delete-messages")}

    def __init__(self, base, transport, token, sleep=time.sleep):
        self.base, self.transport, self.token, self.sleep = base.rstrip("/") + "/api/v1", transport, token, sleep
        self.results, self.calls = [], 0

    def send(self, method, path, payload=None, suffix=""):
        if (method, path) not in self.ALLOWED:
            raise ValueError("request not allowed")
        headers = {"Accept": "application/json", "User-Agent": "MailBurrow-bichon-fixture-cleanup/1",
                   "Authorization": "Bearer " + self.token}
        body = None
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        self.calls += 1
        try:
            status, resp_headers, data = self.transport(method, self.base + path + suffix, headers, body)
        except Exception:
            return Response(None, {}, b"")
        if not is_int(status) or not 100 <= status <= 599 or len(data) > MAX_BODY:
            return Response(None, {}, b"")
        return Response(status, resp_headers, data)

    def check(self, name, ok, detail=""):
        self.results.append(("PASS" if ok else "FAIL", name, detail))
        return ok

    def note(self, name, detail=""):
        self.results.append(("INFO", name, detail))

    def search(self, flt):
        """All items for a filter, or None if a page fails or it is larger than expected."""
        found = []
        for page in range(1, MAX_PAGES + 1):
            resp = self.send("POST", "/search-messages", {"filter": flt, "page": page, "page_size": PAGE,
                                                          "sort_by": "DATE", "desc": False})
            items = items_of(resp)
            total = resp.obj().get("total_items")
            if resp.status != 200 or items is None or not is_int(total) or total > PAGE * MAX_PAGES:
                return None
            found += items
            if len(found) >= total or not items:
                return found if len(found) == total else None
        return None


def st(resp):
    return "status %s" % (resp.status if resp.status is not None else "none (connection error)")


def run(c, delete):
    resp = c.send("GET", "/minimal-account-list")
    accounts = resp.json if isinstance(resp.json, list) else []
    alex = [a.get("id") for a in accounts if isinstance(a, dict)
            and a.get("email") == EXPECT["reader_email"] and is_int(a.get("id"))]
    if not c.check("Alex Rivera account found", resp.status == 200 and len(alex) == 1, st(resp)):
        return
    alex = alex[0]

    resp = c.send("GET", "/list-mailboxes", suffix="/%d" % alex)
    boxes = resp.obj().get("mailboxes")
    boxes = boxes if isinstance(boxes, list) else []
    named = [b.get("id") for b in boxes if isinstance(b, dict) and b.get("name") == FOLDER and is_int(b.get("id"))]
    if not c.check("Exactly one %s folder" % FOLDER, resp.status == 200 and len(named) == 1,
                   "%s, %d found" % (st(resp), len(named))):
        return
    folder = named[0]

    want = expected()
    in_folder = c.search({"account_ids": [alex], "mailbox_ids": [folder]})
    if not c.check("Folder contents listed", in_folder is not None):
        return
    marked = c.search({"subject": MARKER})
    if not c.check("Fixture-marked messages listed", marked is not None):
        return

    def exact(i):
        mid = i.get("message_id")
        mid = mid.strip("<>") if isinstance(mid, str) else None
        return (mid in want and i.get("subject") == want[mid] and i.get("from") == SENDER_ADDRESS
                and i.get("account_id") == alex and i.get("mailbox_id") == folder and isinstance(i.get("id"), str))

    if not in_folder and not any(MARKER in str(i.get("subject", "")) for i in marked):
        c.check("Fixtures already removed", True, "folder empty, no fixture-marked messages")
        return
    ids = {i.get("message_id", "").strip("<>") for i in in_folder if isinstance(i.get("message_id"), str)}
    if not c.check("Folder holds only the %d fixtures" % len(want),
                   len(in_folder) == len(want) and all(exact(i) for i in in_folder) and ids == set(want),
                   "%d messages, %d exact matches" % (len(in_folder), sum(1 for i in in_folder if exact(i)))):
        return
    folder_envs = {i["id"] for i in in_folder}
    outside = [i for i in marked if i.get("id") not in folder_envs and MARKER in str(i.get("subject", ""))]
    if not c.check("No fixture-marked message outside the folder", not outside, "%d outside" % len(outside)):
        return

    if not delete:
        c.note("Dry run", "nothing deleted; rerun with --delete to remove these %d" % len(want))
        return
    resp = c.send("POST", "/delete-messages", {str(alex): sorted(folder_envs)})
    if not c.check("Delete accepted (admin)", resp.status == 200, st(resp)):
        return
    remaining = None
    for _ in range(WAIT_SECONDS // 5 + 1):
        remaining = c.search({"account_ids": [alex], "mailbox_ids": [folder]})
        if remaining == []:
            break
        c.sleep(5)
    c.check("Folder empty after delete", remaining == [],
            "%s remaining" % ("unknown" if remaining is None else len(remaining)))
    total = c.search({"account_ids": [alex]})
    c.check("Alex account back to %d messages" % EXPECT["reader_total"],
            total is not None and len(total) == EXPECT["reader_total"],
            "%s messages" % ("unknown" if total is None else len(total)))


def report(c, delete, out):
    print("\nBichon fixture cleanup v1 (paste this summary; it holds no keys, addresses or server text)", file=out)
    print("Python %s, %s, %s" % (sys.version.split()[0], time.strftime("%Y-%m-%d %H:%M"),
                                 "delete" if delete else "dry run"), file=out)
    for status, name, detail in c.results:
        print("[%s] %s%s" % (status, name, (": " + detail) if detail else ""), file=out)
    failed = sum(1 for r in c.results if r[0] == "FAIL")
    ok = failed == 0 and bool(c.results)
    print("%d checks, %d failed; %d requests" % (len(c.results), failed, c.calls), file=out)
    done = any(r[1] == "Fixtures already removed" for r in c.results)
    print("RESULT: %s" % (("nothing to remove" if done else "fixtures removed" if delete else "ready to delete") if ok
                          else "STOPPED: nothing further was changed"), file=out)
    return ok


def main(argv=None, key=None, transport=None, out=None, sleep=time.sleep):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description="Remove the MailBurrow Bichon fixtures (dry run by default).")
    parser.add_argument("url", help="Test server base URL, e.g. https://<host>:9443")
    parser.add_argument("--delete", action="store_true", help="Delete the verified fixtures")
    args = parser.parse_args(argv)
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
    if key is None:
        key = ask_key("Admin token: ")
    if not key:
        return 2
    c = Cleaner(args.url, transport or urllib_transport, key, sleep)
    try:
        run(c, args.delete)
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, OverflowError):
        c.check("Response contracts valid", False, "malformed response; no server values displayed")
    return 0 if report(c, args.delete, out) else 1


if __name__ == "__main__":
    sys.exit(main())
