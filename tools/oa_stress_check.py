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
from email import policy

from oa_lab_check import Lab, ask_key, raw_bytes, urllib_transport

MIB = 1024 * 1024
MESSAGE_LIMIT = 10 * MIB      # the app's limit for an opened message
WIRE_LIMIT = 40 * MIB         # the app's limit for the detail response
PREFIX = "Stress "


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

    def walk(part, level):
        facts["depth"] = max(facts["depth"], level)
        if part.is_multipart():
            for child in part.iter_parts():
                walk(child, level + 1)
            return
        facts["leaves"] += 1
        if part.get_content_maintype() == "text":
            facts["encodings"].add((part.get("Content-Transfer-Encoding") or "7bit").lower())
            facts["charsets"].add((part.get_content_charset() or "us-ascii").lower())
        if (part.get_content_maintype() == "image" and part.get("Content-ID")
                and (part.get_content_disposition() or "inline") == "inline"):
            facts["inline_images"] += 1

    walk(msg, 0)
    return facts


EXPECTED = {
    "text-1m": ("about 1 MiB of text", lambda f: f["raw"] >= MIB),
    "html-qp-2m": ("quoted-printable HTML, about 2 MiB", lambda f: "quoted-printable" in f["encodings"] and f["raw"] >= 2 * MIB),
    "base64-text-1m": ("base64 text body", lambda f: "base64" in f["encodings"] and f["raw"] >= MIB),
    "legacy-charsets": ("ISO-8859-1 and Windows-1252 parts", lambda f: {"iso-8859-1", "windows-1252"} <= f["charsets"]),
    "inline-images-6m": ("6 inline images with Content-ID", lambda f: f["inline_images"] >= 6),
    "nested-30": ("30 nesting levels", lambda f: f["depth"] >= 30),
    "many-parts-400": ("400 body parts", lambda f: f["leaves"] >= 400),
    "large-headers-200k": ("at least 150 KiB of headers", lambda f: f["headers"] >= 150 * 1024),
    "near-limit": ("just under the 10 MiB message limit", lambda f: 9 * MIB <= f["raw"] < MESSAGE_LIMIT),
    "over-limit": ("over the 10 MiB message limit", lambda f: f["raw"] > MESSAGE_LIMIT),
}


def fetch_items(lab, key, source):
    items, page = [], 1
    while page <= 20:
        resp = lab.get("/archived-emails/ingestion-source/" + source, key, {"page": page, "limit": 25})
        data = resp.obj() or {}
        batch = data.get("items") if isinstance(data.get("items"), list) else []
        items += [item for item in batch if isinstance(item, dict)]
        if len(batch) < 25:
            break
        page += 1
    return items


def run(lab, key, source, out):
    items = fetch_items(lab, key, source)
    cases = {}
    for item in items:
        case = case_of(item.get("subject"))
        if case in EXPECTED and case not in cases:
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
        resp = lab.get("/archived-emails/" + str(cases[case]), key)
        raw, _ = raw_bytes(resp.obj() or {})
        if resp.status != 200 or not raw:
            print("%-20s %9s %9s  %-8s %s (status %s)" % (case, "-", "-", "ERROR", label, resp.status), file=out)
            problems += 1
            continue
        facts = structure(raw)
        wire = len(resp.body)
        result = "kept" if ok(facts) else "changed"
        note = label
        if case in ("near-limit", "over-limit") and wire >= WIRE_LIMIT:
            result, note = "changed", label + "; response is over the app's 40 MiB response limit, so that limit, not the message limit, would apply"
        if result != "kept":
            problems += 1
        print("%-20s %8.2fM %8.2fM  %-8s %s" % (case, wire / MIB, facts["raw"] / MIB, result, note), file=out)
        if result != "kept":
            print("%20s depth %d, parts %d, inline images %d, headers %d KiB, encodings %s, charsets %s" % (
                "", facts["depth"], facts["leaves"], facts["inline_images"], facts["headers"] // 1024,
                ",".join(sorted(facts["encodings"])) or "none", ",".join(sorted(facts["charsets"])) or "none"), file=out)
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
    if not args.url.startswith("https://"):
        print("Use the HTTPS address.", file=out)
        return 2
    if not all(c.isalnum() or c == "-" for c in args.source) or not 0 < len(args.source) <= 64:
        print("That doesn't look like a source ID (letters, digits and dashes).", file=out)
        return 2
    key = key if key is not None else ask_key("Reader API key: ")
    if not key:
        return 2
    lab = Lab(args.url, args.api_prefix, transport or urllib_transport)
    return run(lab, key, args.source, out)


if __name__ == "__main__":
    sys.exit(main())
