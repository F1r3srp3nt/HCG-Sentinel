# Testing

## Automated tests

| Suite | Runs on | Covers |
| --- | --- | --- |
| `SentinelCoreTests` | macOS and Linux via `swift test`; iOS simulator via the scheme | Capture parsing and malformed input, packet decoding, capture store and retention, capability rules, redaction, activity log, request validation/preview/state, Bluetooth scan state machine including permission failures, node protocol and session, helper crypto/handshake/validation, Stop All, settings, deep links. Security Lab: assessment model and redacted export, report store, scope policy and address classification, DEFLATE/zip/tar decoding with bombs and zip-slip, Secret Scanner detection/false positives/redaction/suppression/symlinks/limits/cancellation, Exposure Check with a mock transport and against the local exposure service (TLS refusal, out-of-scope redirects, timeouts, cancellation, body cap), Authentication Defense Lab service and assessment over real loopback HTTP (lockout, throttling, error messages, logging, attempt cap, cancellation, time limit). |
| `HCGSentinelTests` | iOS simulator (hosted in the app) | Wiring between settings, tools and the capability registry; Preview mode isolation; router behaviour; Security Lab switches, report links, Stop All of the lab service, a full lab assessment through the app model, snapshot references. |
| `Tools/test_hcg_server_assessment_harness.py` | Any Python 3 | The proposed HCG Server Security Lab contract: device authorisation, cross-device report denial, execution-side scope validation, redirects, cancellation. |

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

### Security Lab services

The live Exposure Check tests run only when the exposure service URLs are set:

```bash
python3 Tools/exposure_test_service.py --http-port 8081 --https-port 8444
```

```bash
SENTINEL_EXPOSURE_HTTP=http://127.0.0.1:8081 SENTINEL_EXPOSURE_HTTPS=https://127.0.0.1:8444 swift test --package-path SentinelCore
```

The Authentication Defense Lab tests start the bundled lab themselves on a random loopback port. The HCG Server
contract harness tests need nothing else:

```bash
python3 -m unittest -v Tools/test_hcg_server_assessment_harness.py
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
5. Bluetooth Explorer › Start scanning with **Scanning** off: "Scanning is off" with a button to Settings. Turn it
   on and start again: on the simulator this reports "Bluetooth LE is not available" — that is correct.
6. Request Composer:
   * Start the local test service on the Mac (`--port 8080`). The simulator shares the Mac's loopback.
   * Settings › turn on **Remote connections**; Request testing › add `http://127.0.0.1:8080`.
   * Set method `POST`, URL `http://127.0.0.1:8080/echo?token=abc` (or just `/echo?token=abc`), add header
     `Authorization: Bearer secret`, body `{"password":"x"}`.
   * Review request…: the sheet lists the changes, the exact request and which endpoint allowed it. Send.
   * The response shows 200, timing, headers and the echoed body; switch the body between Text, JSON and Hex.
   * Dashboard › Recent activity shows the request with `token=[REDACTED]` and no header or body contents.
   * `/status/503` shows a 503; `/redirect` a 302 that was not followed; `https://example.com/` is refused before
     sending because it is not an allowed endpoint.
   * Turn Remote connections off while `/delay/20` is in flight: the request is cancelled.
   * Own-device filtering (bottom of the screen) explains that no helper is verified and offers no controls.
7. Radio Lab:
   * `python3 Tools/mock_radio_node.py` on the Mac; note the pairing key it prints.
   * Settings › Remote connections on; External analysis node › address `ws://127.0.0.1:8765/`, Save address;
     paste the pairing key, Save key.
   * Radio Lab › Connect: "Connected (authenticated)", node "mock-node", data source "Simulated (no radio)",
     recognised features `spectrum, wifi_scan`.
   * Start spectrum stream: the plot is labelled "SIMULATED NODE DATA". With Scanning on, Request Wi-Fi scan: three
     `SIMULATED-…` networks labelled "Simulated node data". Capabilities shows the node link verified, and hardware
     spectrum and nearby Wi-Fi discovery **not** verified.
   * Turn Scanning off during a scan request: it is cancelled. Turn Remote connections off: the session closes.
   * Save a different (wrong) pairing key and connect: "could not prove it holds the pairing key"; nothing from the
     node is shown. Restart the mock with `--no-wifi`: the Wi-Fi card says the node does not offer scanning.
8. Check My Network (Dashboard tile, or Network Inspector › Check My Network):
   * Start: the progress shows each step; finished results list findings with evidence, time, limitations and
     remediation. The headline never says the network is safe.
   * Start and press Cancel during the HTTPS steps: "Check cancelled…", remaining steps "Not checked".
   * Turn the Mac's Wi-Fi off (simulator offline) and run: "No network connection", network steps "Not checked",
     no security concerns.
   * On the simulator, Wi-Fi name and security are reported **unavailable** with the reason.
