"""Generate the fictional archive bundled for MailBurrow's in-app demo mode.

Writes assets/demo/archive.json and small attachment files under
assets/demo/attachments/. Output is deterministic: no randomness, clock or
network. Every person, business and address is invented and uses reserved
example domains. Run with --check to verify committed files are current.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "demo"
ATTACH = OUT / "attachments"
BASE = datetime(2026, 10, 28, 9, 15, tzinfo=timezone.utc)

ACCOUNTS = [
    {"id": 1, "emailAddress": "alex.rivera@example.com", "name": "Alex Rivera",
     "lastSync": "2026-10-28T08:00:00Z", "isEnabled": True},
    {"id": 2, "emailAddress": "hello@maple-street-bakery.example", "name": "Maple Street Bakery",
     "lastSync": "2026-10-28T07:30:00Z", "isEnabled": True},
    {"id": 3, "emailAddress": "volunteers@riverside-garden-club.example", "name": "Riverside Garden Club",
     "lastSync": "2026-09-30T18:00:00Z", "isEnabled": False},
]

FOLDERS = {
    1: ["INBOX", "INBOX/Family", "INBOX/Travel", "Receipts", "Newsletters", "Sent", "Archive", "Archive/2021", "Junk"],
    2: ["INBOX", "INBOX/Orders", "INBOX/Suppliers", "Sent", "Invoices"],
    3: ["INBOX", "INBOX/Events", "Sent", "Minutes"],
}

ALEX = "Alex Rivera <alex.rivera@example.com>"
BAKERY = "Maple Street Bakery <hello@maple-street-bakery.example>"
CLUB = "Riverside Garden Club <volunteers@riverside-garden-club.example>"

DEMO_NOTE = "This is fictional sample mail included with MailBurrow's demo mode."


def when(days, hours=0):
    """ISO 8601 UTC timestamp a fixed number of days before BASE."""
    return (BASE - timedelta(days=days, hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


def para(*lines):
    return "\n\n".join(lines)


NEWSLETTER_HTML = """<html><body>
<h2>The Corner Reader &mdash; {month} picks</h2>
<p><img src="https://images.example.org/newsletter/{slug}.png" alt="Banner" width="600"></p>
<p>Hello Alex, here are this month's staff picks from the shop.</p>
<ul><li><b>{book1}</b> &mdash; a cozy mystery set in a lighthouse.</li>
<li><b>{book2}</b> &mdash; field notes from a year of backyard birding.</li></ul>
<p><a href="https://corner-reader.example/events">See upcoming events</a> &middot;
<a href="http://corner-reader.example/unsubscribe">Unsubscribe</a></p>
<p style="color:#666">The image above is a remote resource; MailBurrow blocks it.</p>
</body></html>"""

TABLE_HTML = """<html><body>
<p>Hi Alex, your itinerary is below.</p>
<table border="1" cellpadding="4">
<tr><th>Day</th><th>Departs</th><th>Arrives</th><th>Seat</th></tr>
<tr><td>Fri</td><td>Lakeside 07:40</td><td>Harbor City 10:05</td><td>14C</td></tr>
<tr><td>Sun</td><td>Harbor City 18:20</td><td>Lakeside 20:45</td><td>9A</td></tr>
</table>
<table><tr><td><table><tr><td>Nested layout table</td><td>with merged cells</td></tr></table></td></tr></table>
<p>Manage your booking at <a href="https://trains.example/booking/DEMO42">trains.example</a>.</p>
</body></html>"""

RECEIPT_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Receipt</title></head>
<body><h1>Maple Street Bakery</h1><p>Fictional demo receipt</p>
<p>2 &times; Sourdough loaf &mdash; 12.00<br>1 &times; Cinnamon rolls (6) &mdash; 9.50</p>
<p>Total 21.50</p></body></html>
"""


def long_text():
    body = [
        "Hi Alex,",
        "Here are the full notes from the neighborhood planning meeting, as promised. "
        "They are long, so scroll at your own pace.",
    ]
    topics = ["Sidewalk repairs", "Community garden plots", "Holiday lights", "Speed bumps",
              "Library pop-up", "Park cleanup", "Newsletter volunteers", "Budget review"]
    for number in range(1, 41):
        topic = topics[number % len(topics)]
        body.append(f"{number}. {topic}: discussion continued about timelines, volunteers and costs. "
                    "Several neighbors shared ideas and the group agreed to revisit the item next month "
                    "after collecting quotes and checking the calendar for conflicts.")
    body.append("Thanks for reading all the way to the end!\nJordan")
    return para(*body)


