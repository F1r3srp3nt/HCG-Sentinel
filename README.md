# HCG Sentinel

A native SwiftUI iPhone and iPad app (iOS 14.7+) for **authorised testing of your own devices, networks and
services**: capture-file inspection, Bluetooth LE discovery, a controlled test-request composer, and a client for an
external radio-analysis node.

Sentinel is built around not overstating what it can do. Every capability is tracked on four separate facts —
implemented, supported here, enabled by you, and **verified by a real operation** — and the app shows fabricated data
only in a clearly labelled Preview mode.

## What works today

| Tool | Does | Does not |
| --- | --- | --- |
| **Dashboard** | HCG SENTINEL banner, device and connection status, verified-capability indicators, active operations, recent activity, quick access, Stop All Operations. | Invent telemetry, detections or connected equipment. |
| **Check My Network** | Bounded DNS, HTTPS, captive-portal, proxy and Wi-Fi checks of the current connection; evidence, time, limitations and remediation per finding; cancel at any time. | Call a network safe, or treat a connection failure as an attack. |
| **Network Inspector** | Shows the app's own network path and addresses. Imports pcap/pcapng through the document picker and decodes Ethernet, VLAN, ARP, IPv4/IPv6, TCP, UDP, ICMP with size and resource limits. | Capture this device's traffic or decrypt TLS. Imported files are labelled as such. |
| **Bluetooth Explorer** | User-started Core Bluetooth discovery: identifier, advertised name and services, RSSI, last seen; permission and radio error states. | Connect to devices, see traffic between other devices, estimate distance, or call anything malicious. |
| **Radio Lab** | Connects to an external node with a pairing key over the authenticated Sentinel Node Protocol v2; spectrum and nearby Wi-Fi scans when the node offers them. | Receive or transmit RF on the iPhone, or show anything before the node authenticates. |
| **Request Composer** | Edits method, full URL, headers and body of requests Sentinel itself sends to your allowlisted test endpoints; review-before-send; status, headers, body as text/JSON/hex, timing; credentials redacted from logs. Own-device filtering through a verified helper only. | Intercept other apps, decrypt HTTPS, or follow redirects. |
| **Settings** | Scanning, Remote connections and Animation switches (each says what it enables and stops), Preview mode, capture retention and deletion, test endpoints, node and helper pairing keys, local redacted diagnostic logging, Stop All Operations. | Install certificates, change system networking, or start persistent services. |

Interface-only (specified, validated and tested, but with **no backend**): the privileged helper's capture and filter
operations, and the Mac debugging-proxy adapter. No real radio node implementation exists yet either; a mock node that
declares itself simulated is provided for development.

## Quick start

```bash
open HCGSentinel.xcodeproj
```

Choose the **HCGSentinel** scheme and a simulator, then Run. From the command line, `Tools/build.sh` is the single
entry point (`info`, `range`, `simulator`, `archive`, `inspect`, `export`). To test the core logic without Xcode:

```bash
swift test --package-path SentinelCore
```

## Documentation

| Document | Contents |
| --- | --- |
| [docs/MAKER.md](docs/MAKER.md) | Building with HCG Executable Maker, the archive failure, and the two schemes. |
| [docs/BUILDING.md](docs/BUILDING.md) | Requirements, simulator and device builds, manual signing, IPA export, CI. |
| [docs/TESTING.md](docs/TESTING.md) | Automated tests, local test service, simulator and physical-device checklists. |
| [docs/VALIDATION.md](docs/VALIDATION.md) | What has actually been compiled, simulator-tested and device-tested. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Capability model, module layout, process boundaries, data handling. |
| [docs/NETWORK_CHECK.md](docs/NETWORK_CHECK.md) | What Check My Network tests, its endpoints and its limits. |
| [docs/NODE_PROTOCOL.md](docs/NODE_PROTOCOL.md) | Authenticated Sentinel Node Protocol v2 for external nodes. |
| [docs/HELPER_INTERFACE.md](docs/HELPER_INTERFACE.md) | Optional privileged-helper interface and what is needed to package one. |
| [docs/MAC_PROXY_ADAPTER.md](docs/MAC_PROXY_ADAPTER.md) | Future Mac debugging-proxy adapter. |
| [docs/NEXUS_INTEGRATION.md](docs/NEXUS_INTEGRATION.md) | Future Nexus shortcuts and status. |

## Ground rules

* Use Sentinel only on equipment and services you own or are explicitly authorised to test.
* Never commit real captured traffic, tokens, certificates or provisioning profiles. `.gitignore` excludes the usual
  file types; tests build their captures synthetically in code.
