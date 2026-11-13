# Test archive servers with fictional mail

[Main index](../../README.md) · [Playbook](../PLAYBOOK.md) · [Setup and CI](setup-and-ci.md)

Load the app's fictional demo mail into a throwaway archive server, to develop and test a backend without real mail. Never connect a real mailbox to a test server, and never put real mail, keys or server addresses in fixtures, issues or logs.

## Export the demo mail

```
python tools/export_demo_eml.py
```

[export_demo_eml.py](../../tools/export_demo_eml.py) reads the committed demo archive (`assets/demo/`) and writes one zip per demo account to `build/demo-eml/`, which Git ignores. Use `--out <folder>` to write elsewhere. The output is reproducible byte for byte.

| Zip | Account | Messages | Attachments |
| --- | --- | --- | --- |
| `alex-rivera.zip` | `alex.rivera@example.com` | 40 | 6 |
| `maple-street-bakery.zip` | `hello@maple-street-bakery.example` | 20 | 3 |
| `riverside-garden-club.zip` | `volunteers@riverside-garden-club.example` | 10 | 2 |

Each zip holds one `.eml` per message, in folders that mirror the demo's folders (`INBOX/Family`, `Receipts`, `Sent` and so on), with text and HTML bodies, attachments, fixed `Message-ID` headers (`<demo-N@mailburrow.example>`) and an `X-MailBurrow-Demo: fictional sample message` header. All people and domains are invented; domains are RFC 2606 reserved names. [test_export_demo_eml.py](../../tools/test_export_demo_eml.py) checks every message, header, body and attachment byte against the demo fixtures.

## Import into Open Archiver

Open Archiver's **EML Import** accepts exactly this layout: a zip of `.eml` files in folders.

1. In Open Archiver, open the ingestion sources page and choose **Create New**.
2. Select **EML Import**, name the source after the zip (for example "Alex Rivera (demo)"), choose the zip and submit.
3. Repeat for each zip, so **each account is its own source**. Separate sources are what let a test user be limited to one source when checking authorization.

File imports run once; they are not re-synced. Importing the same zip again may be skipped or deduplicated, depending on the server's duplicate handling (fixed `Message-ID`s make duplicates detectable). To start over, delete the test source and import it again.

## Check an Open Archiver test server

[oa_lab_check.py](../../tools/oa_lab_check.py) runs read-only API checks against a test Open Archiver holding only the demo mail, and prints a summary with no keys, addresses or message content:

```
python tools/oa_lab_check.py https://<test-server>:8443 --samples oa-samples --rate-limit
```

It asks for an admin key, a reader key and, optionally, a deleted key and an expired key, without echoing them (on Windows, paste with a right-click). For an expired key, create a reader key with the earliest expiry Open Archiver allows and run the check after that date. It only sends `GET` requests, always verifies certificates and never follows redirects.

**What a result means.** Every check is `PASS`, `FAIL` or `SKIP`, and required or `(optional)`. The last line reads `RESULT: all required checks passed` only when nothing failed **and** no required check was skipped; otherwise it reads `NOT PROVEN` and the script exits with 1. Search checks use known terms from the demo fixtures with positive controls (an admin search that must find the other source's term), so an empty or malformed response never counts as working.

**Phase 3 contract checks (v3):** the list items, search hits and opened-message response must have the fields and types MailBurrow's Open Archiver backend reads. IDs must pass its ID rule, storage paths its path rule, and the opened message must fit the app's 40 MiB response and 10 MiB message limits. Up to 12 attachments from the reader's source are downloaded and each must match its stated `sizeBytes` exactly. Malformed array members and raw bytes are rejected, timestamp bounds match the app, and paging is checked for the filter search as well as both search pages. Attachment sampling is capped at 12 message-detail requests and 12 downloads, including when messages have no valid attachment records. Problems are reported by field name only. The script also reports, without failing, whether the opened-message response states a `Content-Length` and whether the server compresses it when asked.

**Required fixtures:** the three demo zips imported as separate sources, and a reader limited to the Alex Rivera source (40 messages). **Optional:** a deleted key, a source imported with **Preserve Original File** (from `riverside-garden-club.zip`), and `--rate-limit`, which sends about 100 quick requests and rate-limits the reader key for about a minute. Optional checks that did not run are listed as `SKIP (optional)`, never as passes.

**What the summary can contain:** statuses, counts, sizes, booleans, and field or header names from fixed allowlists. Server-provided text (error messages, page bodies, header values, unknown field names) is never printed; unknown names are only counted. `--samples` saves fictional sample responses for future test fixtures; review them before committing.

[test_oa_lab_check.py](../../tools/test_oa_lab_check.py) runs the checker against an in-process fake server built from the demo fixtures, with faults injected one at a time: missing fixtures, empty and malformed search responses, leaking results or totals, inline payloads and server error text carrying sentinel secrets.

The reader needs a custom role with two rules, one on its source and one on that source's emails:

```json
[
  {"action": ["read", "search"], "subject": "ingestion", "conditions": {"id": {"$in": ["<source id>"]}}},
  {"action": ["read", "search"], "subject": "archive", "conditions": {"ingestionSourceId": {"$in": ["<source id>"]}}}
]
```

## What this does not prove

A successful export only proves the files match the demo data. Whether the server ingested every message and attachment, how it stores and returns them, and whether a restricted key is isolated from other sources are separate checks, run against the live test server. Record them with the server's exact version.
