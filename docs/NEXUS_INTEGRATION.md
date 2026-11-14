# Future Nexus integration

Nexus (the HCG home-screen surface) should offer **shortcuts and status only**. Capture, radio processing and
privileged operations must never run inside SpringBoard or any process other than Sentinel, a radio node, or the
helper daemon.

Nothing Nexus-specific is implemented. Two small building blocks exist for it:

## 1. Navigation deep links (implemented)

```
hcgsentinel://open/dashboard
hcgsentinel://open/network
hcgsentinel://open/networkCheck
hcgsentinel://open/securityLab
hcgsentinel://open/bluetooth
hcgsentinel://open/radio
hcgsentinel://open/requests
hcgsentinel://open/capabilities
hcgsentinel://open/settings
```

Security Lab reports have their own review link:

```
hcgsentinel://report/<report-uuid>
```

It opens Security Lab with that stored report on top, or a "Report not found" screen. It never starts an assessment;
reports are only produced by pressing Start inside Sentinel.

`DeepLink.target(from:)` accepts exactly these. Links with a query, fragment, extra path component or any other
host are rejected. There is deliberately **no** link that starts a scan, sends a request, connects to a node,
changes a setting or deletes data, so a shortcut can never trigger an operation: the user always lands on a screen
and decides there.

## 2. Status snapshot (type defined, not yet published)

`NexusStatusSnapshot` (schema version 1):

| Field | Meaning |
| --- | --- |
| `schemaVersion` | 1 |
| `generatedAt` | When the snapshot was produced. |
| `activeOperations` | Titles such as "Bluetooth scan". |
| `verifiedCapabilities` / `totalCapabilities` | Counts only. |
| `previewMode` | Whether demonstration data is showing. |

| `recentAssessments` | Optional (additive): up to five Security Lab report references: id, module, status, times, finding count and highest severity. No scope, evidence or findings. |

It carries no addresses, packet data, endpoints, findings or credentials; report contents stay in Sentinel. The app does not write it anywhere yet.

## Decisions needed before building it

* **How Nexus reads status.** For a stock-iOS widget: a WidgetKit extension reading the snapshot from an App Group
  container. For a jailbreak tweak: the tweak reads the same file; it must not load Sentinel code into SpringBoard.
* **Staleness.** Nexus must show the snapshot's age and treat anything older than a few minutes as "unknown" rather
  than "idle", because Sentinel may have been terminated.
* **Stop control.** If Nexus is to offer "Stop All", it should open Sentinel on the dashboard (where the button is)
  rather than act in the background.