def build_messages():
    m = []

    def add(account, folder, sender, to, subject, days, text, html=None, attachments=(),
            outgoing=False, sent=None, hours=0):
        m.append({
            "accountId": account, "folderName": folder, "from": sender, "to": to,
            "subject": subject, "sentDate": when(days, hours) if sent is None else sent,
            "receivedDate": when(days, hours) if sent is None else sent,
            "isOutgoing": outgoing, "textBody": text, "htmlBody": html,
            "attachments": list(attachments),
        })

    # Account 1: Alex Rivera (personal)
    add(1, "INBOX", "MailBurrow Demo <demo@mailburrow.example>", ALEX, "Welcome to the MailBurrow demo", 0,
        para("Hi there,",
             "Everything you see here is fictional sample mail built into the app. Nothing is "
             "downloaded, and no server is involved.",
             "Try searching for \"invoice\", filtering by date, switching to the bakery account, "
             "opening the long meeting notes or saving an attachment.",
             "Exit the demo any time from the banner or from Settings.", DEMO_NOTE))
    add(1, "INBOX/Family", "Sam Rivera <sam.rivera@example.net>", ALEX, "Sunday dinner?", 1,
        para("Hey! Mom asked if you can bring the lemon cake again. Dinner at 5, as usual.",
             "Also, can you send me the photos from the lake?", "Sam"), hours=3)
    add(1, "Sent", ALEX, "Sam Rivera <sam.rivera@example.net>", "Re: Sunday dinner?", 1,
        para("Count me in. Cake is already on my list.", "Photos attached.", "Alex"),
        attachments=[("lake-sunset.png", "image/png")], outgoing=True, hours=1)
    add(1, "INBOX/Travel", "Lakeside Rail <tickets@trains.example>", ALEX, "Your trip to Harbor City", 3,
        "Your itinerary: Friday Lakeside 07:40 to Harbor City 10:05, seat 14C. Sunday return 18:20, seat 9A.",
        html=TABLE_HTML, attachments=[("boarding-pass.pdf", "application/pdf")])
    add(1, "INBOX", "Jordan Lee <jordan.lee@example.org>", ALEX, "Meeting notes (long)", 5, long_text())
    add(1, "INBOX", "Corner Reader Books <news@corner-reader.example>", ALEX, "Your order has shipped", 6,
        "Your order #DEMO-1042 has shipped and should arrive in 3-5 days.")
    add(1, "Receipts", BAKERY, ALEX, "Your Maple Street Bakery receipt", 8,
        para("Thanks for stopping by! Your receipt is attached.",
             "Open it in a browser to print it. Note: MailBurrow warns before saving HTML files."),
        attachments=[("receipt-printable.html", "text/html")])
    add(1, "INBOX", "Priya Natarajan <priya.n@example.com>", ALEX, "Book club: next pick", 11,
        para("We're reading \"The Lighthouse Keeper's Ledger\" next. See you on the 14th?",
             "Bring snacks if you can!", "Priya"))
    add(1, "Junk", "Prize Department <winner@lucky-draw.example>", ALEX, "You have WON a free cruise!!!", 12,
        para("Click now to claim your prize before it expires!",
             "This fictional message sits in the Junk folder, so MailBurrow shows an extra caution."),
        html='<p>Click <a href="http://lucky-draw.example/claim">here</a> to claim!</p>')
    add(1, "INBOX", "City Utilities <billing@city-utilities.example>", ALEX, "October statement available", 14,
        "Your October statement is ready. Amount due: 64.20. Due date: November 15.",
        attachments=[("statement-october.pdf", "application/pdf")])
    add(1, "INBOX/Family", "Mom <maria.rivera@example.net>", ALEX, "Recipe you asked for", 18,
        para("Lemon cake", "- 2 cups flour\n- 1 cup sugar\n- 3 eggs\n- zest of 2 lemons\n- 1 cup yogurt",
             "Bake at 350F for 45 minutes. Love, Mom"),
        attachments=[("lemon-cake-recipe.txt", "text/plain")])
    add(1, "Sent", ALEX, "Priya Natarajan <priya.n@example.com>", "Re: Book club: next pick", 10,
        "I'll be there and I'll bring cookies from Maple Street.", outgoing=True)
    add(1, "INBOX", "Neighborhood Watch <updates@oak-hollow.example>", ALEX, "Road closure this weekend", 21,
        "Elm Street will be closed between 8am and 4pm on Saturday for paving.")
    add(1, "INBOX", "No Subject Sender <someone@example.org>", ALEX, None, 23,
        "This message has no subject, so the app shows a placeholder.")
    add(1, "INBOX", "Old Server Import <import@example.org>", ALEX, "Imported without a time zone", 25,
        "This message's date has no time zone, so the app labels it time zone unspecified.",
        sent="2026-10-03T14:30:00")
    add(1, "INBOX", "Legacy Import <legacy@example.org>", ALEX, "Imported without a date", 26,
        "This message has no date, so the app shows the date as unavailable.", sent="")
    add(1, "INBOX/Travel", "Harborview Hotel <stay@harborview-hotel.example>", ALEX, "Booking confirmed", 30,
        para("Your stay is confirmed: 2 nights, check-in Friday after 3pm.",
             "Questions? Visit https://harborview-hotel.example/help"))
    add(1, "INBOX", "Café Lumière <bonjour@cafe-lumiere.example>", ALEX, "Unicode: café, reunión, 日本語", 33,
        para("Merci! Gracias! ありがとう!",
             "This fictional message checks accented and non-Latin text: café, niño, Zürich, 東京."))
    months = ["October", "September", "August", "July", "June", "May"]
    books = [("The Lighthouse Keeper's Ledger", "Backyard Wings"), ("Salt and Starlight", "Small Gardens"),
             ("The Quiet Orchard", "Maps of Nowhere"), ("Paper Boats", "The Long Way Round"),
             ("Winter Bread", "Clockwork Bees"), ("Harbor Lights", "A Year of Soup")]
    for index, month in enumerate(months):
        book1, book2 = books[index]
        add(1, "Newsletters", "The Corner Reader <news@corner-reader.example>", ALEX,
            f"The Corner Reader: {month} picks", 4 + index * 30,
            f"This month's picks: {book1} and {book2}. See upcoming events on our website.",
            html=NEWSLETTER_HTML.format(month=month, slug=month.lower(), book1=book1, book2=book2))
    for index in range(1, 9):
        add(1, "Receipts", "Corner Grocer <receipts@corner-grocer.example>", ALEX,
            f"Receipt #{4100 + index}", 9 + index * 17,
            f"Thanks for shopping at Corner Grocer. Total: {18 + index * 3}.{index}5. Paid by card ending 0000.")
    add(1, "Archive/2021", "Sam Rivera <sam.rivera@example.net>", ALEX, "Moving day photos", 1700,
        "Here are the photos from moving day. Can't believe it's been this long!",
        attachments=[("moving-day.png", "image/png")])
    add(1, "Archive/2021", "Jordan Lee <jordan.lee@example.org>", ALEX, "Welcome to the neighborhood", 1745,
        "Welcome! We're at number 12 if you ever need anything. Jordan")
    add(1, "Archive", "Corner Reader Books <news@corner-reader.example>", ALEX, "Your 2023 reading recap", 1040,
        "You read 14 books with us in 2023. Here's to another great year of reading!")

    # Account 2: Maple Street Bakery (small business)
    add(2, "INBOX/Orders", "Taylor Brooks <taylor.brooks@example.com>", BAKERY, "Birthday cake order", 2,
        para("Hi! I'd like to order a chocolate birthday cake for 12 people, pickup Saturday at 10am.",
             "Could it say \"Happy 8th Birthday, Mia\"?", "Thanks, Taylor"))
    add(2, "Sent", BAKERY, "Taylor Brooks <taylor.brooks@example.com>", "Re: Birthday cake order", 2,
        "Confirmed for Saturday at 10am. See you then!", outgoing=True, hours=-2)
    add(2, "INBOX/Suppliers", "Golden Mill Flour <orders@golden-mill.example>", BAKERY, "Invoice GM-2210", 4,
        para("Please find invoice GM-2210 attached for 20 bags of bread flour.", "Payment due in 30 days."),
        attachments=[("invoice-GM-2210.pdf", "application/pdf")])
    add(2, "Invoices", BAKERY, "Riverside Garden Club <volunteers@riverside-garden-club.example>",
        "Invoice MSB-0381: fall fair pastries", 9,
        para("Thanks for choosing us for the fall fair! Invoice MSB-0381 is attached.",
             "Total: 240.00, due within 14 days."),
        attachments=[("invoice-MSB-0381.pdf", "application/pdf")], outgoing=True)
    add(2, "INBOX", "Health Inspection Office <inspections@city-hall.example>", BAKERY,
        "Annual inspection scheduled", 15, "Your annual kitchen inspection is scheduled for November 19 at 9am.")
    add(2, "INBOX/Orders", "Chris Okafor <chris.okafor@example.net>", BAKERY, "Weekly bread standing order", 20,
        "Please continue my standing order: two sourdough loaves every Friday.")
    add(2, "INBOX/Suppliers", "Orchard Valley Farms <sales@orchard-valley.example>", BAKERY,
        "Apple season price list", 27,
        para("Our apple season price list is attached.", "Honeycrisp and Cortland are available now."),
        attachments=[("price-list.txt", "text/plain")])
    for index in range(1, 7):
        add(2, "INBOX/Orders", f"Online Orders <orders@maple-street-bakery.example>", BAKERY,
            f"New online order #{2200 + index}", 1 + index * 6,
            f"New pickup order #{2200 + index}: {index} dozen assorted cookies, pickup tomorrow morning.")
    add(2, "Sent", BAKERY, "Golden Mill Flour <orders@golden-mill.example>", "Re: Invoice GM-2210", 3,
        "Thank you, payment has been scheduled.", outgoing=True)

    # Account 3: Riverside Garden Club (volunteer)
    add(3, "INBOX/Events", "Dana Whitfield <dana.whitfield@example.org>", CLUB, "Fall fair volunteer schedule", 7,
        para("Here is the volunteer schedule for the fall fair.", "Please reply if you need to swap a shift."),
        html="""<p>Volunteer schedule:</p><table border="1"><tr><th>Shift</th><th>Volunteer</th></tr>
<tr><td>9-11</td><td>Dana, Lee</td></tr><tr><td>11-1</td><td>Morgan, Priya</td></tr>
<tr><td>1-3</td><td>Alex, Sam</td></tr></table>""")
    add(3, "Minutes", CLUB, "Members <members@riverside-garden-club.example>", "Minutes: October meeting", 13,
        para("Attendance: 14 members.", "Decisions: plant bulbs along the river path on November 8; "
             "order new hose reels; thank Maple Street Bakery for the pastries."),
        attachments=[("minutes-october.txt", "text/plain")], outgoing=True)
    add(3, "INBOX", "Morgan Ellis <morgan.ellis@example.com>", CLUB, "Seed swap ideas", 19,
        "Could we host a seed swap in early spring? I can bring tomato and basil seeds.")
    add(3, "Sent", CLUB, "Morgan Ellis <morgan.ellis@example.com>", "Re: Seed swap ideas", 18,
        "Great idea! Let's add it to the next meeting agenda.", outgoing=True)
    add(3, "INBOX/Events", "Parks Department <events@city-parks.example>", CLUB, "River path planting permit", 24,
        "Your permit for planting along the river path on November 8 has been approved.",
        attachments=[("planting-permit.pdf", "application/pdf")])
    add(3, "Minutes", CLUB, "Members <members@riverside-garden-club.example>", "Minutes: September meeting", 43,
        "Attendance: 11 members. Decisions: fall fair booth confirmed; new members welcomed.", outgoing=True)

    messages = []
    attachment_id = 1
    for number, item in enumerate(m, start=1):
        files = []
        for name, kind in item["attachments"]:
            files.append({"id": attachment_id, "fileName": name, "contentType": kind,
                          "size": len(ATTACHMENTS[name])})
            attachment_id += 1
        item = dict(item, id=number, attachments=files, hasAttachments=bool(files))
        messages.append(item)
    return messages


