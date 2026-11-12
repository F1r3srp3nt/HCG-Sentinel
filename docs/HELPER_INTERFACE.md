# Sentinel Helper Interface (SHI) — version 1

An optional privileged helper could, on a compatible jailbroken device, perform operations that the iOS sandbox does
not allow (device-wide capture, traffic filter rules). This document defines the interface between the app and such a
helper.

## Status: interface and test harness only

* **No helper has been written, built, packaged or run.** The jailbreak environment of the target devices is unknown,
  so deployment is unverified and the app says so.
* What exists: the wire protocol, client (`HelperClient`), reference helper-side session logic
  (`HelperServerSession`), request validation (`HelperRequestValidator`), and tests that join client and server in
  memory with a handler that performs nothing privileged (`SentinelCoreTests/HelperTests.swift`).
* A package repository only distributes files. It does not provide a jailbreak, entitlements or root. The app treats
  none of package-manager presence, sideloading or filesystem markers as evidence of anything.

## Design constraints

1. **Narrow.** A fixed allowlist of operations with typed, range-checked parameters. No shell, command, script, eval
   or file-path operation exists, and none may be added without a new protocol version.
2. **Authenticated both ways.** The helper proves it holds the pairing key before the client reveals its own proof.
3. **Authorised.** The helper grants an explicit subset of operations per session and rejects the rest.
4. **Tamper- and replay-resistant.** Every request and response carries a MAC; request sequence numbers must
   strictly increase.
5. **Loopback only.** The app connects exclusively to `127.0.0.1`.
6. **Never in SpringBoard.** A helper is its own process (a daemon), not a tweak injected into other processes.
7. **Not persistent by default.** The app probes only on an explicit tap and closes the session afterwards.

## Framing

4-byte big-endian length, then one UTF-8 JSON object (`HelperFrame`). Maximum frame size 65 536 bytes. An oversized
or undecodable frame ends the session.

## Handshake

Pairing key `K`: at least 32 random bytes, generated at helper install time, shown to the user once and entered in
Sentinel (stored in the Keychain). `ctx = "hcg-sentinel-helper-v1"`. `HMAC` is HMAC-SHA256.

| # | Direction | Frame |
| --- | --- | --- |
| 1 | app → helper | `hello { protocolVersions, clientNonce }` (32 random bytes, base64) |
| 2 | helper → app | `challenge { protocolVersion, serverNonce, proof = HMAC(K, ctx‖"\|helper\|"‖clientNonce‖serverNonce) }` |
| 3 | app → helper | `authenticate { proof = HMAC(K, ctx‖"\|client\|"‖clientNonce‖serverNonce) }` — sent only if step 2 verified |
| 4 | helper → app | `session { sessionID, grantedOperations }` |

Session key `S = HMAC(K, ctx‖"|session|"‖clientNonce‖serverNonce)`. Any failure produces an `error` frame and closes
the connection; one authentication attempt per connection.

## Requests

```
request  { sequence, requestID, operation, body (base64 JSON), mac }
response { sequence, requestID, operation, ok, body (base64 JSON), mac }
mac = HMAC(S, ctx‖"|request|" or "|response|"‖"<sequence>|<requestID>|<operation>|<ok or ->|"‖bodyBytes)
```

The helper must verify, in order: MAC → sequence greater than the last accepted → operation known → parameters valid
→ operation granted. MAC or sequence failures close the session.

## Operations

| Operation | Parameters | Limits |
| --- | --- | --- |
| `reportCapabilities` | none | Returns `helperVersion`, `packaging`, `supportedOperations`, `notes`. |
| `getStatus` | none | Returns `activeCaptureID`, `filterRuleCount`. |
| `startCapture` | `interface`, `snapLength`, `maxDurationSeconds`, `maxBytes` | interface `^[a-z][a-z0-9_]{0,14}$`; snap 64–65 535; ≤ 3600 s; ≤ 256 MiB. Always bounded. |
| `stopCapture` | `captureID` | Identifier `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. |
| `setFilterRules` | `rules[]`: `id`, `action` (`block`/`allow`), `transport` (`tcp`/`udp`/`any`), `remoteAddress` (IP literal, optional `/prefix`), `remotePort?` | 1–64 rules; port 1–65 535. |
| `clearFilterRules` | none | Removes only rules this helper installed. |

`startCapture`, `stopCapture`, `setFilterRules` and `clearFilterRules` have **no implementation anywhere**. In the app
they are `interfaceOnly` capabilities and can never show as verified. How a capture file would be handed back to the
app is deliberately left for version 2, once a real backend exists to design against.

## What must be decided before any helper can be built

Shared app logic knows nothing about packaging. The following is required per package and is currently unknown:

| Needed | Rootful package | Rootless package |
| --- | --- | --- |
| Jailbreak and iOS version actually in use on each device | e.g. iPhone X / iOS 14.7 | e.g. a rootless jailbreak, if one applies to the device |
| Install prefix | `/` (e.g. `/usr/libexec`, `/Library/LaunchDaemons`) | the jailbreak's prefix (commonly `/var/jb/...`) |
| Package architecture field | `iphoneos-arm` | `iphoneos-arm64` |
| Daemon launch mechanism | launchd plist path and label | launchd plist path under the prefix, same label |
| Code signing | Entitlements needed for packet capture / filter APIs on that iOS version, and how binaries are signed (`ldid` or equivalent) | Same, plus any trust-cache or signing requirement of that jailbreak |
| Capture backend | Which mechanism is usable (BPF device, `libpcap`, packet tunnel, …) and with which privileges | Same |
| Filter backend | Which mechanism is usable and reversible (`pf` anchor, Network Extension, …) | Same |
| Pairing | How the key is generated at install and shown to the user; file location and permissions (root-only, 0600) | Same, under the prefix |
| Build toolchain | SDK and toolchain (e.g. Theos) versions | Same |
| Removal | What uninstall must clean up (daemon, rules, key) | Same |

See `Helper/README.md` for the packaging checklist. Building or publishing a package is out of scope until those
answers exist and the result has been tested on the actual device.
