"""Open Archiver lab check for MailBurrow (Phase 0).

Runs read-only API checks against a TEST Open Archiver server that holds
only fictional demo mail, and prints a summary that is safe to share: no
keys, no server address, no message content. It never sends a request that
changes server state (only GET).

Usage (PowerShell):
    python tools\\oa_lab_check.py https://<test-server>:8443

You are asked for three API keys (input is hidden): the admin key, the
reader key (custom read-only role on one source), and the deleted
"revoke-test" key. Optional: --samples <folder> saves fictional sample
responses for test fixtures (raw message bytes are truncated).

Standard library only. Certificates are always verified and redirects are
never followed.
"""
import argparse
import email
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx is returned as an error and recorded


OPENER = urllib.request.build_opener(
    NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))


class Lab:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.results = []
        self.redirects = 0
        self.ratelimit_headers = set()

    def get(self, path, key=None, params=None, read_body=True):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, method="GET")
        if key:
            req.add_header("X-API-KEY", key)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "MailBurrow-lab-check/1")
        start = time.monotonic()
        try:
            resp = OPENER.open(req, timeout=TIMEOUT)
            status, headers = resp.status, resp.headers
            body = resp.read() if read_body else b""
        except urllib.error.HTTPError as err:
            status, headers = err.code, err.headers
            body = err.read() if read_body else b""
        except urllib.error.URLError as err:
            return {"status": None, "error": type(err.reason).__name__, "headers": {}, "body": b"", "json": None}
        if 300 <= status < 400:
            self.redirects += 1
        for name in headers.keys():
            if name.lower().startswith(("ratelimit", "x-ratelimit", "retry-after")):
                self.ratelimit_headers.add(name)
        parsed = None
        if body:
            try:
                parsed = json.loads(body)
            except ValueError:
                parsed = None
        return {"status": status, "headers": headers, "body": body, "json": parsed,
                "ms": int((time.monotonic() - start) * 1000)}

    def check(self, name, ok, detail=""):
        self.results.append((name, ok, detail))


def error_shape(resp):
    data = resp.get("json")
    if isinstance(data, dict):
        return "{" + ", ".join(sorted(data.keys())) + "}"
    return "non-JSON" if resp.get("body") else "empty"


def short_message(resp):
    data = resp.get("json")
    if isinstance(data, dict) and isinstance(data.get("message"), str):
        return data["message"][:120]
    text = (resp.get("body") or b"")[:120].decode("utf-8", "replace")
    return " ".join(text.split()) or "none"


def raw_bytes(email_json):
    raw = email_json.get("raw")
    if isinstance(raw, dict) and raw.get("type") == "Buffer" and isinstance(raw.get("data"), list):
        return bytes(raw["data"]), "Buffer JSON array"
    if isinstance(raw, str):
        return raw.encode("utf-8", "replace"), "string"
    return b"", type(raw).__name__


def attachment_parts(raw):
    if not raw:
        return 0, 0
    msg = email.message_from_bytes(raw, policy=policy.default)
    count = size = 0
    for part in msg.walk():
        if part.is_multipart():
            continue
        disposition = (part.get_content_disposition() or "").lower()
        if disposition == "attachment" or (part.get_filename() and disposition != "inline"):
            payload = part.get_payload(decode=True) or b""
            count += 1
            size += len(payload)
    return count, size


