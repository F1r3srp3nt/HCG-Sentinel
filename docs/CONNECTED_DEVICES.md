# Connected Devices (HCG Device Link)

Sentinel can pair with an HCG Server you own, show your other paired HCG devices (HCG Terminal, HCG Nexus) and send
one of them a **redacted** Security Lab or Check My Network report. The protocol is HCG Device Link
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
4. Open a finished Security Lab report or Check My Network result → **Share with paired device** → choose the device.
   The sheet labels every target **REMOTE**, with its app (HCG Terminal Vanilla/Unleashed, HCG Nexus) and whether it is
   online. An offline device receives the report when it next connects, until the report expires (7 days).
5. **Disconnect and remove this device** tells the server (signed with the device key), forgets the pairing and the
   device key. The owner can also remove the device on the server: Sentinel then shows *Disconnected*.

## What is shared

`SentinelReportSharing` (SentinelCore) converts reports to `hcg.diagnostic-report/1`.

- **Security Lab.** Every string passes through Sentinel's `Redactor`, then the shared `hcg.redaction/1` rules.
  - What these remove: bearer/Basic credentials, JWTs, private keys, passwords in URLs and `key=value` secrets.
  - What is never shared: the secret-finding fingerprint HMACs.
- **Check My Network.** It uses strict redaction.
  - IP addresses, MAC/BSSID and e-mail addresses are masked.
  - Wi-Fi details (network name, BSSID) are withheld entirely.
- **Checks before sending.**
  - Sentinel runs the server's own check before anything is sent, and refuses a report that still contains a credential.
  - HCG Server checks again and refuses such a report (`unredacted_content`).

Unit tests: `SentinelCore/Tests/SentinelCoreTests/DeviceLinkSharingTests.swift`.

## Configuration still missing (not invented)

- **HCG Connect client.** `Info.plist` → `HCGConnectClientID` and `HCGConnectRedirectURI` are empty. HCG has not issued
  an HCG Connect client for HCG Sentinel. Until it does, sign-in shows *Not configured* and nothing is contacted.
- **ERP App Access.** The product and feature keys for Device Link permissions are configured on HCG Server
  (`hcg-connect.json`). None are assumed.

## What was verified, and how

| Kind | What | Where |
|---|---|---|
| Unit (Linux and macOS) | Conversion, redaction, validation | `swift test --package-path SentinelCore` |
| Unit (Linux and macOS) | Device Link client: signing, vectors, retries | `swift test --package-path HCGDeviceLink` |
| Real server, mock identity | Full workflow against a real HCG Server over pinned TLS | HCG-Server CI, `swift-client-macos` job: pair, approve, share, open, revoke |
| Simulator | App build, the Connected Devices screen screenshot | CI `app-macos` and `screenshots` jobs |
| Real device | Not done in this change | — |
