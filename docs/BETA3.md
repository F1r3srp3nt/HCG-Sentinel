# HCG Sentinel Unleashed 0.1.0~beta3 — Security Intelligence

Development beta for HCG Repo Candidate. **Not published.** It goes to HCG Repo only after the owner approves this
exact package (see [release/0.1.0-beta3.md](release/0.1.0-beta3.md)). Test device: iPhone 11 Pro Max, iOS 17.4,
Dopamine (rootless). Identifiers unchanged: package `com.hakmicapitalgroup.hcgsentinel`, bundle `com.hcg.sentinel`,
Home Screen name Sentinel. Build number 3. `0.1.0~beta2` was built and validated but never imported, so `~beta3` is
the next unused version and no published version is overwritten.

The owner's message referred to an attached device recording. No recording reached this session, so nothing below
is based on it; every statement comes from the code and from CI.

## P0: Starting point

| Item | State found |
| --- | --- |
| HCG-Sentinel `main` | `4c3f9ee`: Connected Devices (HCG Device Link pairing, report sharing, HCG Server health). Merged into the beta branch (`cfef50b`); nothing was dropped. |
| HCG Repo Candidate | Only `0.1.0~beta1` (`490858c`) is published. beta2 was built (SHA-256 `6d783bdb…6e4e61`) but never imported. |
| HCG Nexus integration | Nexus (`c39bbb5`) opens Sentinel with `hcgsentinel://open/<screen>` for dashboard, securityLab, networkCheck, capabilities, network, bluetooth, radio, requests, settings, and `hcgsentinel://report/<uuid>`. Kept byte-for-byte; every name still opens the same screen. |
| HCG System Tester | Links to the same names (plus none new) and exports `hcg.diagnostic-report/1` "connection-security" findings for Sentinel. |
| HCG Signal Contractor | The repository contains only an initial README. There is no interface to integrate with yet. |

### Every capability, classified from the code

