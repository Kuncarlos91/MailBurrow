"""Generate fictional review mail outside the repository; no network or credentials."""
import argparse
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.policy import default
from email.utils import format_datetime
import hashlib
import json
import mailbox
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[1]
ACCOUNTS = ("alpha", "beta")
FOLDERS = {"INBOX": 60, "Sent": 6, "Projects": 6}


def message(account, folder, number):
    label = account.upper()
    owner = f"{account}@example.invalid"
    outgoing = folder == "Sent"
    sent = datetime(2026, 1, 1, 12, tzinfo=timezone.utc) + timedelta(
        days=ACCOUNTS.index(account) * 4 + list(FOLDERS).index(folder), minutes=number)
    msg = EmailMessage(policy=default)
    msg["From"] = f"Fictional {label} <{owner}>" if outgoing else "Fictional Notifications <notify@example.invalid>"
    msg["To"] = "Fictional Recipient <recipient@example.invalid>" if outgoing else f"Fictional {label} <{owner}>"
    msg["Date"] = format_datetime(sent)
    msg["Message-ID"] = f"<mailshelf-review-v1-{account}-{folder.lower()}-{number:03d}@example.invalid>"
    topics = {1: "Welcome and review instructions", 2: "Long message", 3: "Formatted project summary",
              4: "Unicode: Café, reunión, 日本語", 5: "Link confirmation", 7: "Text attachment", 8: "CSV attachment"}
    topic = topics.get(number, ("Invoice", "Travel", "Project", "Meeting")[number % 4])
    msg["Subject"] = f"{label} {folder} {number:03d}: {topic}"
    text = (f"FICTIONAL DEMO DATA ONLY. Account {label}; folder {folder}; message {number:03d}.\n"
            "This archive contains no real mail, users or credentials.\n"
            f"Search for {label} to find only this fictional account.\n"
            "From this line onward the content is also synthetic.\n")
    if number == 1:
        text += "Switch accounts, search, page, open a long message and save an attachment.\n"
    elif number == 2:
        text += "\n".join(f"Paragraph {i:03d}: fictional {label} project notes for scrolling and large-text checks. " * 2 for i in range(1, 161))
    elif number == 4:
        text += "Café y reunión de demostración. 日本語のサンプル。 No personal information.\n"
    elif number == 5:
        text += "Optional external-link confirmation sample: https://example.com/\n"
    msg.set_content(text)
    if number == 3:
        rows = "".join(f"<tr><td>Fictional item {i}</td><td>{label}</td><td>Pending</td></tr>" for i in range(1, 41))
        msg.add_alternative(f"<!doctype html><html><body><h1>{label} fictional project summary</h1>"
                            f"<p>No real mail or private resources.</p><table><tr><th>Item</th><th>Account</th><th>Status</th></tr>{rows}</table>"
                            "<p>End of synthetic message.</p></body></html>", subtype="html")
    if number == 7:
        msg.add_attachment(f"Fictional {label} attachment. Safe plain-text review sample.\n".encode(),
                           maintype="text", subtype="plain", filename=f"{account}-sample.txt")
    if number == 8:
        msg.add_attachment(f"item,account,status\nsynthetic,{label},complete\n".encode(),
                           maintype="text", subtype="csv", filename=f"{account}-sample.csv")
    # Reproducible boundaries and mbox envelope dates, not current time/random IDs.
    for index, part in enumerate(msg.walk()):
        if part.is_multipart():
            part.set_boundary(f"mailshelf-review-v1-{account}-{folder}-{number}-{index}")
    result = mailbox.mboxMessage(msg)
    result.set_from("demo@example.invalid", time.gmtime(sent.timestamp()))
    return result


def generate(output):
    output = Path(output).resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError("Generated mail must stay outside the repository")
    if output.exists():
        raise ValueError("Use a new output directory; existing files are never overwritten")
    # Existing parent required. An exclusive directory prevents accidental merging.
    output.mkdir()
    manifest = {"dataset": "mailshelf-review-v1", "synthetic_only": True, "accounts": []}
    for account in ACCOUNTS:
        account_dir = output / account
        account_dir.mkdir()
        entry = {"label": account.upper(), "address": f"{account}@example.invalid", "folders": []}
        for folder, count in FOLDERS.items():
            path = account_dir / f"{folder}.mbox"
            box = mailbox.mbox(path, create=True)
            try:
                for number in range(1, count + 1):
                    box.add(message(account, folder, number))
                box.flush()
            finally:
                box.close()
            entry["folders"].append({"folder": folder, "messages": count,
                "file": path.relative_to(output).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        manifest["accounts"].append(entry)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository; no existing output is replaced")
    args = parser.parse_args()
    try:
        manifest = generate(args.output)
    except (OSError, ValueError):
        print("Demo generation failed. Choose a new writable directory outside the repo; values withheld.")
        return 1
    total = sum(f["messages"] for a in manifest["accounts"] for f in a["folders"])
    print(f"Generated {total} fictional messages in 6 MBOX files for 2 demo accounts; nothing sent or imported.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
