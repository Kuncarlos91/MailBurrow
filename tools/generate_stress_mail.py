"""Generate fictional large and unusual messages for a phone memory check.

Usage: python tools/generate_stress_mail.py [--out build/stress-eml]

Writes stress-mail.zip: one .eml file per case, in an INBOX folder, for
Open Archiver's "EML Import" (do not turn on Preserve Original File for it).
The cases exercise what the app's Open Archiver reader has to handle on a
phone: long bodies, quoted-printable and base64 encodings, legacy character
sets, inline images, deep nesting, many parts, large headers, a message just
under the app's 10 MiB message limit and one just over it.

Each subject starts with the case name and its size, so the cases are easy
to find in the app. All content is generated: reserved example domains, no
real people, deterministic bytes (running it twice gives identical files).
Nothing is fetched or sent anywhere.
"""
import argparse
import hashlib
import random
import struct
import zipfile
import zlib
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from datetime import datetime, timedelta, timezone
from pathlib import Path

FIXED_ZIP_TIME = (2026, 11, 14, 0, 0, 0)
SENDER = "Stress Test Sender <sender@stress.example>"
RECIPIENT = "Stress Test Reader <reader@stress.example>"
MIB = 1024 * 1024
# The app's limits for an opened Open Archiver message (lib/mime_bodies.dart,
# lib/open_archiver_api.dart): 10 MiB message, depth 32, 500 parts,
# 256 KiB of headers.
MESSAGE_LIMIT = 10 * MIB

WORDS = ("archive harvest lantern meadow orchard pebble quarry ribbon saddle "
         "thistle umbrella velvet willow yarrow zephyr almond bramble cedar "
         "drizzle ember fern glacier hazel iris juniper kestrel").split()


def _text(rng, size):
    """Readable plain text of about [size] bytes, in lines under 78 chars."""
    lines, total = [], 0
    while total < size:
        line = " ".join(rng.choice(WORDS) for _ in range(10)).capitalize() + "."
        lines.append(line)
        total += len(line) + 1
    return "\n".join(lines)


def _html(rng, size):
    paragraphs, total = [], 0
    while total < size:
        words = " ".join(rng.choice(WORDS) for _ in range(40))
        paragraph = f"<p>{words.capitalize()} <b>{rng.choice(WORDS)}</b> café – résumé.</p>"
        paragraphs.append(paragraph)
        total += len(paragraph.encode("utf-8"))
    return "<html><body><h1>Stress test</h1>" + "\n".join(paragraphs) + "</body></html>"


