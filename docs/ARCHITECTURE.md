# Architecture

HCG Sentinel is a standalone SwiftUI app for authorised testing of devices, networks and services that you own or are
explicitly permitted to test.

## Layout

| Path | What it is |
| --- | --- |
| `HCGSentinel.xcodeproj` | App target `HCGSentinel`, hosted test target `HCGSentinelTests`, shared scheme `HCGSentinel`. |
| `HCGSentinel/` | The app: SwiftUI screens, per-tool observable models and iOS platform adapters. |
| `SentinelCore/` | Local Swift package with all logic that needs no UIKit, SwiftUI, Core Bluetooth or Network.framework. Builds and tests on macOS and Linux. |
| `HCGSentinelTests/` | App-level state tests that run inside the app on a simulator. |
| `Tools/` | Local test service, mock radio node, synthetic capture generator, project generator. |
| `Helper/` | Packaging notes for the optional privileged helper. No helper code or binary exists. |
| `docs/` | Build, test, protocol and integration documentation. |

The app never contains decision logic that the core could own. Platform adapters implement small core protocols
(`BluetoothCentral`, `NodeTransport`, `HelperTransport`, `HTTPTransport`), so every state machine is tested against
mocks, including permission failures that cannot be reproduced on a simulator.

## Backends

Sentinel separates three backends, and a control only appears as working when its backend has proved it:

| Backend | Reached how | Proven by |
| --- | --- | --- |
| Standard iOS | Public APIs in the app sandbox | The operation itself succeeding (path update, parsed file, BLE advertisement, HTTP response, completed network check) |
| Jailbreak helper | Loopback TCP to a separately installed helper (`docs/HELPER_INTERFACE.md`) | Mutual HMAC authentication **and** a capability report; only operations in the v1 allowlist count |
| External node | WebSocket to a node you operate (`docs/NODE_PROTOCOL.md`) | Authenticated v2 handshake whose MAC covers the capability report; data from `simulated` nodes never verifies anything |

Jailbreak markers (package managers, filesystem paths, sideloading) are not checked and would not count. Monitor
mode, packet injection and radio control are not operations of either protocol; names like these in a helper report
or node feature list are ignored.

Own-device filtering is offered only when an authenticated helper reports `setFilterRules`; otherwise the Request
Composer screen explains the missing requirement. Nearby Wi-Fi discovery is offered only when an authenticated node
offers `wifi_scan`; stock iOS has no API for it.

## Switches

| Setting | Enables | Turning it off |
| --- | --- | --- |
| Scanning | Starting Bluetooth LE scans; requesting Wi-Fi scans from a node | Stops a Bluetooth scan at once; cancels a pending Wi-Fi scan request |
| Remote connections | Connecting to the node; probing the helper; sending test requests; running Exposure Check | Closes node and helper sessions; cancels a request in flight and a running Exposure Check |
| Animation | Status pulses and the moving light line | Makes them static (Reduce Motion also turns them off) |

All default to off except Animation. Turning a switch on starts nothing by itself. Check My Network is separate: it
runs only when Start is pressed and contacts only the documented test endpoints (`docs/NETWORK_CHECK.md`).

## Capability tiers

Every feature belongs to exactly one tier (`CapabilityTier`):

1. **On this device** – supported iOS APIs in the app sandbox: connection diagnostics, capture-file inspection,
   Bluetooth LE discovery, the test request composer.
2. **External Mac or radio node** – Sentinel only connects to equipment you operate: the radio node link, spectrum
   from node hardware, and the future Mac debugging proxy.
3. **Privileged helper** – a separately installed helper on a compatible device: the helper link, and the future
   device-wide capture and traffic filtering operations.

A fourth tier, **Feasibility research**, lists satellite access, radio or baseband modification and Apple Watch
scanning. They are recorded only so their status is visible: none is implemented, none can be enabled or verified,
and they are left out of the dashboard's "confirmed" count.


## Four facts per capability

`CapabilityRegistry` tracks, independently, for each capability:

| Fact | Type | Set by |
| --- | --- | --- |
| Implementation included | `ImplementationStatus` (`included`, `interfaceOnly`, `notIncluded`) | Fixed in `CapabilityCatalog`. |
| Environment supports it | `EnvironmentSupport` (`supported`, `unsupported(reason)`, `unknown(reason)`) | Observed platform state, e.g. Bluetooth permission. |
| User enabled it | `Bool` | Settings. |
| Verified by an operation | `VerificationStatus` (`unverified`, `verified(at:evidence:)`, `failed(at:reason:)`) | Only `recordVerified`, called from the completion of a real operation. |

