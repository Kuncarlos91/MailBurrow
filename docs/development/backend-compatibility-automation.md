# Backend compatibility automation plan

[Main index](../../README.md) · [Playbook](../PLAYBOOK.md) · [Test archive servers](test-archive-servers.md) · [CI](setup-and-ci.md)

Created November 15, 2026. **Status: proposed; no monitoring workflows are enabled by this document.** This is the living technical plan for monitoring Mail-Archiver and Open Archiver, and Bichon when its integration is ready. It does not establish Bichon support or replace backend feasibility gates. App implementation and automation belong in MailBurrow; private lab/device evidence stays outside this public repository.

## Outcome

Detect upstream changes, assess the endpoints MailBurrow uses, run repeatable synthetic compatibility checks, and notify the maintainer with a reproducible result. Automate discovery, comparison, testing and report preparation. Keep acceptance of new supported versions, security decisions, app fixes and publication under review.

A new release is a candidate, not a compatibility failure. A schema diff is a signal, not proof that the app broke. Passing a server checker is not proof that the released app works: test the actual Dart adapter as well. Missing evidence must never produce a green compatibility claim.

## Proposed pipeline

1. Daily discovery reads upstream release metadata and available security advisories from allowlisted sources.
2. It records every unseen eligible release, resolves immutable source/image identities, and creates or updates one compatibility issue per backend/version/edition.
3. A bounded worker queue obtains a schema or source contract, compares only relevant operations, and provisions a disposable synthetic server where an approved recipe exists.
4. Baseline and candidate jobs run server checks plus actual adapter tests against the same fixtures. Results distinguish change, failure and infrastructure problems.
5. A restricted reporting job publishes a sanitized summary and, when appropriate, a draft PR proposing compatibility-matrix or adapter changes. It never merges or publishes an app release.
6. An independent weekly watchdog verifies the discovery heartbeat and checks for missed candidates, stale queues and disabled schedules.

Proposed files, added by later implementation PRs: `config/backend-compatibility.json`, `docs/testing/backend-compatibility.md`, `tools/compatibility/`, `test/integration/backends/`, `test/fixtures/compatibility/` and `.github/workflows/backend-compatibility-*.yml`. They do not exist merely because they are listed here. Start with existing tools where suitable; do not build a second competing test system.

## Inventory and immutable evidence

| Backend | Discovery repository | Initial mode |
| --- | --- | --- |
| Mail-Archiver | `s1t5/mail-archiver` | Supported-backend candidate; review image/bootstrap/contract recipe before CI execution |
| Open Archiver | `LogicLabs-OU/OpenArchiver` | Supported-backend candidate; reuse reviewed lab contracts and synthetic fixtures |
| Bichon | `rustmailer/bichon` | Discovery/source monitoring only until the adapter and feasibility gates are ready |

Populate the manifest from existing reviewed release evidence; do not guess current tested versions. Each backend entry records discovery repository, support state, edition, latest reviewed version, baseline source commit, per-platform image manifest/digest, schema provenance/hash, adapter revision, fixture revision and allowed operation contract. Record runtime dependencies and bootstrap recipe versions too. Current published app and development adapter results must be distinguishable.

An operation contract records method/path, credential header, required permissions/account scope, request shape, response fields/types/units actually consumed, pagination and error semantics, byte/time budgets and optional capabilities. Track endpoints forbidden to the app separately from lab-only bootstrap operations. Do not copy private addresses, credentials or raw upstream files with unreviewed licensing into the manifest.

Never resolve `latest` at execution time. Release metadata maps to a reviewed/pinned image digest and source commit. If mapping or edition is uncertain, report **untested: identity unresolved** and stop that test candidate. A moved tag/different digest is a distinct integrity event even if its version text is unchanged; preserve earlier evidence.

## Discovery, scheduling and durable state