def tiny_png(width, height, top, bottom):
    rows = b""
    for y in range(height):
        t = y / max(1, height - 1)
        color = bytes(round(a + (b - a) * t) for a, b in zip(top, bottom))
        rows += b"\x00" + color * width

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def tiny_pdf(title, lines):
    text = ["BT", "/F1 18 Tf", "72 720 Td", f"({title}) Tj", "/F1 11 Tf"]
    for line in lines + ["Fictional MailBurrow demo document."]:
        text += ["0 -22 Td", f"({line}) Tj"]
    text.append("ET")
    stream = "\n".join(text).encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return out


ATTACHMENTS = {
    "lake-sunset.png": tiny_png(96, 64, (255, 170, 90), (60, 40, 120)),
    "moving-day.png": tiny_png(96, 64, (140, 200, 255), (40, 120, 70)),
    "boarding-pass.pdf": tiny_pdf("Lakeside Rail boarding pass",
                                  ["Passenger: Alex Rivera", "Lakeside to Harbor City", "Seat 14C"]),
    "statement-october.pdf": tiny_pdf("City Utilities statement",
                                      ["October", "Amount due: 64.20", "Due: November 15"]),
    "invoice-GM-2210.pdf": tiny_pdf("Golden Mill Flour invoice GM-2210",
                                    ["20 bags bread flour", "Payment due in 30 days"]),
    "invoice-MSB-0381.pdf": tiny_pdf("Maple Street Bakery invoice MSB-0381",
                                     ["Fall fair pastries", "Total: 240.00"]),
    "planting-permit.pdf": tiny_pdf("Parks Department permit",
                                    ["River path planting", "November 8"]),
    "receipt-printable.html": RECEIPT_HTML.encode("utf-8"),
    "lemon-cake-recipe.txt": b"Lemon cake\n\n2 cups flour\n1 cup sugar\n3 eggs\nZest of 2 lemons\n"
                             b"1 cup yogurt\n\nBake at 350F for 45 minutes.\n",
    "price-list.txt": b"Orchard Valley Farms - fictional price list\n\nHoneycrisp: 2.50/lb\n"
                      b"Cortland: 1.80/lb\nCider (gallon): 7.00\n",
    "minutes-october.txt": b"Riverside Garden Club - October minutes (fictional)\n\n"
                           b"Attendance: 14\nBulb planting: November 8\nNew hose reels approved\n",
}


