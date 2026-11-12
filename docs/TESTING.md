# Testing

## Automated tests

| Suite | Runs on | Covers |
| --- | --- | --- |
| `SentinelCoreTests` | macOS and Linux via `swift test`; iOS simulator via the scheme | Capture parsing and malformed input, packet decoding, capture store and retention, capability rules, redaction, activity log, request validation/preview/state, Bluetooth scan state machine including permission failures, node protocol and session, helper crypto/handshake/validation, Stop All, settings, deep links. |
| `HCGSentinelTests` | iOS simulator (hosted in the app) | Wiring between settings, tools and the capability registry; Preview mode isolation; router behaviour. |

All test inputs are synthetic and built in code (`SyntheticCapture`, RFC 5737/3849 documentation addresses). No real
capture, token or endpoint is stored in the repository.

### Local test service

The request integration tests run only when `SENTINEL_TEST_SERVICE_URL` is set; otherwise they are skipped.

```bash
python3 Tools/local_test_service.py --port 8080
```

```bash
SENTINEL_TEST_SERVICE_URL=http://127.0.0.1:8080 swift test --package-path SentinelCore
```

### Robustness sweeps

`CaptureParserTests` parses every possible truncation of valid pcap/pcapng files, 3 000 randomly corrupted files
and 800 random byte strings behind valid signatures, and decodes every packet that survives. The seed is fixed, so
failures reproduce.

## Simulator checks (iPhone and iPad)

The simulator has no Bluetooth radio and no document provider with your files, so some checks are device-only.

1. Launch on an iPhone simulator. Dashboard shows the model identifier, "Simulator", a connection card, 0 verified
   capabilities rising to 1 (connection diagnostics) within a moment, "Nothing is running" and an activity entry.
2. Launch on an iPad simulator in landscape: a sidebar replaces the tab bar. Put the app in Split View at one-third
   width: it switches to the tab layout.
3. Settings › turn **Animation** off: the light line and pulses stop. Turn it on, then enable Reduce Motion in the
   simulator's Accessibility settings: they stay stopped.
4. Increase the text size (Settings › Accessibility › Larger Text): text wraps instead of truncating.
5. Bluetooth Explorer › Start scanning with the setting off: "Bluetooth scanning is off" with a button to Settings.
   Enable it and start again: on the simulator this reports "Bluetooth LE is not available" — that is correct.
6. Request Composer:
   * Start the local test service on the Mac (`--port 8080`). The simulator shares the Mac's loopback.
   * Settings › HCG test endpoint › `http://127.0.0.1:8080` › Use this endpoint.
   * Set method `POST`, path `/echo?token=abc`, add header `Authorization: Bearer secret`, body `{"password":"x"}`.
   * Review request…: the sheet lists the changes from the template and the exact request. Send.
   * The response shows 200, timing, headers and the echoed body.
   * Dashboard › Recent activity shows the request with `token=[REDACTED]` and no header or body contents.
   * Path `/status/503` shows a 503. Path `/redirect` shows a 302 that was not followed. Path `//example.com/`
     is refused before sending.
7. Radio Lab:
   * `python3 Tools/mock_radio_node.py` on the Mac.
   * Settings › Allow node connection, address `ws://127.0.0.1:8765/`, Save address.
   * Radio Lab › Connect: node "mock-node", data source "Simulated (no radio)". Start spectrum stream: the plot is
     labelled "SIMULATED NODE DATA". Capabilities shows the node link verified and hardware spectrum **not** verified.
   * Stop the mock node: the session reports failure. Restart it with `--token t` and connect without a token: the
     node's rejection is shown.
8. Network Inspector: drag `synthetic.pcap` (from `python3 Tools/make_synthetic_capture.py out`) onto the simulator
   to add it to Files, then Import. Six packets, "IMPORTED FILE" banner, packet detail with layers and hex. Import
   `truncated.pcap` (warning shown, five packets) and `not-a-capture.pcap` (clear error).
9. Settings › Preview mode: banners appear, the three Bluetooth devices are tagged "Demo", scanning and sending are
   disabled. Turn it off: demo data disappears and Capabilities shows nothing newly verified.
10. Start a spectrum stream, then Stop All Operations: the alert lists what stopped; saved captures are still listed.
11. `xcrun simctl openurl booted hcgsentinel://open/bluetooth` navigates; `hcgsentinel://open/bluetooth?start=1`
    does nothing.

## Physical-device checks

Run the same list on each device, plus the device-only items below. Record results in `docs/VALIDATION.md`.

### iPhone 13 Pro Max (iOS 17.4) and iPhone X (iOS 14.7)

1. First launch: **no permission prompt appears**.
2. Bluetooth Explorer › enable scanning in Settings › Start scanning: iOS asks for Bluetooth permission once.
   * Allow: nearby advertisers appear with identifier, name/services where advertised, RSSI and last-seen time;
     Capabilities shows Bluetooth LE discovery verified.
   * The scan stops at the configured time limit and when you tap Stop.
   * Turn Bluetooth off in iOS Settings during a scan: the scan stops with "Bluetooth is turned off"; turning it
     back on does not restart the scan.
   * Deny permission (or revoke it in iOS Settings): "Bluetooth permission denied" with a link to iOS Settings.
3. Network Inspector › Import: choose a pcap/pcapng from Files or iCloud Drive. Check retention: with "Do not save
   imports" nothing appears under Saved captures; with 7 days it does and survives relaunch; Delete removes it.
4. Request Composer against the test service on your Mac: run it with `--host 0.0.0.0`, use
   `http://<Mac LAN address>:8080`. iOS asks for Local Network permission on first send. Deny it once to confirm
   the failure is reported clearly.
5. Radio Lab against the mock node on your Mac (`--host 0.0.0.0`).
6. Layout on the iPhone X (5.8-inch, smallest target): no clipped text on Dashboard, Capabilities and Settings at the
   default and at the largest non-accessibility text size.
7. iOS 14.7 specifically: tab bar and navigation bars are opaque obsidian, the request body editor has a dark
   background, sheets (Settings, Capabilities, Review request) open and close, pushing into a packet works.
8. Background the app during a scan and a stream, return: states are accurate (iOS may have stopped the scan).

### iPad

Sidebar layout in full screen, tab layout in Slide Over, rotation, and Split View resizing while a capture is open.

### Privileged helper

There is nothing to deploy. Settings › Allow helper probing › save any 64-hex-digit key › Probe for helper should
report that nothing answered on 127.0.0.1, and Capabilities should show the helper link as failed/unverified, never
verified.