- Proposed schedule: daily around **13:17 UTC** (07:17 Chicago standard time / 08:17 daylight time), plus manual dispatch; cron is UTC, not a local-time guarantee. GitHub may delay or skip scheduled runs.
- Enumerate all unseen stable releases with pagination; do not inspect only the latest release or treat lexical version ordering as semantic ordering. Skip drafts. Queue prereleases only when opted in, with no expansion of stable support claims. Track changed release metadata and known image-tag mutation independently.
- Use a stable event key: backend + edition + release ID/source commit + image digest + app/fixture/recipe revision for a test result. Issue identity can remain backend/release/edition, with successive immutable run links. Concurrent reruns must update rather than duplicate it.
- Keep discovery state and queue entries in durable reviewed repository state or a dedicated state branch, not an Actions cache. Use conditional updates/concurrency and retry-safe writes. A lost cache, interrupted run or notification failure must not mark a candidate processed. Discovery completion and report delivery are separate states.
- Run one backend candidate at a time initially. Deduplicate repeated jobs; cancel superseded duplicate runs only, not a different baseline/candidate result. Enforce job deadlines and a per-run candidate cap; leave overflow visibly queued for later/manual processing.
- After each successful poll, record a heartbeat, sources checked and queue depth even when no release exists. On API rate limiting, honor Retry-After/reset within a bounded retry budget; retain state and retry later. Authentication, network and parsing errors are failures, never “no updates.”
- Weekly watchdog checks the last successful heartbeat, expected scheduled workflows, oldest queued item and unreported results. Proposed stale threshold: 48 hours; proposed queue escalation: 7 days. Surface unhealthy status through a manually accessible dashboard and one deduplicated monitor-health issue. Because a disabled Actions scheduler can also disable its watchdog, the owner should independently subscribe to upstream releases and review the dashboard weekly; an external uptime check is a later optional improvement.

## Contract and security change detection

Obtain OpenAPI from a pinned upstream artifact or the disposable server, not a customer's archive. Validate input size/depth and parse using a safe YAML/JSON loader. Resolve references only within reviewed downloaded documents; disable arbitrary network/file references and external examples. Keep raw exports out of public logs/artifacts until their privacy/license handling is reviewed. Store canonical structural summaries and hashes instead of all upstream text.

Compare operations used by MailBurrow in both directions: the app must still produce valid requests and consume valid responses. Flag removals, changed methods/auth/scopes, newly required request fields, type/nullability changes, enum restrictions, parameter units/date boundaries, paging behavior, status/error envelopes and permission changes. Added optional fields usually need no code change, but newly returned bodies, attachment text or secrets need privacy and size review. Do not narrow a claim to “schema unchanged”: permission, search semantics and limits can change without a schema change.

For missing/incomplete schemas, compare a small reviewed source/fixture contract and require live tests; schema absence is **unknown**, not passing. Upstream release prose and source diffs can help triage but must not be executed, treated as instructions or used alone to approve compatibility. Automated/AI summaries may draft an explanation; deterministic checks decide observed outcomes and a maintainer approves support claims.

Poll available published security advisories independently of releases. Record advisory ID, affected range and assessment status; incomplete metadata needs review. GitHub-only discovery cannot guarantee every advisory is covered. A security fix can require an operator upgrade or documentation change without any app update. Suspected private vulnerabilities go through the project's security process, not an automatic public issue containing exploit details or secrets.

## Disposable integration tests

Each approved recipe must provision its database/index/storage dependencies, valid local HTTPS, fictional data, account-scoped reader user/token and known forbidden account. Use hosted ephemeral runners initially; do not use production services or a runner connected to the owner's tailnet. No production signing keys, mailbox passwords, archive tokens or real messages. Create short-lived synthetic credentials per job; do not persist them in public artifacts.

Keep fixture import/admin setup separate from app/read-only test clients. Denied-write experiments, if included, target only positively identified sacrificial messages and require valid-reader/positive-admin controls and verified cleanup. Follow the separate-procedure boundary of existing lab tooling. Do not run mutation probes through normal app adapters or against customer endpoints.

The suite must cover:

- Authentication, role changes/revocation, refused credentials and cross-account list/search/direct-message/attachment isolation. Genuine expiry uses verified provenance, not a reused revoked token; use a bounded supported mechanism or report untested.
- Accounts/folders, complete paging, search/filter/sort/date/count semantics, empty results, Unicode and opaque identifier collisions. An HTTP 200 with the wrong schema or missing fixture is a failure.
- Parsed text/HTML, remote-content behavior, inline resources, attachments and any unsolicited content in list/search/detail responses. Preserve fail-closed size/permission rules.
- Real Dart adapter requests and returned models against server TLS, including Bichon's read-only search POST when implemented. Test baseline release adapter and current development adapter separately where behavior differs; no mock-only compatibility promotion.
- Timeouts, redirect refusal, streamed response limits and cancellation before/after headers; attachment limits, explicit save and cleanup. A small deterministic proxy/fault server can inject faults the backend cannot reproduce, labelled separately from real-backend results.
- Existing supported backends after shared transport/model changes. UI archive switching and migration stay in the Flutter acceptance suite; native/device memory and performance checks remain separate.

Use [Open Archiver lab checks](../../tools/oa_lab_check.py) and [stress fixtures](../../tools/generate_stress_mail.py) as starting points after reviewing their applicability. Bichon tooling under development is not assumed available on `main`. Verify required fixtures before testing; skipped required checks prevent a pass. Record the actual API response content and operation coverage, not only server startup success.

Compare baseline and candidate under the same app/fixture/recipe inputs. Baseline fails too → investigate infrastructure/test drift first. Baseline passes, candidate fails → likely regression requiring investigation. Both pass → host compatibility evidence for the covered scope only. If the old image cannot be bootstrapped, report the baseline unavailable rather than blaming the candidate or silently using another version.

Always tear down containers, temporary credentials, volumes and certificates in a finalizer, including cancellation/failure. Enforce output, disk, memory, CPU and duration budgets; set initial proposed limits to one backend job, 25-minute job deadline and bounded fixtures/responses, then calibrate per-backend resources in the recipe PR. Large stress/performance runs can be weekly/manual rather than every poll. Retain sanitized summaries for 90 days and disposable diagnostic artifacts for at most 7 days; never retain raw auth responses or real content.

## Execution and reporting boundaries

Pin Actions by commit and dependencies/images by immutable identities. Workflow execution uses trusted repository code and fixed command templates. Never interpolate upstream tag names, release prose, image labels, schema content or user-supplied URLs into shell commands. Restrict network destinations and downloaded sizes, verify the configured registry/repository, and reject arbitrary workflow-dispatch images/endpoints. A digest identifies bytes; it does not establish that executing those bytes is safe. Review each source/recipe before enabling it.

Separate jobs by permission: discovery and tests use read-only repository tokens; disposable upstream code gets no repository write token or repository/customer secrets. Reporting runs after execution in a trusted job with only issue-write permission. A later draft-PR workflow gets content/PR write permission only if needed and explicitly enabled. Do not use `pull_request_target` to run untrusted checkout code, and fork PR jobs never receive lab secrets. Reports are bounded structured data validated against a fixed schema; never render raw server errors or upstream HTML into trusted issue templates.

Proposed statuses:

| Outcome | Meaning | Automated response |
| --- | --- | --- |
| New candidate / queued | Release found, not assessed | Create/update one tracking issue; no support change |
| Host compatible | All required contract/adapter checks passed | Attach evidence; optionally draft matrix PR; maintainer reviews |
| Action needed | Baseline passes; candidate contract/adapter fails, or new privacy/security concern | Summarize operation/failure category and reproduction; leave prior supported version intact |
| Infrastructure failed | Bootstrap, registry, quota, TLS setup or baseline failed | Bounded retry, then health/infra label; do not call backend broken |
| Untested / incomplete | Identity, recipe, edition, expiry fixture or required check unavailable | Explicit missing coverage and next action; no green promotion |
| Monitor unhealthy | Discovery/report delivery stale | Deduplicated health issue/dashboard indication |

Each result includes upstream version/edition/source/digest, app/adapter commit, fixture/recipe/schema hashes, operation coverage, pass/fail/skip counts, baseline comparison, run URL and next action. Public evidence is fictional/sanitized; detailed private/device records are separate. Issue titles use normalized identifiers, never server-provided text. Do not post the same failure repeatedly: update the issue when evidence changes, then close it only when resolved or explicitly deferred. A stale/closed issue must not erase unresolved queue state.

