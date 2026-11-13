"""Open Archiver lab check for MailBurrow (Phase 0, extended for Phase 3).

Runs read-only API checks against a TEST Open Archiver server that holds only
the fictional demo mail from tools/export_demo_eml.py, and prints a summary
that is safe to share. It never sends a request that changes server state
(GET only), always verifies certificates and never follows redirects.

Usage (PowerShell):
    python tools\\oa_lab_check.py https://<test-server>:8443 [--samples DIR] [--rate-limit]

It asks for up to four API keys without echoing them (on Windows, paste with
a right-click): the admin key, the reader key (custom read-only role on the
Alex Rivera demo source) and, optionally, a deleted key and an expired key.

Version 3 adds the Phase 3 contract checks: list items, search hits and the
opened-message response must have the fields and types MailBurrow's Open
Archiver backend reads, IDs and storage paths must pass its validation, and
every attachment in the reader's source must download at exactly its stated
size.

Every check is PASS, FAIL or SKIP and either required or optional. The run
succeeds (exit 0) only if no check failed and no required check was skipped.
The summary prints only statuses, counts, sizes, booleans and field or header
names from fixed allowlists: never text, addresses or values sent by the
server, so an error page cannot leak into a pasted summary.
"""
import argparse
import email
import re
import getpass
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email import policy
from pathlib import Path

TIMEOUT = 30

# Expected results, derived from assets/demo/archive.json (fictional demo mail).
# tools/test_oa_lab_check.py checks these constants against the fixtures.
EXPECT = {
    "reader_total": 40,            # Alex Rivera demo account
    "own_term": "clockwork",       # occurs in exactly one Alex message
    "own_term_subject": "The Corner Reader: June picks",
    "other_term": "wholesale",     # only in Maple Street Bakery mail, attachments included
    "attachment_term": "yogurt",   # inside lemon-cake-recipe.txt
    "attachment_term_subject": "Recipe you asked for",
    "filter_subjects": [           # Alex messages with attachments sent in 2026
        "Re: Sunday dinner?",
        "Your trip to Harbor City",
        "Your Maple Street Bakery receipt",
        "October statement available",
        "Recipe you asked for",
    ],
}

# Names that may appear in the summary; anything else is only counted.
KNOWN_FIELDS = {
    "id", "subject", "senderEmail", "senderName", "recipients", "sentAt", "archivedAt",
    "hasAttachments", "ingestionSourceId", "ingestionSource", "path", "sizeBytes",
    "storagePath", "storageHashSha256", "threadId", "thread", "userEmail", "tags",
    "isIndexed", "indexAttempts", "isJournaled", "isOnLegalHold", "messageIdHeader",
    "providerMessageId", "raw", "attachments", "items", "total", "page", "limit",
    "totalPages", "hits", "processingTimeMs", "message", "status", "statusCode", "errors",
    "_formatted", "_matchesPosition", "bcc", "cc", "body", "from", "fromDomain",
    "fromLocalPart", "fromName", "recipientDomains", "recipientLocalParts", "timestamp",
    "to", "userEmailDomain", "userEmailLocalPart", "filename", "content", "mimeType",
    "preserveOriginalFile", "name", "provider",
}
# MailBurrow's Open Archiver backend rules (lib/open_archiver_api.dart).
APP_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
APP_MAX_WIRE = 40 * 1024 * 1024
APP_MAX_RAW = 10 * 1024 * 1024
APP_MAX_ATTACHMENT = 50 * 1024 * 1024
MAX_SIZE_DOWNLOADS = 12

KNOWN_HEADERS = {"ratelimit-limit", "ratelimit-policy", "ratelimit-remaining",
                 "ratelimit-reset", "retry-after", "x-ratelimit-limit",
                 "x-ratelimit-remaining", "x-ratelimit-reset"}


# ---------------------------------------------------------------- transport

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx comes back as an HTTPError and is counted


