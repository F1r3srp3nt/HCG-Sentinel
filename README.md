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
| **Dashboard** | Device and connection status, verified-capability indicators, active operations, recent activity, quick access, Stop All Operations. | Invent telemetry, detections or connected equipment. |
| **Network Inspector** | Shows the app's own network path and addresses. Imports pcap/pcapng through the document picker and decodes Ethernet, VLAN, ARP, IPv4/IPv6, TCP, UDP, ICMP with size and resource limits. | Capture this device's traffic or decrypt TLS. Imported files are labelled as such. |
| **Bluetooth Explorer** | User-started Core Bluetooth discovery: identifier, advertised name and services, RSSI, last seen; permission and radio error states. | Connect to devices, see traffic between other devices, estimate distance, or call anything malicious. |
| **Radio Lab** | Connects to an external node over the versioned Sentinel Node Protocol and plots spectrum frames. | Receive or transmit RF on the iPhone. It stays disconnected until you connect it to a node. |
| **Request Composer** | Edits method, path, headers and body of requests Sentinel sends to one selected test endpoint; review-before-send; status, headers, body, timing; credentials redacted from logs. | Intercept other apps or follow redirects off the endpoint. |
| **Settings** | Animation, Preview mode, Bluetooth controls, capture retention and deletion, endpoint, node, helper probing, redacted diagnostic logging, Stop All Operations. | Install certificates, change system networking, or start persistent services. |

Interface-only (specified, validated and tested, but with **no backend**): the privileged helper's capture and filter
operations, and the Mac debugging-proxy adapter. No real radio node implementation exists yet either; a mock node that
declares itself simulated is provided for development.

## Quick start

```bash
open HCGSentinel.xcodeproj
```

Choose the **HCGSentinel** scheme and a simulator, then Run. To test the core logic without Xcode:

```bash
swift test --package-path SentinelCore
```

## Documentation

| Document | Contents |
| --- | --- |
| [docs/BUILDING.md](docs/BUILDING.md) | Requirements, simulator and device builds, manual signing, IPA export, CI. |
| [docs/TESTING.md](docs/TESTING.md) | Automated tests, local test service, simulator and physical-device checklists. |
| [docs/VALIDATION.md](docs/VALIDATION.md) | What has actually been compiled, simulator-tested and device-tested. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Capability model, module layout, process boundaries, data handling. |
| [docs/NODE_PROTOCOL.md](docs/NODE_PROTOCOL.md) | Sentinel Node Protocol v1 for external radio nodes. |
| [docs/HELPER_INTERFACE.md](docs/HELPER_INTERFACE.md) | Optional privileged-helper interface and what is needed to package one. |
| [docs/MAC_PROXY_ADAPTER.md](docs/MAC_PROXY_ADAPTER.md) | Future Mac debugging-proxy adapter. |
| [docs/NEXUS_INTEGRATION.md](docs/NEXUS_INTEGRATION.md) | Future Nexus shortcuts and status. |

## Ground rules

* Use Sentinel only on equipment and services you own or are explicitly authorised to test.
* Never commit real captured traffic, tokens, certificates or provisioning profiles. `.gitignore` excludes the usual
  file types; tests build their captures synthetically in code.