def _png(rng, width, height):
    """A valid PNG of random noise; noise keeps the encoded size close to raw."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\x00" + rng.randbytes(width * 3) for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 0))
            + chunk(b"IEND", b""))


def _base(number, case, subject):
    msg = EmailMessage(policy=SMTP)
    msg["From"] = SENDER
    msg["To"] = RECIPIENT
    msg["Subject"] = subject
    sent = datetime(2026, 11, 1, 9, tzinfo=timezone.utc) + timedelta(hours=number)
    msg["Date"] = format_datetime(sent)
    msg["Message-ID"] = f"<stress-{number:02d}-{case}@stress.example>"
    msg["X-MailBurrow-Stress"] = "fictional generated message"
    return msg


def text_1m(rng, msg):
    msg.set_content(_text(rng, MIB), cte="8bit")


def html_qp_2m(rng, msg):
    msg.set_content("Plain-text part of the quoted-printable stress message.")
    msg.add_alternative(_html(rng, 2 * MIB), subtype="html", cte="quoted-printable")


def base64_text_1m(rng, msg):
    msg.set_content(_text(rng, MIB), cte="base64")


def legacy_charsets(rng, msg):
    msg.set_content("UTF-8 part: café, naïve, 日本語.\n" + _text(rng, 20_000))
    msg.add_attachment(("Latin-1 part: café, señor, über.\n" + _text(rng, 20_000)).encode("latin-1"),
                       maintype="text", subtype="plain", disposition="inline",
                       params={"charset": "iso-8859-1"})
    msg.add_attachment(("Windows-1252 part: “quotes” – dash € euro.\n" + _text(rng, 20_000)).encode("cp1252"),
                       maintype="text", subtype="plain", disposition="inline",
                       params={"charset": "windows-1252"})


def inline_images_6m(rng, msg):
    images = [_png(rng, 512, 512) for _ in range(6)]  # about 0.75 MiB each
    html = "<html><body><h1>Inline images</h1>" + "".join(
        f'<p>Image {i + 1}</p><img src="cid:stress-image-{i}@stress.example">' for i in range(len(images))
    ) + "</body></html>"
    msg.set_content("This message has six inline images.")
    msg.add_alternative(html, subtype="html")
    html_part = msg.get_payload()[1]
    for i, data in enumerate(images):
        html_part.add_related(data, maintype="image", subtype="png",
                              cid=f"<stress-image-{i}@stress.example>", filename=f"image-{i + 1}.png")


def nested_30(rng, msg):
    """Multipart/mixed nested 30 levels deep (the app allows 32)."""
    inner = EmailMessage(policy=SMTP)
    inner.set_content("The innermost readable part, 30 levels down.\n" + _text(rng, 2_000))
    for level in range(29):
        wrapper = EmailMessage(policy=SMTP)
        wrapper.make_mixed()
        wrapper.attach(inner)
        inner = wrapper
    msg.make_mixed()
    msg.attach(inner)


def many_parts_400(rng, msg):
    """400 small parts (the app allows 500)."""
    msg.set_content("First of 400 parts.\n" + _text(rng, 500))
    for i in range(399):
        msg.add_attachment(f"Part {i + 2}.\n{_text(rng, 200)}".encode(), maintype="text",
                           subtype="plain", disposition="inline", filename=f"part-{i + 2:03d}.txt")


def large_headers_200k(rng, msg):
    """About 200 KiB of Received headers (the app allows 256 KiB)."""
    for i in range(1_200):
        msg["Received"] = (f"from relay{i}.stress.example (relay{i}.stress.example [192.0.2.{i % 250}]) "
                           f"by mx.stress.example with ESMTP id stress{i:05d}; Sat, 1 Nov 2026 09:00:00 +0000")
    msg.set_content("A message with very large headers.\n" + _text(rng, 5_000))


def near_limit(rng, msg):
    """A text body just under the 10 MiB message limit."""
    msg.set_content(_text(rng, MESSAGE_LIMIT - 400 * 1024), cte="8bit")


def over_limit(rng, msg):
    """A text body just over the 10 MiB message limit; the app should refuse it."""
    msg.set_content(_text(rng, MESSAGE_LIMIT + 400 * 1024), cte="8bit")


CASES = [
    ("text-1m", "1 MiB plain text", text_1m),
    ("html-qp-2m", "2 MiB quoted-printable HTML", html_qp_2m),
    ("base64-text-1m", "1 MiB base64 text", base64_text_1m),
    ("legacy-charsets", "UTF-8, Latin-1 and Windows-1252 parts", legacy_charsets),
    ("inline-images-6m", "six inline images, about 6 MiB", inline_images_6m),
    ("nested-30", "parts nested 30 levels deep", nested_30),
    ("many-parts-400", "400 parts", many_parts_400),
    ("large-headers-200k", "about 200 KiB of headers", large_headers_200k),
    ("near-limit", "just under the 10 MiB limit", near_limit),
    ("over-limit", "just over the 10 MiB limit, should be refused", over_limit),
]


def build(number, case, label, fill):
    rng = random.Random(f"mailburrow-stress-{case}")
    msg = _base(number, case, f"Stress {number:02d} {case}: {label}")
    fill(rng, msg)
    for index, part in enumerate(p for p in msg.walk() if p.is_multipart()):
        part.set_boundary(f"mailburrow-stress-{number:02d}-{index}")
    return msg.as_bytes()


def export(out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "stress-mail.zip"
    summary = []
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for number, (case, label, fill) in enumerate(CASES, start=1):
            data = build(number, case, label, fill)
            info = zipfile.ZipInfo(f"INBOX/stress-{number:02d}-{case}.eml", date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
            summary.append((number, case, len(data)))
    return path, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("build/stress-eml"),
                        help="Output directory (default build/stress-eml, ignored by Git)")
    args = parser.parse_args()
    path, summary = export(args.out)
    for number, case, size in summary:
        print(f"  {number:02d} {case:<20} {size / MIB:6.2f} MiB")
    print(f"Wrote {path} ({len(summary)} fictional messages). SHA-256 "
          f"{hashlib.sha256(path.read_bytes()).hexdigest()[:16]}...")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
