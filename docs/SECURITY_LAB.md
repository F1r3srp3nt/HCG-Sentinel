# Security Lab

Security Lab is Sentinel's toolkit for checking systems **you own or are authorised to test**. It has three modules,
which share one assessment model and one report format. Every run starts only when you press **Start**, works only on
what you selected or entered, stays within visible limits, can be stopped at any time, and produces a report that
stays on the device until you export or delete it.

| Module | Runs where | Contacts |
| --- | --- | --- |
| Secret Scanner | This device | Nothing. It reads the folders and archives you pick. |
| Exposure Check | This device | Only the URLs you enter (at most 5), with plain GET requests. Needs **Remote connections** on. |
| Authentication Defense Lab | This device | Only Sentinel's bundled lab service on `127.0.0.1`. |

HCG Server execution is designed but not available. See [SECURITY_LAB_SERVER.md](SECURITY_LAB_SERVER.md).

## Shared assessment model

Every report (`SecurityAssessmentRecord` in `SentinelCore/SecurityLab/SecurityAssessment.swift`) records the following:

- the module and its version
- the explicit scope: selected folders, files and archives, entered URLs (and whether you marked them local-network), or the lab test account
- where it ran: *This device*, or later a named paired server
- the permissions granted for the run
- start and end time, and the status: completed, cancelled, stopped at the time limit, failed to execute, or unsupported
- its limits: file and byte caps, request or attempt caps, per-request and overall time limits, request spacing
- its checks and findings. Each finding has evidence, a location, an explanation and a recommended fix.
- what was **not tested** and why, plus any **execution errors**
- the method's fixed limitations

Each check has one of five outcomes, kept deliberately separate: **Passed**, **Finding**, **Inconclusive**,
**Unsupported** and **Failed to execute**. An unavailable or broken check is never counted as a pass. The headline
never calls anything "safe" or "secure".

Findings show **severity** (how bad it would be) and **confidence** (how sure Sentinel is) as two separate labels. They
also say whether the finding is **verified behaviour** (Sentinel demonstrated it, for example a certificate the system
refused or a missing lockout) or an **observation** (an indicator such as a version banner or a missing header, which
does not confirm a vulnerability by itself). There are no scores, no radar animations and no random values.

Progress is measured in units of real work: files read, requests answered, attempts made. Cancellation is checked
between units and also aborts the request in flight. Each module has a hard overall time limit.

### Reports and export

Reports are stored as JSON under the app's Application Support folder, with iOS data protection. The newest 100 are
kept. **Export redacted report** writes Markdown and opens the share sheet. Every line of an export goes through the
redactor again, so a secret that somehow reached evidence still does not leave the device. Nothing is ever sent
automatically. Activity-log lines about runs contain only module names, statuses and counts.

### Scope rules (Exposure Check)

`TargetScope` (`ScopePolicy.swift`) enforces these rules on the device that executes the check:

- Only `http` and `https` URLs, and never with credentials embedded in them.
- Cloud metadata hosts and addresses (169.254.169.254, fd00:ec2::254, metadata.google.internal and others), link-local, multicast, unspecified and reserved addresses are **never** contacted.
- Every address a name resolves to is checked before connecting. Loopback and private addresses are allowed only for targets **you** marked as local-network. A literal private IP, `localhost` or a `.local` name counts as that explicit choice.
- Redirects are followed only to the entered host, on the entered port or the standard 80/443. Anything else is reported as "not followed" and is never resolved or contacted. Discovered hosts are never added to the scope.
- On Apple platforms, the address the connection actually reached is checked afterwards (from `URLSessionTaskMetrics`). A response from anywhere else is discarded. The system resolver runs again when it connects, so this post-check is the defence against DNS changes between the two lookups.

## Module 1: Secret Scanner

Pick folders or archives (`.zip`, `.jar`, `.tar`, `.tar.gz`/`.tgz`, `.gz`) with the system picker. Folders are read in
place under security-scoped access for the length of the scan only. Nothing is copied or uploaded.

It detects:

- **Private-key blocks**: PEM and OpenSSH. If no key body follows the header, the finding has low confidence (for example, in documentation). The key body is never shown.
- **Recognised credential formats**: AWS, GitHub (classic and fine-grained), GitLab, Slack tokens and webhooks, Stripe live and test keys, Google API keys, OpenAI, Anthropic, SendGrid, npm, Twilio key SIDs and JWTs.
- **Embedded credentials**: passwords in connection URLs, and values assigned to password, token or key names in code and in `.env`, `.ini` and `.properties` files. Placeholders (`${VAR}`, `<your-token>`, `changeme`, environment lookups and similar) are ignored.
- **High-entropy values** next to credential-like names. Lock files are skipped, and so are lines that mention hashes, checksums or digests. These matches always have low confidence.

**Redaction:** a finding shows the file, line, rule and confidence. The value is replaced by its known format prefix
and length (for example `ghp_[REDACTED 40 chars]`), and the evidence line is redacted again. Raw values exist only in
memory while a file is being scanned.

**False positives:** add `sentinel:allow` (or `gitleaks:allow`) to the line, or press **Mark as false positive** on a
finding. That stores a keyed HMAC fingerprint of rule, path and value. The key is per installation and kept in the
Keychain, so the fingerprint cannot be used to guess a weak secret. If the Keychain is unavailable, the marks last
only until Sentinel quits, and the screen says so.

**Exclusions:** glob patterns, one per line (`*.min.js`, `docs/`, `tests/fixtures/**`). Folders such as `.git`,
`node_modules`, `Pods`, `.build`, `DerivedData`, `build`, `dist` and `.venv` are always skipped.

**Safety and limits:**

- **Files:** at most 5,000 per scan, each up to 1 MB, with 64 MB read in total.
- **Archives:** each up to 25 MB and 10,000 entries.
- **Time:** 3 minutes per scan.
- **Symbolic links** are never followed, whether one is selected directly or found inside a folder or an archive.
- **Binary files** are skipped.
- **Archive handling:** archives are decoded in memory by a bounded DEFLATE decoder (`Inflate.swift`) and never extracted. These entries are reported and not read:
  - entries whose names would escape the folder ("zip slip"), reported as a finding
  - encrypted, nested-archive and ZIP64 entries
  - entries that inflate beyond their declared size or beyond the limits (decompression bombs)
- **Everything skipped** is listed under **Not tested**.

**What it cannot tell you:** whether a credential is active. Sentinel never tests discovered credentials against any
service. It also does not scan Git history or other branches.

## Module 2: Exposure Check

Enter up to five URLs, mark any local-network targets, and confirm that you own them or are authorised to test them.
For each target it reports:

| Check | Passed | Finding | Otherwise |
| --- | --- | --- | --- |
| Reachability and HTTP status | Any HTTP answer (server errors are inconclusive) | — | A TLS refusal is *inconclusive* and is reported under TLS; timeouts, refused connections and DNS failures are *failed to execute*, never findings |
| TLS certificate and host name | The system trusted it for this host | *Verified*: not trusted, expired, not yet valid, wrong host name; expiring within 21 days | Unsupported when no HTTPS service answers |
| HTTP to HTTPS | Redirects to HTTPS on the same host, or nothing answers on HTTP | *Verified*: HTTP served without a redirect, or HTTP only | Inconclusive for redirects to other hosts or timeouts; unsupported for non-standard HTTPS ports, and on iOS for public hosts (see below) |
| Strict-Transport-Security | Present with max-age of 180 days or more | *Observation*: missing or short | Unsupported over plain HTTP |
| Security headers | CSP, nosniff, frame protection and Referrer-Policy all present | *Observation* per missing header; lower severity when the response is not HTML | Inconclusive on an unfollowed redirect |
| Server and version disclosure | No version numbers in banners | *Observation* (info): banners with versions; never mapped to CVEs | — |

**Requests:**

- Plain GET, with no cookies, credentials, proxies or request bodies.
- At most 6 per target, at least 0.5 s apart.
- 10 s limit per request and 2 minutes overall.
- Response bodies are capped at 64 KB.
- Normal TLS validation is always used. A refused certificate becomes a finding and is never bypassed; Sentinel records the presented chain only as evidence.

