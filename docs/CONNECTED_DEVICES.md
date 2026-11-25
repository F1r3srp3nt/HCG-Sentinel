# Connected Devices (HCG Device Link)

Sentinel can pair with an HCG Server you own, show your other paired HCG devices (HCG Terminal, HCG Nexus) and send
one of them a **redacted** Security Lab, Check My Network or HCG Server health report — only after you have reviewed
the exact report and the destination and confirmed (see [Sharing a report](#sharing-a-report)). The protocol is HCG Device Link
(`hcg.devicelink/1`), specified in HCG-Server `docs/DEVICE-LINK.md`. The client is `HCGDeviceLink/`, vendored
unchanged from HCG-Server (`VENDORED.md`; CI checks `VENDORED.sha256`). SentinelCore depends on it and re-exports it.

## Who decides what

| Question | Decided by |
|---|---|
| Who you are | **HCG Connect** (your own sign-in, verified by HCG Server on every request) |
| What your account may do | **ERP App Access**, checked by HCG Server through HCG's Ecosystem API |
| Whether this iPhone is trusted | **The server owner**, who approves it after comparing the key fingerprint |
| Whether Sentinel contacts a server at all | **You**: *Remote connections* in Settings (off by default), and each action |

Sentinel advertises one capability, `report.send`. It never receives commands and never runs anything another device
sends.

## Using it

1. In HCG Server, create an invitation (computer; Network exposure must allow the local network).
2. In Sentinel: **Connected Devices** → paste the `hcg1-…` code → **Request pairing**.
3. On the server, compare the key fingerprint Sentinel shows with the one in the pairing request, then approve it.
4. Open a finished Security Lab report, a Check My Network result or HCG Server health → **Share with paired device** →
   the **Review before sharing** screen opens. Nothing has been sent at that point; see
   [Sharing a report](#sharing-a-report). An offline device receives the report when it next connects, until the report
   expires (7 days), and you can withdraw it until then.
5. **Disconnect and remove this device** tells the server (signed with the device key), forgets the pairing and the
   device key. The owner can also remove the device on the server: Sentinel then shows *Disconnected*.

## Local development pairing (HCG Connect not yet issued)

While HCG has not issued Sentinel's HCG Connect client, the server owner can switch HCG Server to local development
pairing (`hcg-agent link dev-mode on --i-approve-local-development-pairing`). Its invitations then carry
`"am": "local-development"`.

- Only such an invitation makes Sentinel pair **without** an HCG sign-in (`LocalDevelopmentTokens`: no token is sent).
  Any other invitation uses HCG Connect exactly as before.
- The mode is stored in the pairing record (`authMode`), so it survives restarts.
- Every place that shows the connection says **LOCAL DEVELOPMENT — not an HCG account**: the HCG Server card, the HCG
  Connect account card, paired device rows the server marks `local-development`, the share review screen (and the
  destination's identity there when the destination is a local-development pairing), the HCG Server
  health screen and the Dashboard tile.
- The owner still approves the device. It reaches that one server only, nothing on HCG services, and the server refuses
  remote actions.
- If the server switches authority (local development turned off, or HCG Connect configured), it answers
  `authority_changed`. Sentinel stops at once, never retries, marks the pairing removed and shows the reason with the
  pairing form: pair again with a new invitation.

## HCG Server health (read only)

**Connected Devices → HCG Server health → View server health** reads `GET link/diagnostics` when the screen opens
(and on **Read again**). It shows only what the server returned:

- Server availability, agent version, uptime, start time and authority.
- TLS: device API description, server key SHA-256 (and whether it matches the key pinned at pairing), gateway running
  and exposure, gateway CA SHA-256 (compare it before trusting the HCG Server Local CA), certificate expiry.
- Hosted services with status, health, uptime, restarts and last health check.
- Security events as plain text (already redacted by the server), failed authentications in the last 24 h, summary.

When Sentinel is not paired, not approved yet, or Remote connections are off, the screen says *Not connected*. When the
call fails it shows the server's or the transport's real error (for example `permission_not_configured` while no ERP
key maps `link.diagnostics.read`). Values the server did not send read *Not reported*. The screen runs no action on the
server and shows no credentials.

Reading diagnostics sends nothing, and being allowed to read them (`link.diagnostics.read`) does not mean Sentinel may
transmit them. **Share with paired device…** sits in its own *Share (optional, separate step)* card and opens the same
review screen as every other share: the health report is built as a redacted `hcg-server.health` report, and nothing
leaves the iPhone until you confirm it there.

Presentation and conversion: `SentinelCore/Sources/SentinelCore/DeviceLink/ServerHealth.swift`; tests:
`ServerHealthTests.swift`.

## Sharing a report

Every **Share with paired device** button (Security Lab report, Check My Network result, HCG Server health) opens the
same dedicated **Review before sharing** screen. The rules below apply to all of them; the logic is in SentinelCore
(`DeviceLink/ShareSafety.swift`, `DeviceLink/ShareService.swift`) and is unit-tested on Linux and macOS.

| Requirement | How Sentinel meets it |
|---|---|
| Explicit approval | Opening the screen sends nothing. Only **Send to …** followed by the **Send this report?** confirmation transmits. There is no auto-send, no background resend (the old automatic `resendPending()` in the sync loop was removed) and no remembered "always allow": every share starts from the review screen. Viewing reports or server health never sends anything. |
| Preview of the exact redacted report | When the screen opens, the report is built, redacted and encoded **once** (`SharePayload.prepare`). The screen shows those exact UTF-8 bytes (*Exact bytes*, or a *Readable* layout of the same payload), their size and SHA-256, and *Removed before sharing*: how many values each redaction rule replaced. **Send** sends that same `SharePayload`; before sending, Sentinel re-encodes it and refuses if the bytes or the SHA-256 differ. On the wire the bytes sit unchanged inside the Device Link envelope, which adds only a message ID, the destination's installation ID, a creation time and an expiry. |
| Verified destination identity | Destinations come only from `devices()` on the HCG Server pinned at pairing (the list's host key must equal the pinned key). Only approved, non-revoked installations that accept `report.receive` are offered, never this device. The screen shows the destination's name, app and version, its key fingerprint as the server reports it, and the reporting server's name and key, so you can compare the fingerprint with the one the receiving app shows for itself (*This device → Key fingerprint*). Right before sending, Sentinel fetches the device list again and refuses — nothing sent — if the device is gone, revoked, no longer accepts reports, the list came from another server, or **its key changed since you selected it**; you then have to choose (and compare) it again. |
| No credentials or sensitive host information | Pass 1: Sentinel's `Redactor` plus the sharing rules (API keys and long tokens; home-folder paths and user names, also in URLs; personal device names such as "Ana's iPhone"; this iPhone's name, the server's address and the signed-in e-mail; host names in URLs and dotted host names; serial numbers, UDIDs). Pass 2: the shared `hcg.redaction/1` **strict** rules (credentials, private keys, e-mail, IP and MAC addresses) — for every report type now, not only Check My Network. The report names this device by its model ("iPhone"), never its personal name. The server's display name is the only host name allowed. Then a **strict check** runs on the final bytes (and on every decoded string in them) for credentials, tokens, private keys, IP/MAC/e-mail addresses, user names and home paths, personal device names, host names, serial numbers and HCG Server's own refusal rules. If anything remains, **Sending blocked** is shown with the reasons and Send stays disabled. |
| Audit history | **Connected Devices → Share history (this device)**: time, action (send / withdraw), outcome (*Sent*, *Withdrawn*, *Failed*, *Cancelled before sending*), destination name and key fingerprint, report title and type, payload SHA-256 and size, message ID and a reason (an error code or refusal reason). It never stores report content. It is kept on this iPhone (`Application Support/DeviceLink/share-audit.json`, newest 500 entries), survives disconnecting from the server, and is append-only. |
| Cancellation | **Cancel — send nothing** (or closing the screen) makes no network call and is recorded as *Cancelled before sending*. After sending, **Withdraw** (on the review screen, and on each *queued* report under **Connected Devices → Shared reports**) calls `POST link/messages/{id}/withdraw` (client 1.2.0, `withdraw(messageId:)`). While the recipient has not downloaded it, HCG Server deletes its copy and Sentinel records *Withdrawn*. Once downloaded, the server answers `already_delivered` and Sentinel explains that the device already downloaded the report and it can no longer be recalled (recorded as a failed withdraw). |
| Diagnostics do not imply permission to send | The HCG Server health screen says that reading sends nothing and that being able to read diagnostics does not allow Sentinel to transmit them; its share button is a separate, optional step that goes through the same review. Sentinel still advertises only `report.send`. |

When sending fails because the server could not be reached, Sentinel looks once in the outbox for the message ID (the
server may have stored it before the connection dropped). Otherwise it records *Failed* and resends nothing by itself;
**Send** on the same review screen tries again with the same message ID, so the server cannot store a duplicate.

### What is shared, per report type

`SentinelReportSharing` (SentinelCore) converts reports to `hcg.diagnostic-report/1`.

- **Security Lab.** Scope targets, locations and evidence lose their host names, user names and addresses; secret
  values were already redacted by the scanner. What is never shared: the secret-finding fingerprint HMACs.
- **Check My Network.** Wi-Fi details (network name, BSSID) are withheld entirely.
- **HCG Server health.** Server display name, versions, uptime, authority, gateway state and exposure, hosted services
  and their health, security events (already redacted by the server, redacted again), the failed-authentication count
  and the summary. No key fingerprints, no addresses.
- **Checks on the server.** HCG Server checks again and refuses a report that still contains a credential
  (`unredacted_content`).

Unit tests: `SentinelCore/Tests/SentinelCoreTests/ShareReviewTests.swift` (preview bytes = sent bytes, blocked
sensitive content, destination key change refused before sending, eligible destinations, share history without
content, cancel without network, withdraw: withdrawn / `already_delivered` / `not_found`, no automatic resend) and
`DeviceLinkSharingTests.swift`.

## Configuration still missing (not invented)

- **HCG Connect client.** `Info.plist` → `HCGConnectClientID` and `HCGConnectRedirectURI` are empty. HCG has not issued
  an HCG Connect client for HCG Sentinel. Until it does, sign-in shows *Not configured* and nothing is contacted.
- **ERP App Access.** The product and feature keys for Device Link permissions are configured on HCG Server
  (`hcg-connect.json`). None are assumed.

## What was verified, and how

| Kind | What | Where |
|---|---|---|
| Unit (Linux and macOS) | Conversion, redaction, strict check, review/send/withdraw with a stub server, share history | `swift test --package-path SentinelCore` |
| Unit (Linux and macOS) | Device Link client: signing, vectors, retries | `swift test --package-path HCGDeviceLink` |
| Real server, mock identity | Full workflow against a real HCG Server over pinned TLS | HCG-Server CI, `swift-client-macos` job: pair, approve, share, open, revoke |
| Simulator | App build, the Connected Devices screen screenshot | CI `app-macos` and `screenshots` jobs |
| Real device | Not done in this change | — |