The class is computed by `CapabilityState.classification` from four facts the code tracks (implementation, platform
support, the owner's switch, verification in this session) — never set by hand. "Fresh install" is the class before
anything has run; the Capability Center shows the live class.

| Capability | Fresh install | Becomes verified when | Notes |
| --- | --- | --- | --- |
| Connection diagnostics | Implemented, not yet verified | iOS delivers a path update (normally at launch) | |
| Wi-Fi connection details | Implemented, not yet verified | an en* IPv4 address and subnet are read | SSID needs an entitlement + location (not added) |
| Check My Network | Implemented, not yet verified | a run completes with network tests answered | |
| Ping (ICMP Echo) | Implemented, not yet verified | an ICMP Echo Reply arrives (self-test: 127.0.0.1) | |
| Local network discovery | Implemented, not yet verified | a Bonjour service resolves or a confirmed-range address answers | |
| Capture file inspection | Implemented, not yet verified | a capture parses (self-test: synthetic pcapng, labelled) | |
| Bluetooth LE discovery | Implemented, turned off | the first advertisement arrives | Needs Settings › Scanning |
| Test request composer | Implemented, turned off | an endpoint answers with HTTP | Needs Remote connections + an endpoint |
| Secret Scanner | Implemented, not yet verified | a scan reads text files (self-test: planted fake key, redacted) | |
| Exposure Check | Implemented, turned off | a target you entered answers | Needs Remote connections |
| Authentication Defense Lab | Implemented, not yet verified | the bundled lab answers a login | |
| Device security checks | Implemented, not yet verified | at least one check returns a result | New in beta3 |
| Import diagnostic reports | Implemented, not yet verified | a valid report is imported | New in beta3 |
| HCG Server pairing (Device Link) | External hardware required (off until Remote connections) | the server accepts the link | From main |
| HCG Server health | External hardware required (off until Remote connections) | the server answers diagnostics | From main |
| Radio node link | External hardware required | authenticated handshake with a node | Mock node is labelled simulated |
| Spectrum from node hardware | External hardware required | first valid non-simulated frame | Receive-only |
| Nearby Wi-Fi discovery (node) | External hardware required | valid scan from a non-simulated node | iOS cannot scan |
| Privileged helper link | Partially implemented | an authenticated helper answers | Client only; no helper exists |
| Own-device traffic filtering | Partially implemented | a helper accepts rules | Client only |
| Mac debugging proxy | Interface only | — | No Mac companion exists |
| Device-wide capture | Interface only | — | No helper backend |
| Assessments on HCG Server | Interface only | — | HCG Server has no Security Lab API |
| Satellite access | Future research | — | See P14 |
| Cellular radio settings / baseband | Future research | — | See P14 |
| Apple Watch scanning | Future research | — | See P14 |

## P1: Navigation

`SentinelSection` (SentinelCore) is now the single registry for tabs, the iPad sidebar, the Security Intelligence
Center and incoming links. It has the ten original destinations (names unchanged) and thirteen new ones: `center`,
`wifi`, `ping`, `localNetwork`, `deviceSecurity`, `captureInspector`, `secretScanner`, `exposureCheck`, `authLab`,
`externalNodes`, `reports`, `ecosystem`, `serverHealth`. A link and a tap both call `Router.open(_:)` and show the
same `SectionContent`, so every check inside a screen (switches, confirmations, scope rules, pairing) applies equally;
links cannot carry parameters and cannot start anything (tests: `NavigationRegistryTests`). Tabs on iPhone: Command,
Network, Wireless, Center, Capabilities; everything else opens from the Center or as a sheet.

For HCG Nexus: the new names can be added to `HCGSentinelRoutes()` in HCGInterchange.m whenever wanted; nothing in
Nexus has to change for the existing links to keep working.

## P2: Capability Center

Filters (All, Verified, Unverified, Disabled, Unavailable, Planned) with counts; a count per implementation class;
per capability: description, class, platforms, hardware, permissions, availability, enabled, this session's
verification, last success and last failure (kept across launches as history only — it never verifies a new
session), how it is verified, limits, **Open** (its screen) and, where one exists, a **Run test** button. Tests run
only when the capability is on and record verification only on real success:

| Test | What it does | What it proves |
| --- | --- | --- |
| Read this device's connection | reads the path and interface addresses | connection details and, with an en* address, Wi-Fi details |
| Ping loopback | one ICMP Echo to 127.0.0.1, 2 s | ICMP sockets work on this device (not that any host is reachable) |
| Synthetic capture | generates and decodes a 3-packet pcapng | the parser works here (no real traffic) |
| Synthetic secret scan | writes a fake AWS-style key to a temp folder, scans, deletes | the scanner finds it and keeps it redacted |
| Device security checks | runs the checks | at least one check returns a result |

## P3–P9: Features

| Area | Added in beta3 | Already present |
| --- | --- | --- |
| Network Intelligence | Diagnostic history (Check My Network and ping runs, addresses masked, export); jitter range; "iOS path report" wording; External Nodes note on what needs a node | Wi-Fi, ping, local discovery, Check My Network (DNS, HTTPS, TLS chain, captive portal, proxy) |
| Capture Inspector | Statistics (bytes, truncation, endpoints, duration, rate, protocol mix, services, top conversations), timeline bars, privacy-preserving report (host-N pseudonyms, no payloads), own destination | pcap/pcapng validation, metadata, per-packet decode, limits, errors |
| Bluetooth | "Advertisement vs. connection" explanation | Everything Core Bluetooth exposes, history, permission states |
| Request Composer | TLS protocol, cipher suite, chain and trust as iOS reported; DNS/connect/TLS/first-byte timing; session history (redacted URL, header names only) | Methods, headers, bodies, preview, allowlisted endpoints, redaction |
| Secret Scanner / Exposure Check / Auth Lab | Own destinations; self-test for the scanner | Complete since 0.1.0 (see SECURITY_LAB.md) |

## P10–P12: Integrations

| Product | What exists | What Sentinel does now |
| --- | --- | --- |
| HCG Server | Device Link pairing (HCG Connect or local-development invitations), report sharing, health | Unchanged from main; now verified in the Capability Center when the link connects or health loads; Security Lab execution on the server stays "interface only" |
| HCG System Tester | macOS app; exports `hcg.diagnostic-report/1` connection-security findings and links to Sentinel screens | **Imports those files** (Security Reports › Import), validated with HCG Device Link's own validator (schema, redaction flag, size, no keys/tokens), stored locally, shown as text. System Tester stays responsible for connectivity; Sentinel shows and keeps the findings |
| HCG Signal Contractor | README only | Radio nodes keep using the authenticated Sentinel Node Protocol v2 (receive-only). When Signal Contractor ships a node, it speaks that protocol; Sentinel does not duplicate its hardware |

No production HCG Connect credentials were created and no remote execution was added.

## P13: Jailbreak backend evaluation

| Item | Finding in the code | Decision |
| --- | --- | --- |
| Privileged helper link | Client, protocol and validation exist; no helper binary exists anywhere | Stays "partially implemented" |
| Device-wide capture | Helper operation specified; no backend | Stays "interface only"; no unrestricted interception |
| Own-device filtering | Client sends validated rules; needs a helper | Unchanged |
| **New: device security checks** | Non-invasive, needs no privileges: passcode, biometrics, system, data protection, ATS, environment, Sentinel's own dpkg record and files | Implemented for both editions; the package checks run only when Sentinel is installed under /var/jb |

Standard and Unleashed stay separate: the same app, with package checks only for a package-manager install. No new
privileged component was built; any future one needs its own security review and the owner's explicit approval.

## P14: Platform feasibility

| Question | Supported APIs on iPhone | External hardware | Verdict and path |
| --- | --- | --- | --- |
| Satellite access | None: no public API for the satellite radio, Emergency SOS or Messages via satellite | An SDR on a node could receive satellite downlinks (receive-only) | **Unavailable on the iPhone.** Path: Signal Contractor node → Node Protocol v2 |
| Cellular radio settings | CoreTelephony gives carrier name/MCC (deprecated, often empty) and radio access technology only; no settings, no signal values | A modem on a node | **Read-only basics at most; changing radio behaviour is not possible and not planned.** |
| Apple Watch scanning | watchOS apps can use Core Bluetooth (central) and URLSession, with tight limits; Sentinel has no watchOS app | — | **Feasible to prototype** a small BLE list on the Watch; no data today |
| Nearby Wi-Fi discovery | No public API (NEHotspotHelper needs an operator entitlement) | A Wi-Fi radio on a node (already supported via `wifi_scan`), or a reviewed jailbreak helper | **Unavailable on the iPhone; available through a node.** Helper design in BETA2.md §4 |
| Other hardware (UWB, NFC, sensors) | Nearby Interaction (UWB) only between cooperating apps; Core NFC reads tags with user action | — | Not security-relevant enough to add now; listed for research |

## P16: Testing

Automated results: [VALIDATION.md](VALIDATION.md). Device checklist for the iPhone 11 Pro Max: [BETA3_CHECKLIST.md](BETA3_CHECKLIST.md).
Simulator and mock results are recorded separately from device results.