def urllib_transport(url, headers):
    """GET url; return (status, headers with lower-case names, body bytes)."""
    opener = urllib.request.build_opener(
        NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        resp = opener.open(req, timeout=TIMEOUT)
        return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, {k.lower(): v for k, v in err.headers.items()}, err.read()


class Response:
    def __init__(self, status, headers, body, ms):
        self.status, self.headers, self.body, self.ms = status, headers, body, ms
        try:
            self.json = json.loads(body) if body else None
        except (ValueError, UnicodeDecodeError):
            self.json = None

    def obj(self):
        return self.json if isinstance(self.json, dict) else None


class Lab:
    def __init__(self, base, prefix, transport):
        self.base, self.prefix, self.transport = base.rstrip("/"), prefix, transport
        self.results = []          # (status, required, name, detail)
        self.redirects = 0
        self.connection_errors = 0
        self.headers_seen = set()

    def get(self, path, key=None, params=None, extra=None):
        url = self.base + self.prefix + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {"Accept": "application/json", "User-Agent": "MailBurrow-lab-check/3"}
        headers.update(extra or {})
        if key:
            headers["X-API-KEY"] = key
        start = time.monotonic()
        try:
            status, resp_headers, body = self.transport(url, headers)
        except Exception:  # connection, TLS or timeout: report the category only
            self.connection_errors += 1
            return Response(None, {}, b"", 0)
        if 300 <= status < 400:
            self.redirects += 1
        self.headers_seen.update(h for h in resp_headers if h in KNOWN_HEADERS)
        return Response(status, resp_headers, body, int((time.monotonic() - start) * 1000))

    def record(self, status, required, name, detail=""):
        self.results.append((status, required, name, detail))

    def check(self, name, ok, detail="", required=True):
        self.record("PASS" if ok else "FAIL", required, name, detail)
        return ok

    def skip(self, name, reason, required=True):
        self.record("SKIP", required, name, reason)


# ---------------------------------------------------------------- safe output

def names(keys):
    keys = sorted(set(str(k) for k in keys))
    shown = [k for k in keys if k in KNOWN_FIELDS]
    other = len(keys) - len(shown)
    if not keys:
        return "none"
    return ", ".join(shown) + (" (+%d other)" % other if other else "")


def kind(resp):
    """Body category and allowlisted JSON field names; never server text."""
    if resp.status is None:
        return "no response"
    ctype = (resp.headers.get("content-type") or "").split(";")[0].strip().lower()
    category = {"application/json": "json", "text/html": "html", "text/plain": "text"}.get(
        ctype, "other" if ctype else "none")
    if isinstance(resp.json, dict):
        return "%s {%s}" % (category, names(resp.json.keys()))
    if isinstance(resp.json, list):
        return "%s list" % category
    return category if resp.body else "empty"


def st(resp):
    return "status %s" % (resp.status if resp.status is not None else "none (connection error)")


def count(value):
    return str(len(value)) if isinstance(value, list) else "malformed"


def number(value):
    return str(value) if isinstance(value, int) and not isinstance(value, bool) else "none"


# ---------------------------------------------------------------- MIME helpers

def raw_bytes(detail):
    raw = detail.get("raw") if isinstance(detail, dict) else None
    if isinstance(raw, dict) and raw.get("type") == "Buffer" and isinstance(raw.get("data"), list):
        try:
            return bytes(raw["data"]), "Buffer JSON array"
        except (TypeError, ValueError):
            return b"", "malformed Buffer"
    if isinstance(raw, str):
        return raw.encode("utf-8", "replace"), "string"
    return b"", "missing" if raw is None else "unexpected type"


def mime_payloads(raw):
    """Count leaf payloads in a message by role: {role: [parts, bytes]}.

    attachment: Content-Disposition attachment, or a named part not marked inline.
    inline: any other non-text part, named text part or part with a Content-ID
    (inline images and resources referenced by cid:).
    Plain message bodies (unnamed text/plain or text/html) are not counted.
    """
    counts = {"attachment": [0, 0], "inline": [0, 0]}
    if not raw:
        return counts
    msg = email.message_from_bytes(raw, policy=policy.default)
    for part in msg.walk():
        if part.is_multipart():
            continue
        disposition = (part.get_content_disposition() or "").lower()
        payload = part.get_payload(decode=True) or b""
        if disposition == "attachment" or (part.get_filename() and disposition != "inline"):
            role = "attachment"
        elif part.get_content_maintype() != "text" or part.get_filename() or part.get("Content-ID"):
            role = "inline"
        else:
            continue
        counts[role][0] += 1
        counts[role][1] += len(payload)
    return counts


def year_of(timestamp):
    if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool):
        return None
    seconds = timestamp / 1000 if timestamp > 1e11 else timestamp
    return time.gmtime(seconds).tm_year


def dicts(value):
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


# ---------------------------------------------------------------- app contract

def text_or_none(value):
    return value is None or isinstance(value, str)