Rules enforced in code and by tests:

* `recordVerified` is refused when the capability is `interfaceOnly`/`notIncluded`, not enabled, or unsupported.
* Disabling a capability, or the environment becoming unsupported, clears its verification.
* Verification lasts for the app session only; nothing is remembered as "verified" across launches.
* `PrivilegeAssessment` models jailbreak-related signals. Package-manager presence, sideloading, a filesystem
  marker or the user's own assertion are *hints*; none of them, alone or combined, produce a verified state. Only an
  authenticated helper session that answers a capability report does. The app collects no such hints at all today.

What counts as verification:

| Capability | Evidence |
| --- | --- |
| Connection diagnostics | iOS delivered an `NWPathMonitor` update. |
| Capture file inspection | A file parsed successfully. |
| Bluetooth LE discovery | The first advertisement arrived during a user-started scan. |
| Test request composer | The selected endpoint returned an HTTP response. |
| Radio node link | The protocol handshake completed. |
| Spectrum from node hardware | A valid frame from a node that declares real (non-simulated) hardware. |
| Helper link | Mutually authenticated session **and** a capability report with a valid MAC. |
| Mac proxy, device-wide capture, filtering | Cannot be verified: interface only. |

## Preview mode

Preview mode shows fabricated data (three Bluetooth devices, a seven-packet capture, a static spectrum curve) under a
"PREVIEW MODE — DEMONSTRATION DATA" banner. Turning it on stops running operations and disables scanning, sending and
connecting. Preview data never reaches the activity log, the capability registry or storage. Outside Preview mode the
app displays only what it actually observed; an empty list stays empty.

## Operational control

`OperationsCoordinator` holds a handle for each Sentinel-owned activity (Bluetooth scan, test request, node session,
helper session, capture import). **Stop All Operations** calls each active handle's `stop`. It has no reference to the
capture store or settings, so it cannot delete data, and it uses no API that affects system Bluetooth, Wi-Fi or other
apps.

## Security Lab

`SentinelCore/SecurityLab` holds the shared assessment model (`SecurityAssessmentRecord`, five check outcomes,
severity and confidence kept separate, limits, execution location, report store and redacted renderer), the scope
policy (`TargetScope`, `AddressClassifier`) and the three modules. Each module is a blocking engine driven by an
`AssessmentControl` (cancellation, overall deadline). `SecurityLabModel` in the app runs one engine at a time on a
background queue and publishes progress measured in real work. Exposure Check needs the **Remote connections**
switch, and turning it off cancels a running check. The Authentication Defense Lab service listens on loopback only
and is registered with Stop All Operations. See [SECURITY_LAB.md](SECURITY_LAB.md) and, for the planned HCG Server
execution backend, [SECURITY_LAB_SERVER.md](SECURITY_LAB_SERVER.md).

## Process boundaries

* All capture parsing, radio data handling and helper communication run inside the Sentinel app process (or, in the
  future, inside a node or helper process).
* Nothing is injected into SpringBoard or any other process. A future Nexus integration is limited to opening
  navigation deep links and reading a status snapshot (`docs/NEXUS_INTEGRATION.md`).
* The Mac debugging proxy (`docs/MAC_PROXY_ADAPTER.md`), capture-file inspection and helper filter rules are three
  separate concepts with separate types; none depends on another.

## Data handling

| Data | Where | Lifetime |
| --- | --- | --- |
| Settings | `UserDefaults` (JSON) | Until changed. No secrets. |
| Node token, helper pairing key | Keychain, this device only | Until removed in Settings. |
| Imported captures | `Application Support/Captures`, excluded from backups, file-protected | Per retention setting; explicit delete. |
| Activity history | Memory (300 entries), redacted on entry | Until the app closes or it is cleared. |
| Check My Network results | Memory | Until the next run or the app closes. |
| Node and helper pairing keys | Keychain, this device only | Until removed in Settings. |
| Diagnostic log | `Application Support/Diagnostics`, ~500 KB cap, redacted | Only when enabled; explicit delete. |
| Request drafts and responses | Memory | Until the app closes. |

Sentinel does not install certificates or profiles, change proxy/VPN/DNS settings, register background modes, or
start anything at launch other than passive path monitoring.