**Platform limit (iOS):** App Transport Security lets the app use plain HTTP only for local-network addresses (and
Apple's captive-portal test page). For public hosts, the HTTP-to-HTTPS check is therefore reported as
**Unsupported on this platform**, rather than weakening ATS for the whole app. On macOS and Linux (core tests) the
check runs normally.

**Not included, by design:** exploit execution, credential guessing, path or port discovery, and scanning hosts you
did not enter.

## Module 3: Authentication Defense Lab

**The lab service** (`AuthLabService` and `LoopbackHTTPServer`) runs inside Sentinel and listens on 127.0.0.1 only, on
a random port, while you keep it started. **Stop All Operations** stops it.

- **Accounts:** synthetic only (`lab-alice`, the designated test account, and `lab-bob`). Their passwords are random per start and are never shown, logged or returned.
- **Settings:**
  - **rate limiting:** HTTP 429 with Retry-After after *N* attempts per account per minute
  - **temporary lockout:** HTTP 423 for five minutes after *N* consecutive failures
  - **error messages:** generic, or revealing (a deliberate weakness)
  - **event logging:** on or off. The event log can be read only with a token held by the process that started the lab.

**The assessment** (`AuthDefenseAssessment`):

- **Targets:** only an `AuthLabTarget`. That value can be created only by starting the bundled lab, and the assessment confirms the lab's random instance ID before sending any password.
- **Requests:**
  - one request for a non-existent synthetic account, to compare error messages
  - then your incorrect passwords for `lab-alice`, in order, repeated if needed
  - a hard cap of 2–10 requests in total, at least 1 s apart (1.5 s in the app), 5 s per request
- **Stops at:** the first lockout, the first 429 (it never retries), any server error, an unexpected success, a dead connection, cancellation or the time limit.
- **Compares expected with observed behaviour** for lockout, throttling, generic errors and event logging. Expectations default to the lab's settings and can be edited, to see how a mismatch is reported.
  - If the cap is too low, or one defence stopped the test before another could be measured, that check is **inconclusive** and the report says how to measure it.
  - Evidence lists each attempt's status, message, Retry-After and timing. Passwords appear only as "password #2 of 3, 8 characters".

**Not included, by design:** credential stuffing, distributed or parallel guessing, proxy rotation, CAPTCHA or MFA
bypass, and retries meant to evade rate limits.

### Testing real services later

Testing a real login service must not become possible just because a server is paired. The future design needs two
things:

1. An **authorised-test configuration** naming the service's exact origin and login endpoint, a designated test account the owner created for this purpose, the owner's written authorisation reference and its expiry, maximum attempts (≤ 10) and minimum spacing, and the stop conditions above.
2. A **separate permission**, `securityLab.authTesting.external`, granted per service, never implied by pairing, HCG Connect sign-in or the lab module.

Until both exist, the module accepts only the bundled lab, which the type system enforces: no public initialiser
creates an `AuthLabTarget`.

## Running the local lab and test services

| What | How |
| --- | --- |
| Bundled authentication lab | In the app: Security Lab → Authentication Defense Lab → **Start lab service**. In tests: `AuthLabServer().start()`. |
| Exposure test service | `python3 Tools/exposure_test_service.py --http-port 8081 --https-port 8444`, then set `SENTINEL_EXPOSURE_HTTP=http://127.0.0.1:8081` and `SENTINEL_EXPOSURE_HTTPS=https://127.0.0.1:8444` for `swift test`. Its HTTPS certificate is self-signed for `sentinel-test.invalid`, so clients *must* refuse it. |
| Secret fixtures | `python3 Tools/make_security_fixtures.py` regenerates the archive fixtures. Synthetic credentials are assembled at run time and are valid nowhere. |
| HCG Server contract harness | `python3 Tools/hcg_server_assessment_harness.py --device phone-a:dev-token-a`; tests: `python3 -m unittest Tools/test_hcg_server_assessment_harness.py` |

## Platform capabilities

All three modules use public APIs in the normal iOS app: Foundation, URLSession, Security and BSD sockets on loopback.
None needs, uses or detects privileged ("Unleashed") features. A jailbreak indicator is never treated as permission
for a scan or system operation. If a later module needs privileges, it will go through the separate helper adapter
(`docs/HELPER_INTERFACE.md`) and report only what that helper verifiably supports.

The Capabilities screen lists four entries:

- **Secret Scanner** and **Authentication Defense Lab**: on this device; verified by a completed run.
- **Exposure Check**: on this device; turned off while Remote connections is off; verified by an HTTP answer.
- **Assessments on a paired HCG Server**: interface only.