def whole(value, minimum=0):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def iso_date(value):
    if not isinstance(value, str):
        return False
    try:
        from datetime import datetime
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def app_id(value):
    return isinstance(value, str) and bool(APP_ID.match(value))


def storage_path_ok(value):
    return (isinstance(value, str) and 0 < len(value) <= 1024
            and not any(ord(c) < 0x20 or ord(c) == 0x7f for c in value))


def missing(record, fields):
    return ["missing " + f for f in fields if f not in record]


def list_item_problems(item):
    """Field names, never values, that break MailBurrow's list-item rules."""
    bad = ([] if app_id(item.get("id")) else ["id"]) + missing(item, ("subject", "senderEmail", "sentAt"))
    bad += [f for f in ("subject", "senderName", "senderEmail") if not text_or_none(item.get(f))]
    if item.get("sentAt") is not None and not iso_date(item.get("sentAt")):
        bad.append("sentAt")
    return bad


def search_hit_problems(hit):
    bad = ([] if app_id(hit.get("id")) else ["id"]) + missing(hit, ("subject", "from", "timestamp"))
    bad += [f for f in ("subject", "from", "fromName") if not text_or_none(hit.get(f))]
    if hit.get("timestamp") is not None and not whole(hit.get("timestamp"), -10 ** 13):
        bad.append("timestamp")
    return bad


def attachment_problems(record):
    bad = [] if app_id(record.get("id")) else ["id"]
    bad += [f for f in ("filename", "mimeType") if not text_or_none(record.get(f))]
    if not whole(record.get("sizeBytes")):
        bad.append("sizeBytes")
    if not storage_path_ok(record.get("storagePath")):
        bad.append("storagePath")
    return bad


def detail_problems(detail, source):
    bad = missing(detail, ("subject", "senderEmail", "sentAt", "raw", "attachments"))
    bad += [f for f in ("subject", "senderName", "senderEmail", "path") if not text_or_none(detail.get(f))]
    if detail.get("sentAt") is not None and not iso_date(detail.get("sentAt")):
        bad.append("sentAt")
    if detail.get("ingestionSourceId") not in (None, source):
        bad.append("ingestionSourceId")
    raw = detail.get("raw")
    if not (isinstance(raw, dict) and raw.get("type") == "Buffer" and isinstance(raw.get("data"), list)):
        bad.append("raw")
    records = detail.get("attachments")
    if records is not None and not isinstance(records, list):
        bad.append("attachments")
    for record in dicts(records):
        bad += ["attachments." + f for f in attachment_problems(record)]
    return sorted(set(bad))


def paging_problems(data, hits_field):
    if not isinstance(data, dict) or not isinstance(data.get(hits_field), list):
        return [hits_field]
    bad = [] if whole(data.get("total")) else ["total"]
    for field in ("page", "limit"):
        if data.get(field) is not None and not whole(data.get(field), 1):
            bad.append(field)
    if data.get("totalPages") is not None and not whole(data.get("totalPages")):
        bad.append("totalPages")
    return bad


# ---------------------------------------------------------------- the checks

