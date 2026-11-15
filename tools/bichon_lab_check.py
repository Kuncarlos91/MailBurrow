"""Bichon lab check for MailBurrow (Phase 0, task B04).

Runs API checks against a TEST Bichon server that holds only the fictional
demo mail from tools/export_demo_eml.py (Alex Rivera and Maple Street Bakery
imported into two NoSync accounts), and prints a summary that is safe to
share. It always verifies certificates and never follows redirects.

Requests are read-only: GET, plus POST to the search endpoint, which reads.
Write-denial testing belongs in a separate disposable-lab procedure, not this
routine checker. This script never sends a mutation request.

Usage (PowerShell):
    python tools\bichon_lab_check.py https://<test-server>:9443

It asks for up to four tokens without echoing them (on Windows, paste with
a right-click): an admin token (control only, never used by the app), the
reader token (user with the member global role and account_viewer on the
Alex Rivera account only) and, optionally, a revoked token and an expired
token. The expired token must be a different token whose expiry has passed
and that was never revoked; a revoked token proves nothing about expiry.

Every check is PASS, FAIL or SKIP and either required or optional. The run
succeeds (exit 0) only if no check failed and no required check was skipped.
The summary prints only statuses, counts, sizes, booleans, permission names
of the form "area:action" and field names from fixed allowlists: never
message text, addresses or other values sent by the server.
"""
import argparse
import getpass
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30
MAX_BODY = 41 * 1024 * 1024  # enough to spot a response over the app's limits

# Expected results, derived from assets/demo/archive.json (fictional demo mail).
# tools/test_bichon_lab_check.py checks these against the fixtures.
EXPECT = {
    "reader_email": "alex.rivera@example.com",
    "other_email": "hello@maple-street-bakery.example",
    "reader_total": 40,
    "other_total": 20,
    "own_term": "clockwork",   # occurs in exactly one Alex message
    "other_term": "wholesale",  # occurs only in Maple Street Bakery mail
}

READER_GLOBAL_ALLOWED = {"system:access"}
READER_ACCOUNT_ALLOWED = {"data:read", "account:read_details"}
KNOWN_PERMISSIONS = READER_GLOBAL_ALLOWED | READER_ACCOUNT_ALLOWED

KNOWN_FIELDS = {
    "id", "email", "name", "account_type", "auth_type", "kind", "items", "total_items",
    "total_pages", "current_page", "page_size", "mailboxes", "status", "error", "examined",
    "total", "account_id", "mailbox_id", "mailbox_name", "message_id", "uid", "imap_uid",
    "subject", "preview", "from", "from_name", "wire_from", "to", "cc", "bcc", "date",
    "internal_date", "ingest_at", "cleanup_moved", "size", "thread_id", "attachment_count",
    "regular_attachment_count", "tags", "content_hash", "account_email", "account_name",
    "text", "html", "attachments", "has_remote_content", "file_type", "inline", "filename",
    "content_id", "raw_content_hash", "is_message", "extracted_text", "extracted_page_count",
    "extracted_is_ocr", "message", "code",
}
KNOWN_HEADERS = {"ratelimit-limit", "ratelimit-remaining", "ratelimit-reset", "retry-after",
                 "x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset"}
# Search text the app must handle without a server error (plan decision D09).
ODD_QUERIES = ['"unbalanced', "harbor AND OR", "(", "*", "café", "a" * 300, "x:y", "-"]
REFUSED = (401, 403, 404)


# ---------------------------------------------------------------- transport

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx comes back as an HTTPError and is counted