9. Network Inspector: drag `synthetic.pcap` (from `python3 Tools/make_synthetic_capture.py out`) onto the simulator
   to add it to Files, then Import. Six packets, "IMPORTED FILE" banner, packet detail with layers and hex. Import
   `truncated.pcap` (warning shown, five packets) and `not-a-capture.pcap` (clear error).
10. Settings › Preview mode: banners appear, the three Bluetooth devices are tagged "Demo", scanning and sending are
   disabled. Turn it off: demo data disappears and Capabilities shows nothing newly verified.
11. Start a spectrum stream, then Stop All Operations: the alert lists what stopped; saved captures are still listed.
12. `xcrun simctl openurl booted hcgsentinel://open/bluetooth` navigates; `hcgsentinel://open/bluetooth?start=1`
    does nothing.

## Physical-device checks

Run the same list on each device, plus the device-only items below. Record results in `docs/VALIDATION.md`.

### Which build goes on which phone

| Phone | Build to install | Notes |
| --- | --- | --- |
| iPhone X, iOS 14.7 | Scheme `HCGSentinel` only | `HCGSentinelModern` (iOS 15+) will be refused by the phone. Recent Xcode versions may not attach a debugger to iOS 14; install the IPA instead (see `docs/BUILDING.md`). |
| iPhone 13 Pro Max, iOS 17.4 | Either scheme | Enable Developer Mode first (Settings › Privacy & Security › Developer Mode). |

Before installing, confirm what you built:

```bash
Tools/build.sh inspect
```

It must show `minos 14.7` for the iPhone X. Both phones' UDIDs must be in the development provisioning profile.

### iPhone X (iOS 14.7) — do these first

This is the configuration that has never been executed anywhere, so start here.

1. The app installs and launches to the Dashboard (a launch crash here would point at an API newer than iOS 14).
2. Tab bar and navigation bars are opaque obsidian; text is readable on the 5.8-inch screen at the default and the
   largest non-accessibility text size, on Dashboard, Capabilities and Settings.
3. Each tab opens. From the Dashboard, the gear opens Settings as a sheet and the capability card opens
   Capabilities as a sheet; both close with Done.
4. Network Inspector › import a capture › tap a packet: the detail screen pushes and the back button returns.
5. Request Composer: the body editor has a dark background (not white); Review request… opens and Cancel closes it.
6. Then run the common checklist below.

### iPhone 13 Pro Max (iOS 17.4)

1. Developer Mode is on; the app installs and launches.
2. Run the common checklist below.
3. If you built both variants, install `HCGSentinelModern` over `HCGSentinel` once: it is the same app (same bundle
   identifier), so settings and saved captures must still be there.

### Common checklist (both phones)

1. First launch: **no permission prompt appears**.
2. Bluetooth Explorer › enable scanning in Settings › Start scanning: iOS asks for Bluetooth permission once.
   * Allow: nearby advertisers appear; Capabilities shows Bluetooth LE discovery verified.
   * Names: a device you know (headphones, a watch, a Mac) shows its advertised name; others show
     "Name not broadcast" in italics. Open one: the Name card says where the name comes from.
   * Keep the same device in range for a minute: its row stays one entry, the name does not disappear when later
     advertisements omit it, and "Last heard" keeps updating. Signal strength shows dBm and the last readings' range.
   * Label a device ("Desk speaker"), relaunch Sentinel, scan again: the label is still there.
   * Filters: "Only devices that broadcast a name", "−70 dBm or stronger" and search by a service name narrow the list.
   * Stop, then Scan again: the pill reads "Scan 2 live", devices heard again show "This scan", the rest "Earlier scan".
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
9. Security Lab › Secret Scanner: pick a folder from Files (On My iPhone and iCloud Drive) and a .zip containing a
   synthetic `.env` with `DB_PASSWORD=<random>`. The finding shows file and line, the value is redacted, Export shows
   no secret, "Mark as false positive" hides it on the next scan.
10. Security Lab › Exposure Check (Remote connections on): an HTTPS site you own; a self-signed service on your LAN
    marked local (certificate finding, nothing bypassed); turn Remote connections off mid-run (it stops).
11. Security Lab › Authentication Defense Lab: start the lab, run with defaults (lockout passes), then turn lockout and
    rate limiting off (verified findings); background the app during a run and return (the run stops or completes,
    never silently continues against anything other than the loopback lab).

### iPad

Sidebar layout in full screen, tab layout in Slide Over, rotation, and Split View resizing while a capture is open.

### Privileged helper

There is nothing to deploy. Settings › Allow helper probing › save any 64-hex-digit key › Probe for helper should
report that nothing answered on 127.0.0.1, and Capabilities should show the helper link as failed/unverified, never
verified.