def run_checks(lab, admin, reader, deleted, rate_limit=False, samples=None, expired=""):
    def save(name, data):
        if samples is not None and data is not None:
            (samples / (name + ".json")).write_text(json.dumps(data, indent=2), encoding="utf-8")

    def items_of(resp):
        data = resp.obj()
        return data.get("items") if data and isinstance(data.get("items"), list) else None

    def hits_of(resp):
        data = resp.obj()
        return data.get("hits") if data and isinstance(data.get("hits"), list) else None

    def total_of(resp):
        data = resp.obj()
        return data.get("total") if data else None

    # Sign-in and base path
    adm_src = lab.get("/ingestion-sources", admin)
    if not lab.check("API reachable with admin key", adm_src.status == 200 and isinstance(adm_src.json, list),
                     "%s, %s" % (st(adm_src), kind(adm_src))):
        return
    nokey = lab.get("/ingestion-sources")
    lab.check("Request without a key refused", nokey.status == 401, "%s, %s" % (st(nokey), kind(nokey)))
    if deleted:
        for path, params in (("/ingestion-sources", None), ("/search", {"keywords": "a"})):
            r = lab.get(path, deleted, params)
            lab.check("Deleted key refused on " + path, r.status == 401, "%s, %s" % (st(r), kind(r)),
                      required=False)
    else:
        lab.skip("Deleted key refused", "no deleted key given", required=False)
    if expired:
        for path, params in (("/ingestion-sources", None), ("/search", {"keywords": "a"})):
            r = lab.get(path, expired, params)
            lab.check("Expired key refused on " + path, r.status == 401, "%s, %s" % (st(r), kind(r)),
                      required=False)
    else:
        lab.skip("Expired key refused", "no expired key given", required=False)

    # Sources
    admin_sources = [s for s in dicts(adm_src.json) if isinstance(s.get("id"), str)]
    rd_src = lab.get("/ingestion-sources", reader)
    reader_sources = [s for s in dicts(rd_src.json) if isinstance(s.get("id"), str)]
    save("ingestion-sources-reader", rd_src.json)
    lab.check("Admin sees at least 3 sources", len(admin_sources) >= 3, "%d sources" % len(admin_sources))
    if not lab.check("Reader sees exactly 1 source", rd_src.status == 200 and len(reader_sources) == 1,
                     "%s, %d sources" % (st(rd_src), len(reader_sources))):
        return
    flags = [s.get("preserveOriginalFile") for s in admin_sources]
    lab.check("Every source states preserveOriginalFile", all(isinstance(f, bool) for f in flags),
              "%d true, %d false, %d missing" % (flags.count(True), flags.count(False),
                                                 sum(not isinstance(f, bool) for f in flags)))
    src_a = reader_sources[0]["id"]
    others = [s for s in admin_sources if s["id"] != src_a and s.get("preserveOriginalFile") is not True]
    preserve = [s["id"] for s in admin_sources if s.get("preserveOriginalFile") is True]

    # Browse own source: every page, expected total, only own source
    first = lab.get("/archived-emails/ingestion-source/" + src_a, reader, {"page": 1, "limit": 10})
    save("archived-emails-list-reader-a", first.json)
    total = total_of(first)
    seen, foreign, pages_ok, att_email = set(), 0, items_of(first) is not None, None
    all_items, att_emails, paging_bad = [], [], set()
    page_resp = first
    for page in range(1, 11):
        if page > 1:
            page_resp = lab.get("/archived-emails/ingestion-source/" + src_a, reader, {"page": page, "limit": 10})
        items = items_of(page_resp)
        if items is None:
            pages_ok = False
            break
        paging_bad.update(paging_problems(page_resp.obj(), "items"))
        all_items.extend(dicts(items))
        for it in dicts(items):
            if it.get("hasAttachments") is True and it.get("id") not in att_emails:
                att_emails.append(it.get("id"))
            seen.add(it.get("id"))
            foreign += it.get("ingestionSourceId") != src_a
            if att_email is None and it.get("hasAttachments") is True:
                att_email = it.get("id")
        if len(items) < 10:
            break
    lab.check("Reader browses own source completely",
              pages_ok and total == EXPECT["reader_total"] and len(seen) == EXPECT["reader_total"] and not foreign,
              "%s, total %s (expected %d), %d distinct across pages, %d from other sources" % (
                  st(first), number(total), EXPECT["reader_total"], len(seen), foreign))
    if dicts(items_of(first)):
        lab.check("List item fields", True, names(dicts(items_of(first))[0].keys()))
    item_bad = sorted({f for it in all_items for f in list_item_problems(it)} | paging_bad)
    lab.check("List items match the app's rules", bool(all_items) and not item_bad,
              "%d items checked; problems: %s" % (len(all_items), ", ".join(item_bad) or "none"))

    # Other source: admin finds fixtures first, then the reader tries them
    src_b = None
    if not others:
        for name in ("Reader refused other source's listing", "Reader refused other source's email",
                     "Reader refused other source's attachment"):
            lab.skip(name, "no second non-preserve source on the server")
    else:
        src_b = others[0]["id"]
        b_email = b_att_path = None
        for page in range(1, 6):
            r = lab.get("/archived-emails/ingestion-source/" + src_b, admin, {"page": page, "limit": 25})
            items = dicts(items_of(r))
            for it in items:
                if b_email is None:
                    b_email = it.get("id")
                if it.get("hasAttachments") is True and b_att_path is None:
                    d = lab.get("/archived-emails/" + str(it.get("id")), admin).obj() or {}
                    atts = [a for a in dicts(d.get("attachments")) if a.get("storagePath")]
                    if atts:
                        b_att_path = atts[0]["storagePath"]
            if (b_email and b_att_path) or len(items) < 25:
                break
        rb = lab.get("/archived-emails/ingestion-source/" + src_b, reader, {"page": 1, "limit": 25})
        rb_items, rb_total = items_of(rb), total_of(rb)
        lab.check("Reader refused other source's listing",
                  rb.status in (403, 404) or (rb.status == 200 and rb_items == [] and rb_total in (0, None)),
                  "%s, %s items, total %s" % (st(rb), count(rb_items), number(rb_total)))
        if b_email:
            rv = lab.get("/archived-emails/" + str(b_email), reader)
            leaked = bool(rv.obj() and ("raw" in rv.obj() or "subject" in rv.obj()))
            lab.check("Reader refused other source's email", rv.status in (403, 404) and not leaked,
                      "%s, %s" % (st(rv), kind(rv)))
        else:
            lab.skip("Reader refused other source's email", "admin found no email in the other source")
        if b_att_path:
            rd = lab.get("/storage/download", reader, {"path": b_att_path})
            lab.check("Reader refused other source's attachment", rd.status in (403, 404), st(rd))
        else:
            lab.skip("Reader refused other source's attachment", "admin found no attachment in the other source")
    for label, bogus in (("traversal", "../../../../etc/passwd"), ("missing file", "does/not/exist.eml")):
        r = lab.get("/storage/download", reader, {"path": bogus})
        lab.check("Arbitrary storage path refused (%s)" % label, r.status in (400, 403, 404), st(r))

    # Own message and attachment
    if not att_email:
        for name in ("Reader opens own email", "raw has no attachment parts", "Reader downloads own attachment"):
            lab.skip(name, "no email with attachments found in the reader's source")
    else:
        op = lab.get("/archived-emails/" + str(att_email), reader)
        detail = op.obj() or {}
        raw, raw_kind = raw_bytes(detail)
        atts = dicts(detail.get("attachments"))
        lab.check("Reader opens own email", op.status == 200 and bool(raw),
                  "%s, raw %s, .eml %d bytes, response %d bytes (x%.1f), %d ms" % (
                      st(op), raw_kind, len(raw), len(op.body), len(op.body) / len(raw) if raw else 0, op.ms))
        payloads = mime_payloads(raw)
        lab.check("raw has no attachment parts", bool(raw) and payloads["attachment"][0] == 0,
                  "%d attachment parts, %d bytes; %d attachment records" % (
                      payloads["attachment"][0], payloads["attachment"][1], len(atts)))
        lab.check("Inline binary payload in raw (reported; counts toward the size cap)", bool(raw),
                  "%d inline parts, %d bytes" % tuple(payloads["inline"]))
        if detail:
            lab.check("Detail fields", True, names(detail.keys()))
        bad = detail_problems(detail, src_a) if detail else ["response"]
        lab.check("Opened message matches the app's rules", op.status == 200 and not bad,
                  "problems: %s" % (", ".join(bad) or "none"))
        lab.check("Opened message within the app's size limits",
                  op.status == 200 and len(op.body) <= APP_MAX_WIRE and len(raw) <= APP_MAX_RAW,
                  "response %d bytes (limit %d), .eml %d bytes (limit %d)" % (
                      len(op.body), APP_MAX_WIRE, len(raw), APP_MAX_RAW))
        lab.check("Opened-message response headers (reported)", op.status == 200,
                  "Content-Length %s" % ("yes" if op.headers.get("content-length") else "no"), required=False)
        gz = lab.get("/archived-emails/" + str(att_email), reader, extra={"Accept-Encoding": "gzip"})
        lab.check("Opened message with compression accepted (reported)", gz.status == 200,
                  "%s, Content-Encoding %s, Content-Length %s" % (
                      st(gz), "gzip" if (gz.headers.get("content-encoding") or "").lower() == "gzip"
                      else ("other" if gz.headers.get("content-encoding") else "none"),
                      "yes" if gz.headers.get("content-length") else "no"), required=False)
        if samples is not None and detail:
            trimmed = dict(detail)
            trimmed["raw"] = {"type": "Buffer", "data": "<%d bytes omitted>" % len(raw)}
            save("archived-email-detail-reader-a", trimmed)
            if raw:
                (samples / "archived-email-raw-a.eml").write_bytes(raw)
        downloadable = [a for a in atts if a.get("storagePath") and isinstance(a.get("sizeBytes"), int)]
        if downloadable:
            a = downloadable[0]
            dl = lab.get("/storage/download", reader, {"path": a["storagePath"]})
            lab.check("Reader downloads own attachment", dl.status == 200 and len(dl.body) == a["sizeBytes"],
                      "%s, %d bytes (record %d), Content-Disposition %s, Content-Length %s" % (
                          st(dl), len(dl.body), a["sizeBytes"],
                          "yes" if dl.headers.get("content-disposition") else "no",
                          "yes" if dl.headers.get("content-length") else "no (streamed)"))
        else:
            lab.skip("Reader downloads own attachment", "email lists no downloadable attachment record")

    # Every attachment in the reader's source downloads at exactly its stated size
    checked = mismatched = unsafe = 0
    for eid in att_emails:
        if checked >= MAX_SIZE_DOWNLOADS:
            break
        d = lab.get("/archived-emails/" + str(eid), reader).obj() or {}
        for record in dicts(d.get("attachments")):
            if checked >= MAX_SIZE_DOWNLOADS:
                break
            if attachment_problems(record) or record.get("sizeBytes") > APP_MAX_ATTACHMENT:
                unsafe += 1
                continue
            dl = lab.get("/storage/download", reader, {"path": record["storagePath"]})
            checked += 1
            mismatched += dl.status != 200 or len(dl.body) != record["sizeBytes"]
    if att_emails:
        lab.check("Every checked attachment matches its stated size",
                  checked > 0 and mismatched == 0 and unsafe == 0,
                  "%d downloaded (at most %d), %d mismatched or failed, %d records outside the app's rules" % (
                      checked, MAX_SIZE_DOWNLOADS, mismatched, unsafe))
    else:
        lab.skip("Every checked attachment matches its stated size", "no email with attachments found")

    # Search: positive controls, isolation, filters, pagination
    own = lab.get("/search", reader, {"keywords": EXPECT["own_term"], "limit": 25})
    own_hits = dicts(hits_of(own))
    known = any(h.get("subject") == EXPECT["own_term_subject"] for h in own_hits)
    lab.check("Reader search finds a known own message",
              own.status == 200 and hits_of(own) is not None and known
              and all(h.get("ingestionSourceId") == src_a for h in own_hits),
              "%s, %s hits, known message %s" % (st(own), count(hits_of(own)), "found" if known else "missing"))
    control = lab.get("/search", admin, {"keywords": EXPECT["other_term"], "limit": 25})
    control_hits = dicts(hits_of(control))
    blocked = lab.get("/search", reader, {"keywords": EXPECT["other_term"], "limit": 25})
    b_hits, b_total = hits_of(blocked), total_of(blocked)
    b_foreign = sum(1 for h in dicts(b_hits) if h.get("ingestionSourceId") != src_a)
    if any(h.get("ingestionSourceId") != src_a for h in control_hits):
        # Hits from the reader's own source are allowed (a term can also occur in its own
        # mail or attachment text); any hit, or any count, from another source is a leak.
        lab.check("Reader search cannot find another source's term",
                  blocked.status == 403 or (blocked.status == 200 and b_hits is not None and b_foreign == 0
                                            and b_total in (len(b_hits), None)),
                  "admin control %d hits; reader %s, %s hits (%d from other sources), total %s" % (
                      len(control_hits), st(blocked), count(b_hits), b_foreign, number(b_total)))
    else:
        lab.skip("Reader search cannot find another source's term",
                 "admin control search found nothing (%s)" % st(control))
    if src_b:
        fb = lab.get("/search", reader, {"sources": src_b, "limit": 25})
        fb_hits, fb_total = hits_of(fb), total_of(fb)
        lab.check("Reader filter-search on other source returns nothing",
                  fb.status == 403 or (fb.status == 200 and fb_hits == [] and fb_total in (0, None)),
                  "%s, %s hits, total %s" % (st(fb), count(fb_hits), number(fb_total)))
    else:
        lab.skip("Reader filter-search on other source returns nothing", "no second non-preserve source")
    at = lab.get("/search", reader, {"keywords": EXPECT["attachment_term"], "searchIn": "attachment_content",
                                     "limit": 10})
    at_hits = dicts(hits_of(at))
    match = [h for h in at_hits if h.get("subject") == EXPECT["attachment_term_subject"]]
    carries = any(EXPECT["attachment_term"] in str(a.get("content") or "").lower()
                  for h in match for a in dicts(h.get("attachments")))
    lab.check("Attachment-text search finds the known attachment",
              at.status == 200 and bool(match) and all(h.get("ingestionSourceId") == src_a for h in at_hits),
              "%s, %d hits, known message %s, hit carries attachment text: %s" % (
                  st(at), len(at_hits), "found" if match else "missing", "yes" if carries else "no"))
    ff = lab.get("/search", reader, {"sources": src_a, "hasAttachments": "true", "dateFrom": "2026-01-01",
                                     "dateTo": "2026-12-31", "limit": 25})
    ff_hits, ff_total = dicts(hits_of(ff)), total_of(ff)
    subjects_ok = sorted(str(h.get("subject")) for h in ff_hits) == sorted(EXPECT["filter_subjects"])
    lab.check("Filter-only search returns exactly the expected messages",
              ff.status == 200 and subjects_ok and ff_total == len(EXPECT["filter_subjects"])
              and len({h.get("id") for h in ff_hits}) == len(ff_hits)
              and all(h.get("hasAttachments") is True and h.get("ingestionSourceId") == src_a
                      and year_of(h.get("timestamp")) == 2026 for h in ff_hits),
              "%s, %d hits (expected %d), total %s, subjects %s" % (
                  st(ff), len(ff_hits), len(EXPECT["filter_subjects"]), number(ff_total),
                  "match" if subjects_ok else "differ"))
    p1 = lab.get("/search", reader, {"sources": src_a, "limit": 10, "page": 1, "sort": "date_desc"})
    p2 = lab.get("/search", reader, {"sources": src_a, "limit": 10, "page": 2, "sort": "date_desc"})
    pages = []
    for resp in (p1, p2):
        raw_hits = hits_of(resp)
        valid = (resp.status == 200 and raw_hits is not None and len(dicts(raw_hits)) == len(raw_hits)
                 and all(isinstance(h.get("id"), str) and h.get("id") for h in raw_hits))
        ids = [h.get("id") for h in dicts(raw_hits)]
        pages.append({
            "valid": valid, "ids": ids, "unique": len(set(ids)) == len(ids),
            "foreign": sum(1 for h in dicts(raw_hits) if h.get("ingestionSourceId") != src_a),
            "total": total_of(resp),
        })
    h1, h2 = pages[0]["ids"], pages[1]["ids"]
    overlap = len(set(h1) & set(h2))
    lab.check("Search pages are distinct, own-source only and totals match",
              all(pg["valid"] and pg["unique"] and pg["foreign"] == 0 and len(pg["ids"]) == 10
                  and pg["total"] == EXPECT["reader_total"] for pg in pages) and overlap == 0,
              "page 1 %d hits (%d from other sources, %s), page 2 %d hits (%d from other sources, %s), "
              "%d overlap, totals %s/%s (expected %d)" % (
                  len(h1), pages[0]["foreign"], "valid" if pages[0]["valid"] and pages[0]["unique"] else "invalid",
                  len(h2), pages[1]["foreign"], "valid" if pages[1]["valid"] and pages[1]["unique"] else "invalid",
                  overlap, number(pages[0]["total"]), number(pages[1]["total"]), EXPECT["reader_total"]))
    if h1:
        lab.check("Search page size", True, "%d bytes for %d hits; hit fields: %s" % (
            len(p1.body), len(h1), names(dicts(hits_of(p1))[0].keys())))
        save("search-reader", p1.json)
    search_hits = dicts(hits_of(p1)) + dicts(hits_of(p2)) + dicts(hits_of(ff))
    hit_bad = sorted({f for h in search_hits for f in search_hit_problems(h)}
                     | set(paging_problems(p1.obj(), "hits")) | set(paging_problems(p2.obj(), "hits")))
    lab.check("Search hits match the app's rules", bool(search_hits) and not hit_bad,
              "%d hits checked; problems: %s" % (len(search_hits), ", ".join(hit_bad) or "none"))

    # Totals
    stats = lab.get("/dashboard/stats", reader)
    lab.check("Reader gets no server-wide totals", stats.status in (401, 403), "%s, %s" % (st(stats), kind(stats)))

    # Preserve-original sources (optional fixture)
    if not preserve:
        lab.skip("Preserve-original source", "no source with Preserve Original File on the server", required=False)
    for psrc in preserve:
        r = lab.get("/archived-emails/ingestion-source/" + psrc, admin, {"page": 1, "limit": 25})
        pid = next((it.get("id") for it in dicts(items_of(r)) if it.get("hasAttachments") is True), None)
        if not pid:
            lab.skip("Preserve-original source", "it has no email with attachments", required=False)
            continue
        pd = lab.get("/archived-emails/" + str(pid), admin).obj() or {}
        praw, _ = raw_bytes(pd)
        pp = mime_payloads(praw)
        lab.check("Preserve-original source keeps attachments inside raw", pp["attachment"][0] > 0,
                  "%d attachment parts, %d bytes inside raw; %d attachment records" % (
                      pp["attachment"][0], pp["attachment"][1], len(dicts(pd.get("attachments")))),
                  required=False)
        rp = lab.get("/archived-emails/" + str(pid), reader)
        lab.check("Reader refused preserve-original source's email", rp.status in (403, 404), st(rp),
                  required=False)

    # Rate limit (optional, slow)
    if rate_limit:
        hit_at = retry = None
        for i in range(110):
            r = lab.get("/ingestion-sources", reader)
            if r.status == 429:
                hit_at = i + 1
                value = str(r.headers.get("retry-after", ""))
                retry = value if value.isdigit() else ("present" if value else "absent")
                break
        lab.check("Rate limit answers 429", hit_at is not None,
                  ("after %d requests, Retry-After %s" % (hit_at, retry)) if hit_at else "no 429 in 110 requests",
                  required=False)
    else:
        lab.skip("Rate limit answers 429", "not requested (--rate-limit)", required=False)

    lab.check("No redirects on any API call", lab.redirects == 0, "%d redirects" % lab.redirects)
    lab.check("No connection errors", lab.connection_errors == 0, "%d errors" % lab.connection_errors)
    lab.check("Rate-limit headers seen", bool(lab.headers_seen),
              ", ".join(sorted(lab.headers_seen)) or "none", required=False)


