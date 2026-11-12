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
| `Tools/` | Local test service, mock radio node, synthetic capture generator, project and icon generators. |
| `Helper/` | Packaging notes for the optional privileged helper. No helper code or binary exists. |
| `docs/` | Build, test, protocol and integration documentation. |

The app never contains decision logic that the core could own. Platform adapters implement small core protocols
(`BluetoothCentral`, `NodeTransport`, `HelperTransport`, `HTTPTransport`), so every state machine is tested against
mocks, including permission failures that cannot be reproduced on a simulator.

## Capability tiers

Every feature belongs to exactly one tier (`CapabilityTier`):

1. **On this device** – supported iOS APIs in the app sandbox: connection diagnostics, capture-file inspection,
   Bluetooth LE discovery, the test request composer.
2. **External Mac or radio node** – Sentinel only connects to equipment you operate: the radio node link, spectrum
   from node hardware, and the future Mac debugging proxy.
3. **Privileged helper** – a separately installed helper on a compatible device: the helper link, and the future
   device-wide capture and traffic filtering operations.

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
| Diagnostic log | `Application Support/Diagnostics`, ~500 KB cap, redacted | Only when enabled; explicit delete. |
| Request drafts and responses | Memory | Until the app closes. |

Sentinel does not install certificates or profiles, change proxy/VPN/DNS settings, register background modes, or
start anything at launch other than passive path monitoring.