def urllib_transport(method, url, headers, body):
    """Send one request; return (status, lower-case headers, body bytes)."""
    if method not in ("GET", "POST"):
        raise ValueError("method not allowed")
    opener = urllib.request.build_opener(
        NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        resp = opener.open(req, timeout=TIMEOUT)
        return resp.status, {k.lower(): v for k, v in resp.headers.items()}, read_bounded(resp)
    except urllib.error.HTTPError as err:
        return err.code, {k.lower(): v for k, v in err.headers.items()}, read_bounded(err)


def read_bounded(response):
    data = response.read(MAX_BODY + 1)
    if len(data) > MAX_BODY:
        raise ValueError("response exceeds host budget")
    return data


class Response:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body
        try:
            self.json = json.loads(body) if body else None
        except (ValueError, UnicodeDecodeError, RecursionError):
            self.json = None

    def obj(self):
        return self.json if isinstance(self.json, dict) else {}


# The only POST path this routine checker may send.
POST_ALLOWED = {"/search-messages"}


class Lab:
    def __init__(self, base, prefix, transport):
        self.base, self.prefix, self.transport = base.rstrip("/"), prefix, transport
        self.results = []
        self.redirects = 0
        self.connection_errors = 0
        self.headers_seen = set()
        self.calls = 0

    def request(self, method, path, token=None, params=None, payload=None, auth="bearer"):
        if method not in ("GET", "POST"):
            raise ValueError("method not allowed")
        if not path.startswith("/") or "?" in path or "#" in path:
            raise ValueError("invalid request path")
        if method == "POST" and path not in POST_ALLOWED:
            raise ValueError("POST path not allowlisted")
        url = self.base + self.prefix + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {"Accept": "application/json", "User-Agent": "MailBurrow-bichon-lab-check/1"}
        body = None
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if token and auth == "bearer":
            headers["Authorization"] = "Bearer " + token
        self.calls += 1
        try:
            status, resp_headers, data = self.transport(method, url, headers, body)
        except Exception:  # connection, TLS or timeout: report the category only
            self.connection_errors += 1
            return Response(None, {}, b"")
        if not is_int(status) or not 100 <= status <= 599 or len(data) > MAX_BODY:
            self.connection_errors += 1
            return Response(None, {}, b"")
        if 300 <= status < 400:
            self.redirects += 1
        self.headers_seen.update(h for h in resp_headers if h in KNOWN_HEADERS)
        return Response(status, resp_headers, data)

    def get(self, path, token=None, params=None):
        return self.request("GET", path, token, params)

    def search(self, token, filt, page=1, page_size=25, sort="DATE"):
        payload = {"filter": filt, "page": page, "page_size": page_size, "sort_by": sort, "desc": True}
        return self.request("POST", "/search-messages", token, payload=payload)

    def record(self, status, required, name, detail=""):
        self.results.append((status, required, name, detail))

    def check(self, name, ok, detail="", required=True):
        self.record("PASS" if ok else "FAIL", required, name, detail)
        return ok

    def skip(self, name, reason, required=True):
        self.record("SKIP", required, name, reason)


# ---------------------------------------------------------------- safe output

def st(resp):
    return "status %s" % (resp.status if resp.status is not None else "none (connection error)")


def names(keys):
    keys = sorted(set(str(k) for k in keys))
    shown = [k for k in keys if k in KNOWN_FIELDS]
    other = len(keys) - len(shown)
    if not keys:
        return "none"
    return ", ".join(shown) + (" (+%d other)" % other if other else "")


def perms(values):
    values = sorted(set(str(v) for v in values if isinstance(v, str)))
    shown = [v for v in values if v in KNOWN_PERMISSIONS]
    other = len(values) - len(shown)
    return (", ".join(shown) or "none") + (" (+%d other)" % other if other else "")


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def items_of(resp):
    data = resp.obj()
    items = data.get("items")
    return items if isinstance(items, list) and all(isinstance(i, dict) for i in items) else None


def refused(resp):
    return resp.status in REFUSED


def refused_or_empty(resp):
    if refused(resp):
        return True
    items = items_of(resp)
    return resp.status == 200 and items is not None and len(items) == 0


def secret_state(value):
    if value is None:
        return "absent"
    if value == "":
        return "empty"
    return "non-empty"


# ---------------------------------------------------------------- checks

def find_accounts(lab, admin):
    resp = lab.get("/minimal-account-list", admin)
    accounts = [a for a in resp.json if isinstance(a, dict)] if isinstance(resp.json, list) else []
    by_email = {a.get("email"): a for a in accounts if is_int(a.get("id"))}
    return resp, accounts, by_email.get(EXPECT["reader_email"]), by_email.get(EXPECT["other_email"])


def all_pages(lab, token, account_id, page_size=10, limit=20):
    """Collect every envelope of one account; returns (ok, ids, totals, foreign)."""
    ids, totals, foreign, ok = [], set(), 0, True
    for page in range(1, limit + 1):
        resp = lab.search(token, {"account_ids": [account_id]}, page=page, page_size=page_size)
        items = items_of(resp)
        if resp.status != 200 or items is None:
            return False, ids, totals, foreign
        total = resp.obj().get("total_items")
        if not is_int(total) or total < 0 or len(items) > page_size:
            return False, ids, totals, foreign
        totals.add(total)
        for item in items:
            if item.get("account_id") != account_id:
                foreign += 1
            if isinstance(item.get("id"), str):
                ids.append(item["id"])
        if len(items) < page_size:
            return ok, ids, totals, foreign
    return False, ids, totals, foreign


def run_checks(lab, admin, reader, revoked, expired):
    # Authentication
    r = lab.get("/current-user", admin)
    if not lab.check("API reachable with admin token (Bearer)", r.status == 200, "%s, json %s" % (
            st(r), "object" if r.obj() else "none")):
        return
    none = lab.get("/minimal-account-list")
    lab.check("Request without a token refused", refused(none), st(none))
    bad = lab.get("/minimal-account-list", "not-a-real-token-0000")
    lab.check("Malformed token refused", refused(bad), st(bad))
    for label, token in (("Revoked", revoked), ("Expired", expired)):
        if token:
            resp = lab.get("/minimal-account-list", token)
            lab.check("%s token refused" % label, refused(resp),
                      st(resp) + ("; expiry state supplied by operator" if label == "Expired" else ""),
                      required=False)
        else:
            lab.skip("%s token refused" % label, "no %s token given" % label.lower(), required=False)

    # Accounts and the reader's permissions
    resp, accounts, own, other = find_accounts(lab, admin)
    lab.check("Admin minimal account list has both demo accounts", own is not None and other is not None,
              "%s, %d accounts; fields %s" % (st(resp), len(accounts), names(accounts[0].keys()) if accounts else "none"))
    if own is None or other is None:
        return
    own_id, other_id = own["id"], other["id"]
    lab.check("Account IDs are integers within 64-bit range",
              all(0 < a < 2 ** 63 for a in (own_id, other_id)), "%d and %d digits" % (
                  len(str(own_id)), len(str(other_id))))
    rd = lab.get("/minimal-account-list", reader)
    rd_accounts = [a for a in rd.json if isinstance(a, dict)] if isinstance(rd.json, list) else []
    rd_ids = [a.get("id") for a in rd_accounts]
    lab.check("Reader minimal account list shows only Alex", rd.status == 200 and rd_ids == [own_id],
              "%s, %d accounts, Alex %s, Bakery %s" % (st(rd), len(rd_ids), own_id in rd_ids, other_id in rd_ids))

    me_resp = lab.get("/current-user", reader)
    me = me_resp.obj()
    global_perms = me.get("global_permissions") if isinstance(me.get("global_permissions"), list) else []
    acct_perms = me.get("account_permissions") if isinstance(me.get("account_permissions"), dict) else {}
    own_perms = acct_perms.get(str(own_id)) or []
    lab.check("Reader global permissions are login only", me_resp.status == 200 and isinstance(me.get("global_permissions"), list)
              and set(global_perms) == READER_GLOBAL_ALLOWED,
              perms(global_perms))
    lab.check("Reader account permissions are read only, Alex only",
              set(acct_perms.keys()) <= {str(own_id)} and set(own_perms) == READER_ACCOUNT_ALLOWED,
              "%d accounts with permissions; Alex: %s" % (len(acct_perms), perms(own_perms)))
    lab.check("Reader current-user password field (reported)", True, secret_state(me.get("password")),
              required=False)
    full = lab.get("/accounts", reader)
    full_items = items_of(full) or []
    exposed = sum(1 for a in full_items if isinstance(a.get("imap"), dict)
                  and secret_state((a["imap"].get("auth") or {}).get("password")) == "non-empty")
    lab.check("Reader /accounts exposes no IMAP password (reported; the app never calls it)", exposed == 0,
              "%s, %d items, %d with an IMAP password" % (st(full), len(full_items), exposed), required=False)

    # Mailboxes
    mb = lab.get("/list-mailboxes/%d" % own_id, reader)
    boxes = mb.obj().get("mailboxes")
    lab.check("Reader lists Alex mailboxes", mb.status == 200 and isinstance(boxes, list) and len(boxes) >= 1,
              "%s, %s mailboxes, status field %s" % (st(mb), len(boxes) if isinstance(boxes, list) else "no",
                                                     "present" if "status" in mb.obj() else "missing"))
    mo = lab.get("/list-mailboxes/%d" % other_id, reader)
    lab.check("Reader refused Bakery mailboxes", refused(mo) or (mo.status == 200 and mo.obj().get("mailboxes") == []),
              st(mo))

    # Listing and search
    ok, ids, totals, foreign = all_pages(lab, reader, own_id)
    lab.check("Reader browses Alex completely", ok and len(set(ids)) == EXPECT["reader_total"] and foreign == 0
              and len(ids) == len(set(ids)) and totals == {EXPECT["reader_total"]},
              "%d distinct of %d expected, totals %s, %d from other accounts" % (
                  len(set(ids)), EXPECT["reader_total"], sorted(t for t in totals if is_int(t)), foreign))
    first = lab.search(reader, {"account_ids": [own_id]}, page_size=5)
    sample = (items_of(first) or [{}])[0]
    lab.check("Envelope fields", bool(sample.get("id")), names(sample.keys()))
    unscoped = lab.search(reader, {}, page_size=50)
    u_items = items_of(unscoped)
    lab.check("Reader search without an account filter stays in Alex",
              unscoped.status == 200 and u_items is not None
              and len(u_items) == EXPECT["reader_total"]
              and unscoped.obj().get("total_items") == EXPECT["reader_total"]
              and all(i.get("account_id") == own_id for i in u_items),
              "%s, %s items, total %s" % (st(unscoped), len(u_items) if u_items is not None else "no",
                                          (unscoped.obj().get("total_items") if is_int(unscoped.obj().get("total_items")) else "invalid")))
    cross = lab.search(reader, {"account_ids": [other_id]}, page_size=5)
    lab.check("Reader search on Bakery account returns nothing", refused_or_empty(cross), "%s, %s items" % (
        st(cross), len(items_of(cross) or [])))
    hit = lab.search(reader, {"account_ids": [own_id], "text": EXPECT["own_term"]}, page_size=5)
    lab.check("Reader text search finds the known Alex message", len(items_of(hit) or []) == 1,
              "%s, %d hits" % (st(hit), len(items_of(hit) or [])))
    leak = lab.search(reader, {"text": EXPECT["other_term"]}, page_size=5)
    control = lab.search(admin, {"text": EXPECT["other_term"]}, page_size=5)
    lab.check("Reader text search cannot find a Bakery term", refused_or_empty(leak) and len(items_of(control) or []) >= 1,
              "admin control %d hits; reader %s, %d hits" % (len(items_of(control) or []), st(leak), len(items_of(leak) or [])))
    for query in ODD_QUERIES:
        resp = lab.search(reader, {"account_ids": [own_id], "text": query}, page_size=5)
        lab.check("Unusual search text handled (%d chars)" % len(query),
                  resp.status in (200, 400, 422),
                  "%s, %s" % (st(resp), "items" if items_of(resp) is not None else
                              ("error {%s}" % names(resp.obj().keys()) if resp.obj() else "no json")),
                  required=False)

    # Messages and attachments
    own_env = ids[0] if ids else None
    att = lab.search(reader, {"account_ids": [own_id], "has_attachment": True}, page_size=10)
    att_items = items_of(att) or []
    lab.check("Attachment filter returns Alex messages with attachments",
              bool(att_items) and all(is_int(i.get("attachment_count")) and i["attachment_count"] > 0 for i in att_items),
              "%s, %d items" % (st(att), len(att_items)))
    other_search = lab.search(admin, {"account_ids": [other_id]}, page_size=5)
    other_env = ((items_of(other_search) or [{}])[0]).get("id")
    if not own_env or not other_env:
        lab.skip("Message checks", "no envelope IDs found")
        return

    content = lab.get("/message-content/%d/%s" % (own_id, urllib.parse.quote(own_env, safe="")), reader,
                      {"block_remote_content": "true"})
    c = content.obj()
    lab.check("Reader opens an Alex message (parsed, remote content blocked)", content.status == 200 and
              ("text" in c or "html" in c), "%s, %d bytes, fields %s" % (st(content), len(content.body), names(c.keys())))
    downloaded = 0
    mismatched = 0
    extracted = 0
    for item in att_items[:6]:
        env = item.get("id")
        detail = lab.get("/message-content/%d/%s" % (own_id, urllib.parse.quote(env, safe="")), reader,
                         {"block_remote_content": "true"}).obj()
        for a in detail.get("attachments") or []:
            if downloaded >= 12:
                break
            if not isinstance(a, dict) or a.get("inline") or not a.get("content_hash"):
                continue
            if a.get("extracted_text"):
                extracted += 1
            dl = lab.get("/download-attachment/%d/%s" % (own_id, urllib.parse.quote(env, safe="")), reader,
                         {"content_hash": a["content_hash"]})
            downloaded += 1
            if dl.status != 200 or len(dl.body) != a.get("size"):
                mismatched += 1
    lab.check("Reader downloads Alex attachments at their stated size", downloaded > 0 and mismatched == 0,
              "%d downloaded, %d mismatched or failed" % (downloaded, mismatched))
    lab.check("Attachment text in message details (reported; Pro feature)", True,
              "%d attachments carried extracted_text" % extracted, required=False)
    raw = lab.get("/download-message/%d/%s" % (own_id, urllib.parse.quote(own_env, safe="")), reader)
    lab.check("Reader refused raw EML download", refused(raw), st(raw))
    oc = lab.get("/message-content/%d/%s" % (other_id, urllib.parse.quote(other_env, safe="")), reader)
    lab.check("Reader refused a Bakery message", refused(oc), st(oc))
    swap = lab.get("/message-content/%d/%s" % (own_id, urllib.parse.quote(other_env, safe="")), reader)
    lab.check("Reader refused a Bakery message under the Alex account ID", refused(swap) or swap.status == 400, st(swap))
    oe = lab.get("/envelope/%d/%s" % (other_id, urllib.parse.quote(other_env, safe="")), reader)
    lab.check("Reader refused a Bakery envelope", refused(oe), st(oe))
    # A real attachment plus a successful admin control is essential: an
    # invented hash could return 404 even without any authorization checks.
    other_atts = lab.search(admin, {"account_ids": [other_id], "has_attachment": True}, page_size=1)
    candidates = items_of(other_atts) or []
    foreign_files = []
    if candidates:
        foreign_env = candidates[0].get("id")
        if isinstance(foreign_env, str):
            detail = lab.get("/message-content/%d/%s" % (other_id, urllib.parse.quote(foreign_env, safe="")),
                             admin, {"block_remote_content": "true"})
            foreign_files = detail.obj().get("attachments") or []
    real = next((a for a in foreign_files if isinstance(a, dict) and not a.get("inline")
                 and isinstance(a.get("content_hash"), str) and is_int(a.get("size"))), None)
    if real is None:
        lab.skip("Reader refused a Bakery attachment download", "no verified foreign attachment fixture")
    else:
        path = "/download-attachment/%d/%s" % (other_id, urllib.parse.quote(foreign_env, safe=""))
        params = {"content_hash": real["content_hash"]}
        control = lab.get(path, admin, params)
        oa = lab.get(path, reader, params)
        lab.check("Reader refused a Bakery attachment download",
                  control.status == 200 and len(control.body) == real["size"] and refused(oa),
                  "admin %s; reader %s" % (st(control), st(oa)))
    trav = lab.get("/message-content/%d/%s" % (own_id, urllib.parse.quote("../../accounts", safe="")), reader)
    lab.check("Path-like message ID refused", trav.status is not None and 400 <= trav.status < 500, st(trav))
    badhash = lab.get("/download-attachment/%d/%s" % (own_id, urllib.parse.quote(own_env, safe="")), reader,
                      {"content_hash": "not-a-hash"})
    lab.check("Unknown attachment hash refused", badhash.status is not None and 400 <= badhash.status < 500, st(badhash))
    remote = lab.get("/list-mailboxes/%d" % own_id, reader)
    lab.check("Mailbox listing works without remote=true", remote.status == 200, st(remote), required=False)

    lab.skip("Write-denial enforcement", "separate sacrificial-fixture procedure required", required=False)

    lab.check("No redirects on any API call", lab.redirects == 0, "%d redirects" % lab.redirects)
    lab.check("No connection errors", lab.connection_errors == 0, "%d errors" % lab.connection_errors)
    lab.check("Rate-limit headers seen (reported)", True,
              ", ".join(sorted(lab.headers_seen)) or "none", required=False)


def report(lab, out):
    print("\nBichon lab check v1 (paste this summary; it holds no keys, addresses or server text)", file=out)
    print("Python %s, %s" % (sys.version.split()[0], time.strftime("%Y-%m-%d %H:%M")), file=out)
    for status, required, name, detail in lab.results:
        print("[%s]%s %s%s" % (status, "" if required else " (optional)", name, (": " + detail) if detail else ""),
              file=out)
    tally = {s: sum(1 for r in lab.results if r[0] == s) for s in ("PASS", "FAIL", "SKIP")}
    missing = sum(1 for s, req, _, _ in lab.results if s == "SKIP" and req)
    print("%d passed, %d failed, %d skipped (%d of them required); %d requests" % (
        tally["PASS"], tally["FAIL"], tally["SKIP"], missing, lab.calls), file=out)
    ok = tally["FAIL"] == 0 and missing == 0 and tally["PASS"] > 0
    print("RESULT: %s" % ("all required checks passed" if ok else
                          "NOT PROVEN: a check failed or a required check could not run"), file=out)
    return ok


def ask_key(prompt, optional=False):
    """Read a token without echo; reject control characters from a bad paste."""
    for _ in range(3):
        key = getpass.getpass(prompt).strip()
        if not key and optional:
            return ""
        if key and all(33 <= ord(c) < 127 for c in key):
            return key
        print("  That did not look like a token (%d characters, %s). Paste with a right-click, or type it." % (
            len(key), "control characters" if key else "empty"))
    return None


def main(argv=None, keys=None, transport=None, out=None):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description="Bichon lab check (read-only).")
    parser.add_argument("url", help="Test server base URL, e.g. https://<host>:9443")
    parser.add_argument("--api-prefix", default="/api/v1")
    args = parser.parse_args(argv)
    try:
        parsed = urllib.parse.urlsplit(args.url)
        port = parsed.port
    except ValueError:
        print("Invalid HTTPS base address", file=out)
        return 2
    if parsed.scheme != "https" or not parsed.hostname or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username is not None or parsed.password is not None or (port is not None and not 1 <= port <= 65535):
        print("Use the HTTPS base address, for example https://<host>:9443", file=out)
        return 2
    if args.api_prefix != "/api/v1":
        print("Only the reviewed /api/v1 prefix is allowed", file=out)
        return 2
    if keys is None:
        keys = (ask_key("Admin token: "), ask_key("Reader token: "),
                ask_key("Revoked token (Enter to skip): ", optional=True),
                ask_key("Expired token, past its expiry date, never revoked (Enter to skip): ", optional=True))
    admin, reader = keys[0], keys[1]
    revoked = keys[2] if len(keys) > 2 else ""
    expired = keys[3] if len(keys) > 3 else ""
    if not admin or not reader:
        return 2
    if len({admin, reader} | ({revoked} if revoked else set()) | ({expired} if expired else set())) != \
            2 + bool(revoked) + bool(expired):
        print("Each token must be different. Use a separate revoked token and a separate expired token, "
              "or leave those prompts empty.", file=out)
        return 2
    lab = Lab(args.url, args.api_prefix, transport or urllib_transport)
    try:
        run_checks(lab, admin, reader, revoked, expired)
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, OverflowError):
        lab.check("Response contracts valid", False, "malformed response; no server values displayed")
    return 0 if report(lab, out) else 1


if __name__ == "__main__":
    sys.exit(main())