def report(lab, out):
    print("\nOpen Archiver lab check v3 (paste this summary; it holds no keys, addresses or server text)", file=out)
    print("Python %s, %s" % (sys.version.split()[0], time.strftime("%Y-%m-%d %H:%M")), file=out)
    for status, required, name, detail in lab.results:
        print("[%s]%s %s%s" % (status, "" if required else " (optional)", name, (": " + detail) if detail else ""),
              file=out)
    tally = {s: sum(1 for r in lab.results if r[0] == s) for s in ("PASS", "FAIL", "SKIP")}
    missing = sum(1 for s, req, _, _ in lab.results if s == "SKIP" and req)
    print("%d passed, %d failed, %d skipped (%d of them required)" % (
        tally["PASS"], tally["FAIL"], tally["SKIP"], missing), file=out)
    ok = tally["FAIL"] == 0 and missing == 0 and tally["PASS"] > 0
    print("RESULT: %s" % ("all required checks passed" if ok else
                          "NOT PROVEN: a check failed or a required check could not run"), file=out)
    return ok


def ask_key(prompt, optional=False):
    """Read a key without echo; reject control characters from a bad paste."""
    for _ in range(3):
        key = getpass.getpass(prompt).strip()
        if not key and optional:
            return ""
        if key and all(33 <= ord(c) < 127 for c in key):
            return key
        print("  That did not look like a key (%d characters, %s). Paste with a right-click, or type it." % (
            len(key), "control characters" if key else "empty"))
    return None