def ask_key(prompt, optional=False):
    """Read a key without echo and reject pasted control characters.

    On Windows, Ctrl+V in a hidden prompt can insert a control character instead of
    pasting; the server then answers 400. Right-click pastes correctly.
    """
    for _ in range(3):
        key = getpass.getpass(prompt).strip()
        if not key and optional:
            return ""
        if key and all(33 <= ord(c) < 127 for c in key):
            return key
        print("  That did not look like a key (%d characters, %s). Paste it with a right-click, "
              "or type it, then press Enter." % (
                  len(key), "contains control characters" if key else "empty"))
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Open Archiver lab check (read-only).")
    parser.add_argument("url", help="Test server base URL, e.g. https://<host>:8443")
    parser.add_argument("--api-prefix", default="/api/v1", help="API path prefix (default /api/v1)")
    parser.add_argument("--samples", help="Folder to save fictional sample responses")
    parser.add_argument("--rate-limit", action="store_true",
                        help="Also send up to 110 quick requests to observe the 429 response")
    args = parser.parse_args(argv)
    if not args.url.startswith("https://"):
        print("Use the HTTPS address.")
        return 2

    admin = ask_key("Admin API key: ")
    reader = ask_key("Reader API key: ")
    revoked = ask_key("Deleted revoke-test key (Enter to skip): ", optional=True)
    if not admin or not reader:
        return 2

    lab = Lab(args.url)
    p = args.api_prefix
    samples = Path(args.samples) if args.samples else None
    if samples:
        samples.mkdir(parents=True, exist_ok=True)

    def save(name, data):
        if samples and data is not None:
            (samples / (name + ".json")).write_text(json.dumps(data, indent=2), encoding="utf-8")

    # 1. Base path and sign-in
    r_admin_src = lab.get(p + "/ingestion-sources", admin)
    lab.check("API reachable at " + p + " with admin key", r_admin_src["status"] == 200,
              "status %s" % r_admin_src["status"])
    if r_admin_src["status"] != 200:
        lab.check("Diagnostics", False, "server %s, content type %s, body shape %s, message %s" % (
            r_admin_src["headers"].get("Server"), r_admin_src["headers"].get("Content-Type"),
            error_shape(r_admin_src), short_message(r_admin_src)))
        alt = lab.get("/v1/ingestion-sources", admin)
        lab.check("Alternative path /v1 works instead", alt["status"] == 200, "status %s" % alt["status"])
        report(lab)
        return 1
    no_key = lab.get(p + "/ingestion-sources")
    lab.check("No key is refused", no_key["status"] == 401,
              "status %s, body %s" % (no_key["status"], error_shape(no_key)))
    if revoked:
        for path in ("/ingestion-sources", "/search"):
            r = lab.get(p + path, revoked, {"keywords": "a"} if path == "/search" else None)
            lab.check("Deleted key refused on " + path, r["status"] == 401,
                      "status %s, body %s" % (r["status"], error_shape(r)))

    # 2. Sources: admin sees all, reader sees only its own
    admin_sources = r_admin_src["json"] or []
    r_reader_src = lab.get(p + "/ingestion-sources", reader)
    reader_sources = r_reader_src["json"] if r_reader_src["status"] == 200 else []
    save("ingestion-sources-reader", reader_sources)
    reader_ids = {s["id"] for s in reader_sources}
    other = [s for s in admin_sources if s["id"] not in reader_ids]
    lab.check("Admin sees at least 3 sources", len(admin_sources) >= 3, "%d sources" % len(admin_sources))
    lab.check("Reader sees exactly 1 source", r_reader_src["status"] == 200 and len(reader_sources) == 1,
              "status %s, %d sources" % (r_reader_src["status"], len(reader_sources)))
    preserve = [s.get("preserveOriginalFile") for s in admin_sources]
    lab.check("Source list exposes preserveOriginalFile", all(v is not None for v in preserve),
              "values %s" % preserve)
    if len(reader_sources) != 1 or not other:
        report(lab)
        return 1
    src_a = reader_sources[0]["id"]
    normal_other = [x for x in other if not x.get("preserveOriginalFile")]
    src_b = (normal_other or other)[0]["id"]
    preserve_sources = [x["id"] for x in admin_sources if x.get("preserveOriginalFile")]

    # 3. Browse
    br_a = lab.get(p + "/archived-emails/ingestion-source/" + src_a, reader, {"page": 1, "limit": 25})
    save("archived-emails-list-reader-a", br_a["json"])
    total_a = (br_a["json"] or {}).get("total")
    lab.check("Reader browses own source", br_a["status"] == 200, "status %s, total %s" % (br_a["status"], total_a))
    item_keys = sorted(((br_a["json"] or {}).get("items") or [{}])[0].keys())
    lab.check("List item fields", bool(item_keys), ", ".join(item_keys))
    br_b = lab.get(p + "/archived-emails/ingestion-source/" + src_b, reader, {"page": 1, "limit": 25})
    total_b = (br_b["json"] or {}).get("total")
    lab.check("Reader gets nothing from other source's listing",
              br_b["status"] in (403, 404) or (br_b["status"] == 200 and not (br_b["json"] or {}).get("items")),
              "status %s, total %s" % (br_b["status"], total_b))

    # Find emails with attachments in A (reader) and B (admin)
    def first_with_attachment(src, key):
        page = 1
        while page <= 10:
            r = lab.get(p + "/archived-emails/ingestion-source/" + src, key, {"page": page, "limit": 25})
            items = (r["json"] or {}).get("items") or []
            for it in items:
                if it.get("hasAttachments"):
                    return it["id"]
            if len(items) < 25:
                return None
            page += 1
        return None

    email_a = first_with_attachment(src_a, reader)
    email_b = first_with_attachment(src_b, admin)

    # 4. Open a message
    if email_a:
        op = lab.get(p + "/archived-emails/" + email_a, reader)
        data = op["json"] or {}
        raw, kind = raw_bytes(data)
        atts = data.get("attachments") or []
        parts, part_bytes = attachment_parts(raw)
        lab.check("Reader opens own email", op["status"] == 200, "status %s, %d ms" % (op["status"], op.get("ms", 0)))
        lab.check("raw format", bool(raw), "%s; .eml %d bytes, response %d bytes (x%.1f)" % (
            kind, len(raw), len(op["body"]), (len(op["body"]) / len(raw)) if raw else 0))
        lab.check("raw excludes attachment bytes (default source)", parts == 0 or part_bytes == 0,
                  "%d attachment parts, %d bytes inside raw; %d attachment records" % (parts, part_bytes, len(atts)))
        lab.check("Detail fields", True, ", ".join(sorted(data.keys())))
        if samples:
            trimmed = dict(data)
            if isinstance(trimmed.get("raw"), dict):
                trimmed["raw"] = {"type": "Buffer", "data": "<%d bytes omitted>" % len(raw)}
            save("archived-email-detail-reader-a", trimmed)
            if raw:
                (samples / "archived-email-raw-a.eml").write_bytes(raw)
        # 5. Attachment download
        if atts:
            att = atts[0]
            dl = lab.get(p + "/storage/download", reader, {"path": att.get("storagePath", "")})
            size_ok = dl["status"] == 200 and len(dl["body"]) == att.get("sizeBytes")
            lab.check("Reader downloads own attachment", size_ok,
                      "status %s, %d bytes (record says %s), type %s, disposition %s, length header %s" % (
                          dl["status"], len(dl["body"]), att.get("sizeBytes"),
                          dl["headers"].get("Content-Type"),
                          "yes" if dl["headers"].get("Content-Disposition") else "no",
                          "yes" if dl["headers"].get("Content-Length") else "no (streamed)"))
    else:
        lab.check("Found an email with attachments in reader's source", False, "none found")
    if email_b:
        op_b = lab.get(p + "/archived-emails/" + email_b, reader)
        lab.check("Reader refused other source's email by ID", op_b["status"] in (403, 404),
                  "status %s, body %s" % (op_b["status"], error_shape(op_b)))
        adm_b = lab.get(p + "/archived-emails/" + email_b, admin)
        atts_b = (adm_b["json"] or {}).get("attachments") or []
        if atts_b:
            dl_b = lab.get(p + "/storage/download", reader, {"path": atts_b[0].get("storagePath", "")})
            lab.check("Reader refused other source's attachment", dl_b["status"] in (403, 404),
                      "status %s" % dl_b["status"])
    for bogus in ("../../../../etc/passwd", "does/not/exist.eml"):
        r = lab.get(p + "/storage/download", reader, {"path": bogus})
        lab.check("Arbitrary storage path refused", r["status"] in (400, 403, 404), "status %s" % r["status"])

    # 6. Search
    s_all = lab.get(p + "/search", reader, {"keywords": "the", "limit": 25, "sort": "date_desc"})
    hits = (s_all["json"] or {}).get("hits") or []
    leaked = [h for h in hits if h.get("ingestionSourceId") != src_a]
    lab.check("Reader search only returns own source", s_all["status"] == 200 and not leaked,
              "status %s, %d hits, %d from other sources, total %s" % (
                  s_all["status"], len(hits), len(leaked), (s_all["json"] or {}).get("total")))
    if hits:
        h = hits[0]
        lab.check("Search page size", True, "%d bytes for %d hits; hit fields: %s" % (
            len(s_all["body"]), len(hits), ", ".join(sorted(h.keys()))))
        att_text = sum(1 for x in hits if any((a or {}).get("content") for a in (x.get("attachments") or [])))
        lab.check("Hits carry attachment text", True, "%d of %d hits" % (att_text, len(hits)))
        if samples:
            save("search-reader", s_all["json"])
    # Attachment text: "yogurt" is inside the demo's lemon-cake-recipe.txt attachment.
    s_att = lab.get(p + "/search", reader, {"keywords": "yogurt", "searchIn": "attachment_content", "limit": 10})
    att_hits = (s_att["json"] or {}).get("hits") or []
    att_keys = sorted({k for h in att_hits for a in (h.get("attachments") or []) for k in (a or {}).keys()})
    with_text = sum(1 for h in att_hits if any(len(str((a or {}).get("content") or "")) > 0
                                               for a in (h.get("attachments") or [])))
    lab.check("Attachment-text search (searchIn=attachment_content)", s_att["status"] == 200,
              "status %s, %d hits, %d carry attachment text; attachment fields: %s" % (
                  s_att["status"], len(att_hits), with_text, ", ".join(att_keys) or "none"))
    s_b = lab.get(p + "/search", reader, {"sources": src_b, "limit": 25})
    lab.check("Reader filter-search on other source returns nothing",
              s_b["status"] in (200, 403) and not ((s_b["json"] or {}).get("hits")),
              "status %s, hits %d" % (s_b["status"], len((s_b["json"] or {}).get("hits") or [])))
    s_f = lab.get(p + "/search", reader, {"sources": src_a, "hasAttachments": "true",
                                          "dateFrom": "2026-01-01", "dateTo": "2026-12-31", "limit": 25})
    lab.check("Filter-only search (source, attachments, dates)", s_f["status"] == 200,
              "status %s, hits %d" % (s_f["status"], len((s_f["json"] or {}).get("hits") or [])))

    # Preserve-original sources (compliance mode): expected to keep attachments inside raw
    for psrc in preserve_sources:
        pid = first_with_attachment(psrc, admin)
        if not pid:
            lab.check("Preserve-original source has an email with attachments", False, "none found")
            continue
        pr = lab.get(p + "/archived-emails/" + pid, admin)
        praw, _ = raw_bytes(pr["json"] or {})
        pparts, pbytes = attachment_parts(praw)
        precs = len((pr["json"] or {}).get("attachments") or [])
        lab.check("Preserve-original source detected (app must not open these in release 1)", True,
                  "raw %d bytes; %d attachment parts, %d bytes inside raw; %d attachment records" % (
                      len(praw), pparts, pbytes, precs))
        rp = lab.get(p + "/archived-emails/" + pid, reader)
        lab.check("Reader refused preserve-original source's email", rp["status"] in (403, 404),
                  "status %s" % rp["status"])

    # 7. Totals
    st = lab.get(p + "/dashboard/stats", reader)
    lab.check("Reader gets no server-wide totals", st["status"] in (401, 403),
              "status %s, body %s" % (st["status"], error_shape(st)))

    # 8. Rate limit (optional)
    if args.rate_limit:
        got = None
        for i in range(110):
            r = lab.get(p + "/ingestion-sources", reader, read_body=False)
            if r["status"] == 429:
                got = (i + 1, r["headers"].get("Retry-After"))
                break
        lab.check("Rate limit reached", got is not None,
                  "429 after %s requests, Retry-After %s" % got if got else "no 429 in 110 requests")

    lab.check("No redirects on any API call", lab.redirects == 0, "%d redirects" % lab.redirects)
    lab.check("Rate-limit headers seen", bool(lab.ratelimit_headers), ", ".join(sorted(lab.ratelimit_headers)) or "none")
    report(lab)
    return 0 if all(ok for _, ok, _ in lab.results) else 1


def report(lab):
    print("\nOpen Archiver lab check (paste this summary; it holds no keys or addresses)")
    print("Python %s, %s" % (sys.version.split()[0], time.strftime("%Y-%m-%d %H:%M")))
    for name, ok, detail in lab.results:
        print("[%s] %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))
    passed = sum(1 for _, ok, _ in lab.results if ok)
    print("%d of %d checks passed" % (passed, len(lab.results)))


if __name__ == "__main__":
    sys.exit(main())