def folder_tree(account, messages):
    counts = {}
    for item in messages:
        if item["accountId"] == account:
            counts[item["folderName"]] = counts.get(item["folderName"], 0) + 1
    nodes = {}
    roots = []
    for path in FOLDERS[account]:
        node = {"name": path.split("/")[-1], "fullPath": path, "totalCount": counts.get(path, 0), "children": []}
        nodes[path] = node
        parent = path.rsplit("/", 1)[0] if "/" in path else None
        (nodes[parent]["children"] if parent else roots).append(node)
    return roots


def build():
    messages = build_messages()
    archive = {
        "notice": "Fictional sample data for MailBurrow's in-app demo. Generated by tools/generate_demo_archive.py.",
        "accounts": ACCOUNTS,
        "folders": {str(account["id"]): folder_tree(account["id"], messages) for account in ACCOUNTS},
        "messages": messages,
        "attachmentFiles": {str(file["id"]): file["fileName"]
                            for item in messages for file in item["attachments"]},
    }
    files = {OUT / "archive.json": (json.dumps(archive, indent=1, ensure_ascii=False) + "\n").encode("utf-8")}
    for name, data in ATTACHMENTS.items():
        files[ATTACH / name] = data
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify committed demo files without writing")
    args = parser.parse_args(argv)
    files = build()
    stale = [path for path, data in files.items() if not path.is_file() or path.read_bytes() != data]
    expected = {path.name for path in files if path.parent == ATTACH}
    extra = sorted(p.name for p in ATTACH.glob("*") if p.name not in expected) if ATTACH.is_dir() else []
    if args.check:
        if stale or extra:
            print("Demo archive files are out of date; run python tools/generate_demo_archive.py", file=sys.stderr)
            return 1
        print(f"Demo archive is current: {len(files)} files.")
        return 0
    for path, data in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    for name in extra:
        (ATTACH / name).unlink()
    print(f"Wrote {len(files)} demo files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