def main(argv=None, keys=None, transport=None, out=None):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description="Open Archiver lab check (read-only).")
    parser.add_argument("url", help="Test server base URL, e.g. https://<host>:8443")
    parser.add_argument("--api-prefix", default="/api/v1")
    parser.add_argument("--samples", help="Folder for fictional sample responses (review before committing)")
    parser.add_argument("--rate-limit", action="store_true", help="Also send up to 110 requests to observe 429")
    args = parser.parse_args(argv)
    if not args.url.startswith("https://"):
        print("Use the HTTPS address.", file=out)
        return 2
    if keys is None:
        keys = (ask_key("Admin API key: "), ask_key("Reader API key: "),
                ask_key("Deleted key (Enter to skip): ", optional=True),
                ask_key("Expired key (Enter to skip): ", optional=True))
    admin, reader, deleted = keys[:3]
    expired = keys[3] if len(keys) > 3 else ""
    if not admin or not reader:
        return 2
    samples = Path(args.samples) if args.samples else None
    if samples is not None:
        samples.mkdir(parents=True, exist_ok=True)
    lab = Lab(args.url, args.api_prefix, transport or urllib_transport)
    run_checks(lab, admin, reader, deleted, args.rate_limit, samples, expired)
    return 0 if report(lab, out) else 1


if __name__ == "__main__":
    sys.exit(main())
