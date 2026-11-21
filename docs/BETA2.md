# HCG Sentinel Unleashed 0.1.0~beta2

Development beta for HCG Repo Candidate, built from branch `claude/festive-shannon-1nfggt`. **Not published.** It
goes to HCG Repo only after the owner approves this exact package (see [Release proposal](#release-proposal)).

| Item | Value |
| --- | --- |
| Public name | HCG Sentinel Unleashed (package `Name`, About screen, dashboard, documentation) |
| Home Screen name | Sentinel (`CFBundleDisplayName`, unchanged) |
| Package ID | `com.hakmicapitalgroup.hcgsentinel` (unchanged) |
| Bundle ID | `com.hcg.sentinel` (unchanged) |
| Version | `0.1.0~beta2` (beta1 is `0.1.0~beta1`; no other beta exists in HCG Repo, Maker or this repository). App: 0.1.0, build 2 |
| Install path | `/var/jb/Applications/HCGSentinelModern.app` (same as beta1) |
| Entitlements | None, the same as beta1. The CI build fails if any appear |
| Maintainer scripts | Maker's generated `postinst` (`uicache -p`) and `postrm` (`uicache -u`), byte-identical to beta1. The CI build compares them |
| Built by | `.github/workflows/beta-package.yml`, running HCG Executable Maker's Unleashify packager (`feature/unleashify`, `c074245`), the code that built beta1 |

## 1. Bluetooth: root-cause analysis

Beta1 is HCG-Sentinel `490858c` (HCG Repo's provenance record). Inspecting that source and the installed package
found the following. The owner reported "not functioning correctly" without the screen's text, so the table says what
the code proves and what only a device can confirm.

| Area checked | Finding in beta1 | Effect | Beta2 |
| --- | --- | --- | --- |
| Interface used | Core Bluetooth `CBCentralManager`, `scanForPeripherals(withServices: nil)`. No private API, no mock data in release builds (the fixture radio is `#if DEBUG` only) | Correct mechanism | Unchanged |
| Scanning master switch | Settings › Scanning defaults to **off**. Pressing Start on the Bluetooth screen only showed "Scanning is off" with a link to Settings | **Most likely cause.** The first scan never reaches iOS until the user finds the switch in Settings | Bluetooth screen offers "Turn on scanning and start" (one tap, same switch) |
| Duplicate reports | `bluetoothContinuousUpdates` defaulted to off, so `CBCentralManagerScanOptionAllowDuplicatesKey` was false | iOS reports each device about once per scan: signal strength and "last seen" never change, so the list looks frozen | On by default; beta1 settings migrate once (settings schema 2). Scans remain user-started and time-limited |
| State transitions | Scanning starts only after `centralManagerDidUpdateState` reports `.poweredOn`; `.unknown` waits | Correct, but with no time limit | If iOS reports no usable state within 20 s, the scan ends with **"Bluetooth did not respond"** and the last state and permission iOS reported |
| Authorization | Reads `CBCentralManager.authorization` (no prompt). `NSBluetoothAlwaysUsageDescription` is present in the packaged Info.plist | Correct. Denied and restricted show their own screens | Unchanged; also shown on the dashboard without creating a manager |
| Filters | `withServices: nil` (no UUID restriction). The list filters (named, labelled, connectable…) are off by default and the screen says "Showing N of M" when on | No devices hidden by default | Unchanged |
| Lifecycle | No `bluetooth-central` background mode (correct for a foreground tool); a scan was left "running" when the app was backgrounded | Results stop arriving in the background while the screen still says Scanning | A scan stops with a logged reason when Sentinel leaves the foreground |
| Classic Bluetooth | Not expected anywhere in the code | iOS gives apps BLE advertisements only; classic devices and devices already connected to the phone never appear | The screen now says so explicitly |
| Device-specific | The jailbreak package has **no entitlements**, like beta1. Core Bluetooth needs none, but an app installed outside the App Store depends on iOS's privacy service (TCC) recognising it | Not verifiable without the phone | The new **Bluetooth diagnostics** card records what iOS actually reported (states, permission, counts, times; no device data) and can be copied into a report |

**Not claimed:** that beta1 failed for one specific reason. If beta2 still finds nothing, the diagnostics card says
whether iOS never answered (state stays `unknown`), refused (`unauthorized` / `denied`), reported the radio off, or
answered but delivered no advertisements. That is enough to decide the next fix.

## 2. BLE discovery (implemented)

Start, stop, scan duration (30 s – 5 min or no limit), clear results, device list with name (only when the device
broadcasts one, or your own label), iOS's per-app peripheral identifier, signal strength (RSSI) and history, first and
last seen, advertised services, service data, manufacturer data, connectable flag and TX power: everything Core
Bluetooth exposes. Permission, Bluetooth off, unsupported, restarting, no response, starting, scanning, nothing heard and
stopped each have their own status. Sentinel never pairs, connects or reads characteristics.

## 3. Wi-Fi diagnostics (implemented: current connection)

Network tab › Network tools › **Wi-Fi**: connection status and interface name (`NWPathMonitor`); IPv4 address, prefix
and netmask (`getifaddrs`); IPv6 addresses; default gateway (`NWPath.gateways`); IPv4 / IPv6 availability; whether a
DNS resolver is available; a session log of connection changes.

- **SSID / BSSID:** asked from iOS only when you tap the button (`NEHotspotNetwork.fetchCurrent`). iOS answers only for
  apps with the Access Wi-Fi Information entitlement and location permission; this build has neither, so it reports
  "unavailable" with that reason. Adding the entitlement is a security-relevant change and is **not** made silently: see
  limitation L3.
- **DNS servers:** iOS has no public API for the configured resolver addresses; the screen says so. Check My Network
  tests resolution instead.

## 4. Nearby Wi-Fi discovery: feasibility

| Route | Feasible? | Notes |
| --- | --- | --- |
| Standard iOS app | **No** | No public API lists nearby networks. `NEHotspotHelper` needs an entitlement Apple grants only to hotspot operators. CoreWLAN is macOS-only. |
| Jailbroken iPhone, inside the app | Not recommended | Would need private `MobileWiFi` symbols and `com.apple.wifi.manager-access`-class entitlements on the app itself, giving the whole UI process Wi-Fi management rights. |
| Jailbroken iPhone, separate privileged helper | **Feasible, not built** | A small launchd daemon (rootless, `/var/jb`) holding the Wi-Fi entitlement, exposing one read-only operation over the existing authenticated helper protocol (`docs/HELPER_INTERFACE.md`): `wifi.scan` → list of {SSID, BSSID, channel, RSSI, security}. |

Rules for that helper, if it is approved later: started only by an explicit user action; read-only (no join, no
disconnect, no deauthentication, no password access, no keychain); one scan per request with a rate limit; loopback
only with a pairing key; its own package that the owner approves and installs manually; it reports unsupported
firmware instead of guessing. What is needed to build it: the target device's iOS version and the private framework
symbols for that version, tested on that device. **Nothing of this is in beta2**, and the app never shows nearby
networks.

## 5. Local network discovery (implemented)

Network tools › **Local Network**:

- **Bonjour** (`NWBrowser`, 22 service types declared in `NSBonjourServices`), 20 s per browse, then mDNS resolution to
  host name and addresses (`NetService.resolve`, no connection to the device). Results show service name and type
  (labelled as announced by the device, not verified), host name, addresses, discovery method and last seen. A refused
  local network permission is shown as such.
- **Authorised sweep:** you enter a range (pre-filled with the /24 of your Wi-Fi address) and confirm that the network
  is yours or that you are authorised to test it. Refused unless the range is private (10/8, 172.16/12, 192.168/16,
  169.254/16), at most a /24, and inside a network the iPhone is on now. The iPhone's own address is skipped. Per
  address: one ICMP echo, then one TCP connection attempt to 80, 443, 22 and 445 until one answers; 4 addresses at a
  time (hard cap 8); nothing retried. Answers are **verified** (with method and time); reverse DNS names are labelled
  as coming from DNS; addresses that did not answer are listed as "no response", which the screen says is not proof
  that nothing is there.

## 6. Ping and reachability (implemented)

Network tools › **Ping**: IP address or host name; **ICMP Echo** over an unprivileged ICMP datagram socket (the same
mechanism Apple's SimplePing uses, so no helper or root is needed), IPv4 and IPv6; or a **TCP connect test** to a port,
always labelled "not ICMP". 1–100 probes, interval 1/2/5 s (never below 1 s), timeout 1/2/5 s, one probe in flight,
Stop at any time. Shows each probe (reply time, timeout, error), answered/sent, packet loss, min/avg/max, the address
actually used and the others DNS returned. DNS failures ("not found" vs resolver failure), "no route to host" and
similar errors are shown in plain words. History of the session's runs is kept in memory only.

## 7. Branding

"HCG Sentinel Unleashed" in the package name (Sileo, Zebra and HCG Repo show the package `Name`), the description, the
dashboard (HCG mark | SENTINEL with UNLEASHED under the moving divider), Settings › About and this documentation. The
Home Screen label stays **Sentinel**. Logo and design language unchanged. Changing the name in the app's binary needs a
new build, so it is in beta2; beta1 is not touched.

## 8. Installation and respring

Facts from beta1's package: `Depends: firmware (>= 15.0), uikittools`; `postinst` runs
`uicache -p "/var/jb/Applications/HCGSentinelModern.app"` on configure and prints a message on stderr if that fails;
`postrm` runs `uicache -u` on remove/purge; nothing else runs; no SpringBoard injection. This is the supported
registration route for rootless apps, and HCG Repo's validator requires exactly these scripts, so beta2 keeps them
byte-identical.

Why the owner needed a respring is **not determined**: there is no install log or `uicache -l` output from the phone.
Possible causes, in the order to check them:

1. `uicache` was not on the package manager's `PATH` when `postinst` ran, so registration failed with the stderr
   message (Sileo shows it in the install log). Check: the log line "HCG: uicache could not register…".
2. The registration succeeded but SpringBoard did not refresh its icon list until the respring. Check:
   `uicache -l | grep com.hcg.sentinel` right after installing, before respringing.
3. Another build with bundle ID `com.hcg.sentinel` (from Xcode or an IPA) was installed, so LaunchServices kept that
   one. Check: `uicache -l | grep com.hcg.sentinel` lists two paths.

The device checklist (step 1) records exactly these outputs. Sentinel never resprings anything. If the icon does not
appear after installing beta2, run `uicache -p /var/jb/Applications/HCGSentinelModern.app` over SSH (or in a terminal
app), and respring only if that does not help. A Maker change to print an explicit "icon registered" or "respring
needed" line after `uicache` is proposed in [Remaining limitations](#14-remaining-limitations-and-risks); it is not
made here, because HCG Repo's validator pins the current scripts.

## 9. HCG Connect

Checked again for this beta: Sentinel has **no** registered HCG Connect client, product ID, callback URI or
entitlement contract (details and the exact registration request in [HCG_CONNECT.md](HCG_CONNECT.md)). The HCG--Connect
repository attached to this session is a messaging project with only a README, not an identity service. So there is
no "existing registration" to reuse. Beta2 therefore:

- adds no sign-in code and does not reuse another HCG app's client (HCG Executable Maker's production client belongs to
  Maker);
- shows Settings › HCG account: "Not signed in · not available yet", with the reason;
- keeps every local tool working without an account. Local privileges (Bluetooth, local network, the future helper)
  are governed only on the device and can never be granted by an HCG account.

## 10. Automated test results

See [VALIDATION.md](VALIDATION.md#beta2-010beta2-21-november-2026), filled in from CI runs (not from expectations).

## 11. Physical-device checklist

[BETA_CHECKLIST.md](BETA_CHECKLIST.md), steps 1–18.

## 12. Package and checksum

Built by `beta-package.yml`; artifact `hcg-sentinel-unleashed-0.1.0-beta2-deb` (30-day retention) with the Candidate
handoff `hcg-sentinel-unleashed-0.1.0-beta2-handoff`. The SHA-256 is in VALIDATION.md and in the release proposal.

## Screenshots (Simulator, CI run on `680cb3f`)

iPad Simulator, from the same commit as the package: [dashboard](screenshots/beta2/ipad-dashboard.jpg),
[Network tools](screenshots/beta2/ipad-tools-network.jpg), [Wi-Fi](screenshots/beta2/ipad-tools-wifi.jpg),
[Local Network](screenshots/beta2/ipad-tools-local.jpg), [Ping](screenshots/beta2/ipad-tools-ping.jpg). The Ping
screenshot is a real ICMP run to the Simulator's loopback address: 5 of 5 answered, 0 % loss, 0.11 / 0.20 / 0.42 ms.
The Simulator has no Bluetooth or Wi-Fi radio; those screens prove layout and wording, not radio behaviour.

## Release proposal

See [release/0.1.0-beta2.md](release/0.1.0-beta2.md). Nothing is imported until the owner approves.

## 14. Remaining limitations and risks

| # | Limitation or risk |
| --- | --- |
| L1 | **No physical-device result.** CI has no iPhone. Bluetooth, Bonjour, the sweep, ICMP from a phone, Wi-Fi changes, respring behaviour and package-manager behaviour are untested until the checklist is run. |
| L2 | The jailbroken build has no entitlements. If iOS's privacy service does not prompt for or recognise the package-installed app, Bluetooth and local network will fail. The diagnostics card shows this; the fix would be a reviewed entitlement change, not a silent one. |
| L3 | SSID/BSSID need `com.apple.developer.networking.wifi-info` and location permission. Adding them needs the owner's review (it also adds a location prompt). Not done. |
| L4 | Nearby Wi-Fi needs a privileged helper. Designed above, not built. |
| L5 | ICMP datagram sockets are what SimplePing uses on iOS; behaviour on the specific jailbroken firmware is unverified. If it is refused, the Ping screen says so and offers the labelled TCP test. |
| L6 | A sweep can trigger alerts on managed networks; it is limited to private ranges the iPhone is on, after explicit confirmation, but the user remains responsible for authorisation. |
| L7 | Maker's `postinst` prints nothing on success. Proposal for Maker: after `uicache -p`, check `uicache -l` for the bundle ID and print "Sentinel registered with the Home Screen" or the exact recovery command. |
| L8 | Simulator tests cover the app's state logic with a fixture radio; they are not evidence of real radio behaviour. |
| L9 | HCG Connect sign-in cannot be built until HCG registers a client for Sentinel. |
| L11 | Seen in the Simulator screenshots: the dashboard labels Wi-Fi **Unsupported** when the device is simply not on Wi-Fi (for example wired or cellular); it should say Idle. Display only; fix in the next build. |
| L12 | Seen in the Simulator: the Wi-Fi screen's "IPv4 / IPv6" and "DNS" rows repeat what iOS's path monitor reports, which in the Simulator is "no IPv4 · no IPv6" even with an IPv4 address assigned. The rows should say the values come from iOS's path report. Display only; fix in the next build. |
| L10 | The GitHub artifact that holds the .deb expires after 30 days; HCG Repo's import must happen before that, or the workflow is re-run (the output is reproducible). |
