"""Fictional Bichon fixtures for phone measurement checks.

Writes one mbox file to import into the Alex Rivera lab account. Bichon
puts it in its own folder, named after the file, so the fixtures stay
apart from the 40 demo messages:

    python tools\\bichon_fixtures.py --out build\\mailburrow-fixtures.mbox

It holds:
- a large message intended to approach the 8 MiB message-response limit;
  measure the actual parsed JSON after import before using it for memory
  or cancellation measurements;
- a message with a 45 MiB attachment, under the 50 MiB attachment cap, for
  download cancellation;
- 30 small messages, so a search for the fixture marker fills a 25-item
  page.

Every message is fictional, uses reserved example domains, and carries the
marker below in its subject and Message-ID, so fixtures can be found and
removed without touching other mail. Output is deterministic and bounded.
Run the 40-message lab check (tools/bichon_lab_check.py) before importing
these, or after removing them, because they change the account's totals.
"""
import argparse
import hashlib
import sys
from email.message import EmailMessage
from email.utils import format_datetime
from datetime import datetime, timedelta, timezone
from pathlib import Path

MARKER = "MailBurrow fixture"
SENDER = "Fixture Generator <fixtures@fixtures.example>"
RECIPIENT = "Alex Rivera <alex.rivera@example.com>"
START = datetime(2026, 11, 16, 9, 0, tzinfo=timezone.utc)

# Parsed content of the large message: HTML and text bodies of this many
# bytes each. Bichon returns both in one JSON response; two bodies of
# 4.12 MB target a response near 8 MiB (8,388,608 bytes). Server
# normalization/metadata can change that size; record the measured response.
LARGE_BODY_BYTES = 4_120_000
ATTACHMENT_BYTES = 45 * 1024 * 1024
SMALL_MESSAGES = 30
MAX_OUTPUT_BYTES = 80 * 1024 * 1024

# Plain ASCII words, so JSON encoding adds no escapes and the response
# size stays predictable.
WORDS = ("harbor lantern meadow orchard pebble quartz ribbon saddle thistle "
         "umber velvet willow yarrow zephyr amber birch cobalt dune ember "
         "fern").split()


def filler(size, seed):
    """Deterministic ASCII text of exactly [size] bytes."""
    out, i = [], 0
    total = 0
    while total < size:
        word = WORDS[(i * 7 + seed) % len(WORDS)]
        piece = word + (" " if i % 12 else "\n")
        out.append(piece)
        total += len(piece)
        i += 1
    return "".join(out)[:size]


def attachment_bytes(size):
    """Deterministic, incompressible-looking bytes of exactly [size]."""
    block, counter, out = b"", 0, bytearray()
    while len(out) < size:
        block = hashlib.sha256(b"mailburrow-fixture-%d" % counter).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:size])


def base(subject, index):
    msg = EmailMessage()
    msg["From"] = SENDER
    msg["To"] = RECIPIENT
    msg["Subject"] = "%s: %s" % (MARKER, subject)
    msg["Date"] = format_datetime(START + timedelta(minutes=index))
    msg["Message-ID"] = "<mailburrow-fixture-%d@fixtures.example>" % index
    return msg


def large_message():
    msg = base("large message", 0)
    text = filler(LARGE_BODY_BYTES, 1)
    prefix, suffix = "<html><body><p>", "</p></body></html>"
    # Budget the markup before generating text. Truncating assembled HTML
    # can cut a tag or remove the document's closing tags.
    paragraph_text = filler(LARGE_BODY_BYTES - len(prefix) - len(suffix), 2)
    html = prefix + paragraph_text.replace("\n", " ") + suffix
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    msg.set_boundary("mailburrow-fixture-large")
    return msg


def attachment_message():
    msg = base("large attachment", 1)
    msg.set_content("Fictional message with a 45 MiB attachment for download cancellation.\n")
    msg.add_attachment(attachment_bytes(ATTACHMENT_BYTES), maintype="application",
                       subtype="octet-stream", filename="fixture-45mib.bin")
    msg.set_boundary("mailburrow-fixture-attachment")
    return msg


def small_messages():
    for i in range(SMALL_MESSAGES):
        msg = base("search page %02d" % (i + 1), 10 + i)
        msg.set_content("Fictional search-page message %d for the MailBurrow fixtures.\n" % (i + 1))
        yield msg


def messages():
    yield large_message()
    yield attachment_message()
    yield from small_messages()


def mbox_bytes(msg):
    raw = msg.as_bytes(policy=msg.policy.clone(linesep="\n"))
    # mboxrd: quote lines that begin with optional ">" then "From ".
    lines = []
    for line in raw.split(b"\n"):
        stripped = line.lstrip(b">")
        lines.append(b">" + line if stripped.startswith(b"From ") else line)
    return b"From fixtures@fixtures.example Mon Nov 16 09:00:00 2026\n" + b"\n".join(lines) + b"\n\n"


def write(out):
    out.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    # Exclusive creation protects any existing archive, including symlinks.
    # Failed generation removes only the new output owned by this call.
    fh = out.open("xb")
    try:
        with fh:
            for msg in messages():
                data = mbox_bytes(msg)
                total += len(data)
                if total > MAX_OUTPUT_BYTES:
                    raise ValueError("fixture output exceeds its bound")
                fh.write(data)
    except BaseException:
        out.unlink(missing_ok=True)
        raise
    return total


def main(argv=None, out=sys.stdout):
    parser = argparse.ArgumentParser(description="Write fictional Bichon measurement fixtures (one mbox).")
    parser.add_argument("--out", required=True, help="Output .mbox path")
    args = parser.parse_args(argv)
    path = Path(args.out)
    if path.suffix.lower() != ".mbox":
        print("Use an .mbox file name, for example build/mailburrow-fixtures.mbox", file=out)
        return 2
    try:
        total = write(path)
    except FileExistsError:
        print("Output already exists; choose a new .mbox file. Nothing was overwritten.", file=out)
        return 2
    except (OSError, ValueError):
        print("Could not finish the bounded fixture output; check storage and use a new file.", file=out)
        return 2
    print("Wrote %d fictional messages (%d bytes). Import into the Alex Rivera account; "
          "Bichon creates a folder named after the file." % (2 + SMALL_MESSAGES, total), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
