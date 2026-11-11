"""Export the in-app demo archive as zipped .eml files for a test archive server.

Usage: python tools/export_demo_eml.py [--out build/demo-eml]

Writes one zip per demo account (alex-rivera.zip, maple-street-bakery.zip,
riverside-garden-club.zip). Each zip holds one .eml file per message, in
folders that mirror the demo's folders (INBOX/Family, Receipts, Sent, ...),
with the demo's attachments included. This is the layout Open Archiver's
"EML Import" expects, and other archivers can usually import it too.

All content is the fictional demo data in assets/demo/archive.json, using
reserved example domains only. Output is deterministic: running it twice
produces identical zips. Nothing is fetched or sent anywhere.
"""
import argparse
import json
import zipfile
from email.message import EmailMessage
from email.utils import format_datetime
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEMO = ROOT / "assets" / "demo"
FIXED_ZIP_TIME = (2026, 10, 28, 0, 0, 0)

SLUGS = {
    "alex.rivera@example.com": "alex-rivera",
    "hello@maple-street-bakery.example": "maple-street-bakery",
    "volunteers@riverside-garden-club.example": "riverside-garden-club",
}


def iso(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def build_eml(message, attachment_files):
    eml = EmailMessage()
    eml["From"] = message["from"]
    eml["To"] = message["to"]
    if message.get("subject") is not None:  # the demo includes a message without a subject
        eml["Subject"] = message["subject"]
    date = message.get("sentDate") or message.get("receivedDate")
    if date:
        eml["Date"] = format_datetime(iso(date))
    eml["Message-ID"] = "<demo-%d@mailburrow.example>" % message["id"]
    eml["X-MailBurrow-Demo"] = "fictional sample message"
    eml.set_content(message.get("textBody") or "")
    if message.get("htmlBody"):
        eml.add_alternative(message["htmlBody"], subtype="html")
    for attachment in message.get("attachments") or []:
        name = attachment_files[str(attachment["id"])]
        data = (DEMO / "attachments" / name).read_bytes()
        maintype, _, subtype = attachment["contentType"].partition("/")
        eml.add_attachment(data, maintype=maintype, subtype=subtype or "octet-stream",
                           filename=attachment["fileName"])
    # Fixed MIME boundaries keep the output byte-for-byte reproducible.
    for index, part in enumerate(p for p in eml.walk() if p.is_multipart()):
        part.set_boundary("mailburrow-demo-%d-%d" % (message["id"], index))
    return eml.as_bytes(policy=eml.policy.clone(linesep="\r\n"))


def export(out_dir):
    archive = json.loads((DEMO / "archive.json").read_text(encoding="utf-8"))
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for account in archive["accounts"]:
        slug = SLUGS[account["emailAddress"]]
        messages = sorted((m for m in archive["messages"] if m["accountId"] == account["id"]),
                          key=lambda m: m["id"])
        path = out_dir / (slug + ".zip")
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive_zip:
            for message in messages:
                folder = message["folderName"].strip("/")
                name = "%s/message-%03d.eml" % (folder, message["id"])
                info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                archive_zip.writestr(info, build_eml(message, archive["attachmentFiles"]))
        attachments = sum(len(m.get("attachments") or []) for m in messages)
        written.append((path, account["emailAddress"], len(messages), attachments))
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(ROOT / "build" / "demo-eml"),
                        help="Output folder (default: build/demo-eml)")
    args = parser.parse_args(argv)
    for path, address, count, attachments in export(Path(args.out)):
        print("%s: %s, %d messages, %d attachments" % (path.name, address, count, attachments))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