Notifications initially use GitHub issue assignment/subscription and workflow failure notifications. The owner chooses recipients and verifies notification delivery during rollout. External email/chat integrations are optional future work, not enabled or authorized by this plan. Minimize noise: one candidate issue, updates for meaningful transitions, one health issue per ongoing outage.

## When MailBurrow needs an update

- Required operation or auth contract breaks: draft adapter fix plus regressions, then existing candidate/device/release checks.
- New optional capability appears: backlog it; no automatic app update.
- Only deployment/role setup changes: review setup/troubleshooting/privacy updates; app code may be unchanged.
- All covered tests pass: propose matrix expansion with the exact evidence, distinguishing published adapter from development adapter; no app release required solely because upstream released.
- Security advisory affects users: assess separately and communicate reviewed guidance; do not automatically downgrade/upgrade customer servers.

Never automatically merge dependency/adapter fixes, weaken parsing/TLS/roles, change customer servers, bump app versions, sign artifacts, tag releases or deploy the website. An enabled monitoring workflow may create issues/draft PRs as configured; those actions do not authorize publication or compatibility claims.

## Delivery tracker and finish criteria

All tasks start **not started**. Maintainer owns scope/support decisions and notification delivery; implementation/review can be assigned per PR. Update each row with status, responsible person and evidence link as work progresses.

| ID | Deliverable | Done when |
| --- | --- | --- |
| C01 | Manifest, result schema and evidence model | Both supported backends populated from reviewed records; Bichon marked investigation-only; invalid/unknown fields fail validation |
| C02 | Discovery/state/issue workflow | Paginated release scan, prerelease policy, digest changes, durable queue and idempotent issue updates tested; manual dry-run matches injected historical releases without duplicates |
| C03 | Health/security monitoring | Injected API/rate-limit/notification failures remain visible; stale heartbeat and advisory events raise one correct alert; owner receives a test notification |
| C04 | Contract extraction/comparison | Relevant breaking and additive changes classified with fixtures; unsafe references/input rejected; missing schema never passes |
| C05 | First disposable backend recipe | Baseline and candidate boot, fictional data/roles established, actual adapter checks run, cleanup verified on success/failure/cancel; no privileged token reaches upstream processes |
| C06 | Expand backend matrix and fault coverage | Both supported backends covered; Bichon enabled only after readiness; seeded auth/schema/paging/size/cancellation regressions detected and existing backend regressions retained |
| C07 | Reporting and reviewed matrix proposals | Correct statuses, deduplicated bounded issues, draft matrix PRs never auto-merged; failure cannot widen support |
| C08 | Operational handoff | Two weeks of scheduled operation with heartbeat/queue review, notification test, cost/concurrency review and maintainer-assigned monitoring responsibility |

Suggested PR order: C01 → C02/C03 → C04 → C05 (one backend selected by smallest reproducible recipe) → C06 → C07/C08. Start useful release alerts before full server automation exists. Proposed initial Actions budget: cap at 120 runner minutes/week, track actual job minutes and repo allowance, then adjust explicitly; queued work stays visible when the cap is reached. No elapsed-time promise is made for an unbuilt recipe.

At rollout, use dry-run reports before enabling issue writes; then opt in one backend at a time. A successful implementation must demonstrate a new-release alert, a detected injected breaking change, a passing unchanged candidate, a failed/missing infrastructure case, a lost-notification recovery, duplicate suppression and cleanup after interruption. Re-running every scenario should not create duplicate issues or promote untested versions.

## Living-plan maintenance

Each implementation PR links C-task IDs and updates status/evidence, assumptions, remaining work and the next action in this document. Keep a decision log for changed thresholds, notification scope, recipes, permissions and support policy; preserve prior results rather than replacing failures with the latest green run. Reopen affected tasks when version/edition/adapter/fixture/recipe inputs change. Review the matrix quarterly for versions that cannot be reproduced and explicitly retire them rather than keeping stale “tested” claims.

First action: C01 inventory/evidence PR, then release discovery in dry-run mode. This planning PR does not install servers, enable scheduled jobs or notify third parties.
