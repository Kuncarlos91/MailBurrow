"""Check that Open Archiver kept the stress messages' structure after import.

Usage: python tools/oa_stress_check.py https://<test-server>:8443 --source <SOURCE_ID>

After importing build/stress-eml/stress-mail.zip (from generate_stress_mail.py)
as an EML Import source, run this with the phone reader's key. For each stress
message it downloads the stored message once, as the app would, and reports
the response size, the stored message size and the structure the case is meant
to exercise: encodings, charsets, inline images, nesting depth, part count and
header size. A case whose structure the server changed is reported as
"changed"; it doesn't count as tested until replaced.

Read-only: GET requests only, no redirects followed. Prints case names, sizes
and counts, never message text, addresses or the key.
"""
import argparse
import email
import sys
import re
import urllib.parse
import urllib.request
import urllib.error
import ssl
from email import policy

from oa_lab_check import Lab, ask_key, NoRedirect, TIMEOUT

MIB = 1024 * 1024
MESSAGE_LIMIT = 10 * MIB      # the app's limit for an opened message
WIRE_LIMIT = 40 * MIB         # the app's limit for the detail response
PREFIX = "Stress "


def bounded_transport(url, headers):
    # Enough headroom to diagnose a wire-cap refusal without an unbounded
    # host allocation. Lab converts transport failures to safe ERROR results.
    cap = WIRE_LIMIT + MIB
    opener = urllib.request.build_opener(
        NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    try:
        response = opener.open(urllib.request.Request(url, headers=headers, method="GET"), timeout=TIMEOUT)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read(cap + 1)
        if len(body) > cap:
            raise ValueError("response exceeds verification budget")
        return response.code, {k.lower(): v for k, v in response.headers.items()}, body


def case_of(subject):
    """'Stress 03 base64-text-1m: …' -> 'base64-text-1m'; None otherwise."""
    if not isinstance(subject, str) or not subject.startswith(PREFIX):
        return None
    head = subject[len(PREFIX):].split(":", 1)[0].split(" ", 1)
    return head[1] if len(head) == 2 else None


def structure(raw):
    """Facts about a stored message; no content."""
    header_bytes = len(raw.split(b"\r\n\r\n", 1)[0]) if b"\r\n\r\n" in raw else len(raw.split(b"\n\n", 1)[0])
    msg = email.message_from_bytes(raw, policy=policy.default)
    facts = {"raw": len(raw), "headers": header_bytes, "leaves": 0, "depth": 0,
             "inline_images": 0, "encodings": set(), "charsets": set()}

    facts.update(parts=0, body_leaves=0, valid=True, plain_charset=None,
                 html_charset=None, plain_encoding=None, html_encoding=None,
                 plain_bytes=0, html_bytes=0)
    selected = set()
    images = []
    html_text = ""
    stack = [(msg, 0, False)]
    while stack:
        part, level, attachment = stack.pop()
        facts["parts"] += 1
        facts["depth"] = max(facts["depth"], level)
        if level > 32 or facts["parts"] > 500:
            facts["valid"] = False
            break
        if part.defects or sum(len(str(k)) + len(str(v)) + 4 for k, v in part.items()) > 256 * 1024:
            facts["valid"] = False
        attachment = attachment or part.get_content_disposition() == "attachment"
        if part.is_multipart() and part.get_content_maintype() == "multipart":
            stack.extend((child, level + 1, attachment) for child in reversed(list(part.iter_parts())))
            continue
        facts["leaves"] += 1
        if not attachment and part.get_content_maintype() == "text":
            facts["body_leaves"] += 1
            kind = {"text/plain": "plain", "text/html": "html"}.get(part.get_content_type())
            if kind and kind not in selected:
                selected.add(kind)
                encoding = (part.get("Content-Transfer-Encoding") or "7bit").strip().lower()
                charset = (part.get_content_charset() or "us-ascii").lower()
                facts["encodings"].add(encoding)
                facts["charsets"].add(charset)
                facts[kind + "_charset"] = charset
                facts[kind + "_encoding"] = encoding
                facts[kind + "_bytes"] = len((part.get_payload() or "").encode("utf-8", "replace"))
                if kind == "html":
                    html_text = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
        if (not attachment and part.get_content_type() == "image/png" and part.get("Content-ID")):
            payload = part.get_payload(decode=True) or b""
            if len(payload) >= 700 * 1024 and payload.startswith(b"\x89PNG\r\n\x1a\n"):
                images.append(str(part["Content-ID"]).strip("<>"))
    references = set(re.findall(r"cid:([^\s\"'<>]+)", html_text, re.IGNORECASE))
    facts["inline_images"] = len(set(images) & references)
    return facts


EXPECTED = {
    "text-1m": ("about 1 MiB of text", lambda f: f["plain_bytes"] >= MIB),
    "html-qp-2m": ("quoted-printable HTML, about 2 MiB", lambda f: f["html_encoding"] == "quoted-printable" and f["html_bytes"] >= 2 * MIB),
    "base64-text-1m": ("base64 text body", lambda f: f["plain_encoding"] == "base64" and f["plain_bytes"] >= MIB),
    "legacy-charsets": ("ISO-8859-1 and Windows-1252 parts", lambda f: f["plain_charset"] == "iso-8859-1" and f["html_charset"] == "windows-1252"),
    "inline-images-6m": ("6 inline images with Content-ID", lambda f: f["inline_images"] >= 6),
    "nested-30": ("30 nesting levels", lambda f: f["depth"] >= 30),
    "many-parts-400": ("400 body parts", lambda f: f["body_leaves"] >= 400),
    "large-headers-200k": ("at least 150 KiB of headers", lambda f: 150 * 1024 <= f["headers"] <= 256 * 1024),
    "near-limit": ("just under the 10 MiB message limit", lambda f: 9 * MIB <= f["raw"] < MESSAGE_LIMIT),
    "over-limit": ("over the 10 MiB message limit", lambda f: f["raw"] > MESSAGE_LIMIT),
}


def safe_names(values, allowed):
    names = sorted(values & allowed)
    if values - allowed:
        names.append("other")
    return ",".join(names) or "none"


def fetch_items(lab, key, source):
    items, page = [], 1
    while page <= 20:
        resp = lab.get("/archived-emails/ingestion-source/" + source, key, {"page": page, "limit": 25})
        data = resp.obj() or {}
        batch = data.get("items")
        if resp.status != 200 or not isinstance(batch, list) or any(not isinstance(item, dict) for item in batch):
            raise ValueError("invalid listing")
        items += [item for item in batch if isinstance(item, dict)]
        if len(batch) < 25:
            break
        page += 1
    if page > 20:
        raise ValueError("listing truncated")
    return items


def run(lab, key, source, out):
    try:
        items = fetch_items(lab, key, source)
    except ValueError:
        print("RESULT: source listing failed, was malformed or exceeded the page budget; not tested.", file=out)
        return 1
    cases = {}
    duplicates = set()
    for item in items:
        case = case_of(item.get("subject"))
        if case in EXPECTED:
            if case in cases:
                duplicates.add(case)
            cases[case] = item.get("id")
    if not cases:
        print("No stress messages found in that source. Check the source ID and that the reader's role includes it.", file=out)
        return 1
    print("%-20s %9s %9s  %-8s %s" % ("case", "response", "message", "result", "what was checked"), file=out)
    problems = 0
    for case, (label, ok) in EXPECTED.items():
        if case not in cases:
            print("%-20s %9s %9s  %-8s %s" % (case, "-", "-", "MISSING", label), file=out)
            problems += 1
            continue
        ident = cases[case]
        if case in duplicates or not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", ident):
            print("%-20s ERROR: duplicate case or invalid message ID; not tested" % case, file=out)
            problems += 1
            continue
        resp = lab.get("/archived-emails/" + ident, key)
        envelope = (resp.obj() or {}).get("raw")
        data = envelope.get("data") if isinstance(envelope, dict) else None
        raw = (bytes(data) if isinstance(envelope, dict) and envelope.get("type") == "Buffer"
               and isinstance(data, list) and all(type(b) is int and 0 <= b <= 255 for b in data) else b"")
        if resp.status != 200 or not raw:
            print("%-20s %9s %9s  %-8s %s (status %s)" % (case, "-", "-", "ERROR", label, resp.status), file=out)
            problems += 1
            continue
        try:
            facts = structure(raw)
        except (ValueError, TypeError, RecursionError, LookupError):
            print("%-20s ERROR: malformed MIME; not tested" % case, file=out)
            problems += 1
            continue
        wire = len(resp.body)
        result = "kept" if facts["valid"] and ok(facts) and (case == "over-limit" or len(raw) <= MESSAGE_LIMIT) else "changed"
        note = label
        if case in ("near-limit", "over-limit") and wire > WIRE_LIMIT:
            result, note = "changed", label + "; response is over the app's 40 MiB response limit, so that limit, not the message limit, would apply"
        if result != "kept":
            problems += 1
        print("%-20s %8.2fM %8.2fM  %-8s %s" % (case, wire / MIB, facts["raw"] / MIB, result, note), file=out)
        if result != "kept":
            print("%20s depth %d, parts %d, inline images %d, headers %d KiB, encodings %s, charsets %s" % (
                "", facts["depth"], facts["leaves"], facts["inline_images"], facts["headers"] // 1024,
                safe_names(facts["encodings"], {"7bit", "8bit", "binary", "base64", "quoted-printable"}),
                safe_names(facts["charsets"], {"utf-8", "us-ascii", "iso-8859-1", "windows-1252"})), file=out)
    print("", file=out)
    if problems:
        print("RESULT: %d case(s) missing or changed by the server; those are not tested." % problems, file=out)
    else:
        print("RESULT: all 10 stress cases kept their structure after import.", file=out)
    if lab.connection_errors:
        print("Connection errors: %d" % lab.connection_errors, file=out)
    return 1 if problems else 0


def main(argv=None, key=None, transport=None, out=None):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description="Check imported stress messages (read-only).")
    parser.add_argument("url", help="Test server base URL, e.g. https://<host>:8443")
    parser.add_argument("--source", required=True, help="Ingestion source ID of the imported stress-mail.zip")
    parser.add_argument("--api-prefix", default="/api/v1")
    args = parser.parse_args(argv)
    try:
        url = urllib.parse.urlsplit(args.url)
        valid_url = (url.scheme == "https" and bool(url.hostname) and not url.username
                     and not url.password and not url.query and not url.fragment
                     and (url.port is None or 1 <= url.port <= 65535))
    except ValueError:
        valid_url = False
    if not valid_url:
        print("Use the HTTPS address.", file=out)
        return 2
    if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", args.source):
        print("That doesn't look like a source ID (letters, digits and dashes).", file=out)
        return 2
    if not re.fullmatch(r"/[A-Za-z0-9/_-]*", args.api_prefix):
        print("Use an API path prefix without queries or fragments.", file=out)
        return 2
    key = key if key is not None else ask_key("Reader API key: ")
    if not key:
        return 2
    lab = Lab(args.url, args.api_prefix, transport or bounded_transport)
    try:
        return run(lab, key, args.source, out)
    except (ValueError, TypeError, RecursionError):
        print("RESULT: malformed response could not be verified; not tested.", file=out)
        return 1


if __name__ == "__main__":
    sys.exit(main())
