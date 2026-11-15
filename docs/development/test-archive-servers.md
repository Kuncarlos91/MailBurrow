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

It asks for an admin key, a reader key and, optionally, a revoked key and an expired key, without echoing them (on Windows, paste with a right-click). Open Archiver revokes keys rather than deleting them. For an expired key, create a reader key with the earliest expiry Open Archiver allows and run the check after that date; never give a revoked key at that prompt, because a 401 response cannot distinguish expiry from revocation, an invalid key or another rejection condition. The checker rejects reuse of the admin, reader or revoked key as the expiry fixture, but cannot establish the state of a different key: verify its expiry date, that it was previously usable and that it was never revoked. Leave the prompt empty until that fixture is available. It only sends `GET` requests, always verifies certificates and never follows redirects.

**What a result means.** Every check is `PASS`, `FAIL` or `SKIP`, and required or `(optional)`. The last line reads `RESULT: all required checks passed` only when nothing failed **and** no required check was skipped; otherwise it reads `NOT PROVEN` and the script exits with 1. Search checks use known terms from the demo fixtures with positive controls (an admin search that must find the other source's term), so an empty or malformed response never counts as working.

**Phase 3 contract checks (v3):** the list items, search hits and opened-message response must have the fields and types MailBurrow's Open Archiver backend reads. IDs must pass its ID rule, storage paths its path rule, and the opened message must fit the app's 40 MiB response and 10 MiB message limits. Up to 12 attachments from the reader's source are downloaded and each must match its stated `sizeBytes` exactly. Malformed array members and raw bytes are rejected, timestamp bounds match the app, and paging is checked for the filter search as well as both search pages. Attachment sampling is capped at 12 message-detail requests and 12 downloads, including when messages have no valid attachment records. Problems are reported by field name only. The script also reports, without failing, whether the opened-message response states a `Content-Length` and whether the server compresses it when asked.

**Required fixtures:** the three demo zips imported as separate sources, and a reader limited to the Alex Rivera source (40 messages). **Optional:** a revoked key, a source imported with **Preserve Original File** (from `riverside-garden-club.zip`), and `--rate-limit`, which sends about 100 quick requests and rate-limits the reader key for about a minute. Optional checks that did not run are listed as `SKIP (optional)`, never as passes.

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

## Bichon lab check

For the planned Bichon backend (Phase 0 feasibility), [bichon_lab_check.py](../../tools/bichon_lab_check.py) checks a test Bichon server holding only the demo mail: Alex Rivera and Maple Street Bakery imported into two NoSync accounts, and a reader user with the `member` global role and `account_viewer` on the Alex account only.

```
python tools/bichon_lab_check.py https://<test-server>:9443
```

It asks for an admin token (a control; never used by the app), the reader token and, optionally, a revoked token and an expired token, without echoing them; every token must be different, and the expired one must have passed its expiry date without being revoked. It sends GET requests plus POST to the read-only search endpoint, always verifies certificates and never follows redirects. Write-denial testing must be a separate procedure on disposable fictional fixtures; this routine checker never sends tag changes or administrator cleanup writes. Its result does not close that separate authorization gate.

It checks token refusal, the reader's permissions and account list, that the reader sees Alex only (listing, search, unscoped search, text search, mailboxes, messages, envelopes and attachments), attachment sizes, raw EML refusal, path-like IDs, unusual search text, and redirects. The app never calls `/accounts`; the check only reports whether it would expose an IMAP password to the reader. The summary holds only statuses, counts, sizes, permission names and allowlisted field names. [test_bichon_lab_check.py](../../tools/test_bichon_lab_check.py) runs it against an in-process fake server with leaks, malformed responses, oversized bodies and forbidden method/path combinations injected. Cross-account attachment refusal uses an existing attachment with a successful admin control, not an invented hash. Host responses above 41 MiB fail rather than being silently truncated.

### Bichon write-denial check

[bichon_write_denial.py](../../tools/bichon_write_denial.py) is that separate procedure. It uses one sacrificial fictional message, never the demo mail:

```
python tools/bichon_write_denial.py --write-probe-eml build/probe.eml
python tools/bichon_write_denial.py https://<test-server>:9443
```

The first command writes the probe message without touching the network; import it into the Alex Rivera account's INBOX on Bichon's Import page. The second asks for distinct admin and reader tokens. It stops before mutation unless a complete search finds exactly one probe with exact subject, sender and Message-ID, the admin can read its validated envelope, and the reader can read that same envelope. The admin adds a tag (accepted and visible on the envelope) and repairs this sacrificial probe as positive controls. The admin then restores the probe's original tags with `Overwrite`, a required control. It never uses `Remove`: in Bichon 2.4.2, update-tags `Add` and `Remove` fail with HTTP 500 on any message that already has a tag (the stored tags are re-added in tantivy's encoded form, which panics), while `Overwrite` does not read them. Imported mail can take up to about a minute to become searchable, so wait until a search finds the probe before running the check. The result requires every named control, reader denial and cleanup check to pass. Bichon tags are facet paths starting with `/`, and update-tags validates them before checking permissions, so a reader 400 would prove nothing; the controls use valid `/mailburrow-…` tags. The reader then tries tag, repair and delete, expecting **403**; 401 cannot prove authorization denial because it may mean an invalid/expired token. After each attempt the admin compares the validated envelope snapshot. An uncertain or accepted change stops further reader probes. Once mutation testing starts, admin deletion cleanup is attempted even on a contract failure. Cleanup requires both a direct 404 and a successful, complete empty probe search; an error is not absence. A failed admin control cannot establish the matching request shape. Results apply only to the tested operations, not every possible Bichon mutation. An envelope without `tags` (optional in Bichon's schema) or with null tags counts as untagged. If preflight envelope validation fails, the summary names the failing field, never its value, and no writes are sent; the probe is left for a rerun. After mutation testing begins, validation failures still trigger the cleanup attempt described above; do not assume the probe remains available. The summary holds only statuses, booleans and field names. [test_bichon_write_denial.py](../../tools/test_bichon_write_denial.py) covers wrongly allowed writes, invalid reader credentials, incomplete/ambiguous probe searches, broken controls, metadata changes and cleanup lookup failures. No live write is performed by running these unit tests.

## Phone memory check with stress mail

[generate_stress_mail.py](../../tools/generate_stress_mail.py) writes `stress-mail.zip`: ten fictional messages for the 0.4.0 release check of memory on the phone. They include long bodies, quoted-printable and base64 encodings, Latin-1 plain text and Windows-1252 HTML as the selected body alternatives, six explicitly inline CID images, 30 levels of nesting, 400 parts, about 190 KiB of headers, one message just under the app's 10 MiB message limit and one just over it. Output is deterministic and uses only `stress.example` addresses.

```
python tools/generate_stress_mail.py --out build/stress-eml
```

1. In the test Open Archiver, add an **EML Import** source from `build/stress-eml/stress-mail.zip`. Leave **Preserve Original File** off.
2. Add that source's ID to the phone reader's role policy (see the [setup guide](../setup-guide.md#open-archiver-step-1-create-a-read-only-role)).
3. Connect the phone by USB, open MailBurrow on that source, then for each message run [sample_app_memory.ps1](../../tools/sample_app_memory.ps1) on Windows:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\sample_app_memory.ps1 -Label text-1m
   ```

   Start sampling before opening the message; wait until at least one RSS sample is printed, then open it. Wait until it shows, go back, then press Ctrl+C. The script prints the start, peak and growth of the app's resident memory, plus the kernel's high-water mark since the app started. It reads only the app's `/proc/<pid>/status` through adb and prints no content. Samples can miss spikes; VmHWM is process-lifetime data and may predate the current case. Record the process baseline and case order, and repeat with a fresh process when attributing a peak to one case. If proc access fails, before/after `dumpsys meminfo` is diagnostic only and does not pass the peak-memory gate.
4. **Verify the imported fixtures** with [oa_stress_check.py](../../tools/oa_stress_check.py), using the reader key and the stress source's ID:

   ```
   python tools/oa_stress_check.py https://<test-server>:8443 --source <SOURCE_ID>
   ```

   For each case it downloads the stored message once and prints the response and message sizes and whether the structure the case exercises was **kept** or **changed**. It prints no message text, addresses or the key. The backend may normalize MIME or strip parts. Confirm the stored raw message retains the six inline images, intended charset alternatives, 30 nesting levels, 400 body parts and large headers before claiming those cases passed. Check actual detail response/message sizes: metadata can add wire bytes, so an over-limit refusal alone does not prove which cap was exercised. A normalized-away case is not tested and needs a replacement fixture. The checker validates selected body alternatives, large referenced inline PNGs, body-part counts and app structural limits; duplicate case names, failed/malformed listings and invalid Buffer bytes fail verification. Unknown MIME names are reported only as “other.” Its host download budget is 41 MiB, enough to diagnose a 40 MiB cap violation; larger responses fail rather than being read without a limit. Passing verifies only these structural conditions, not exact byte-for-byte preservation or a phone-memory pass.
5. Open each message twice in a row for the repeated-open check. **over-limit** must show the "too large" message rather than opening. For the cancellation check, open **near-limit** and press Back while it loads: the app should return at once and memory should fall back.

Keep the measured numbers in the maintainer's private release records, as the [0.4.0 candidate guide](../releasing/android-0.4.0.md) says; the public guide lists only the check.
