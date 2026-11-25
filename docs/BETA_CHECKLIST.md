# Physical-device checklist: HCG Sentinel Unleashed 0.1.0~beta2

For the owner's Dopamine-jailbroken iPhone (rootless). Nothing here is done automatically: no respring, no install, no
upload. Record each step as **pass**, **fail** (with what you saw) or **not tried**, plus the phone model, iOS version,
Dopamine version and package manager, in `docs/VALIDATION.md` under "Record your own results here". Only results
recorded there count as device evidence.

Commands below are typed over SSH or in a terminal app on the phone (`sudo` needs your mobile password).

**Before you start**
- Know a Bluetooth LE device that is advertising (a fitness tracker, a smart bulb, a second phone running a BLE
  advertiser app). Headphones and watches already connected to this iPhone do **not** appear: iOS hides them.
- Know the IP address of one device on your Wi-Fi that answers ping (usually your router: Wi-Fi screen › Default
  gateway).

| # | Test | Steps | Expected |
| --- | --- | --- | --- |
| 1 | **Installation and launch** | `uicache -l \| grep com.hcg.sentinel` (note the output). In Sileo or Zebra: refresh HCG Repo Candidate, install **HCG Sentinel Unleashed** 0.1.0~beta2 (an upgrade from beta1). Save the install log. Before respringing: `uicache -l \| grep com.hcg.sentinel` and `dpkg-query -W com.hakmicapitalgroup.hcgsentinel`. Then look for the icon. | Install log has no "HCG: uicache could not register" line. `uicache -l` lists exactly one path, `/var/jb/Applications/HCGSentinelModern.app`. dpkg shows `0.1.0~beta2`. The Home Screen icon is labelled **Sentinel**. Record whether it appeared **without** a respring. If not: run `uicache -p /var/jb/Applications/HCGSentinelModern.app`, and respring only if that does not help; record which one worked. Opening it shows the dashboard with HCG mark │ SENTINEL and UNLEASHED, no sign-in, status "Idle". |
| 2 | **Bluetooth permission** | Bluetooth tab. If it says "Scanning is off", tap **Turn on scanning and start**. | The iOS prompt names Sentinel and its reason. Tap Allow. The card goes Starting… → Scanning. If no prompt appears and the card ends with **Bluetooth did not respond**, open **Bluetooth diagnostics**, tap Copy and paste it into the result. |
| 3 | **BLE scan with a known device** | Scan near your known advertising device. Open it. | It appears within ~10 s. Signal strength keeps updating (continuous updates are on). The detail shows name source, services, signal history and last seen. Devices without a broadcast name show as **Unknown device**. |
| 4 | **Scan cancellation** | Tap Stop during a scan. Start again, then let it hit the time limit. | "Stopped · N devices listed"; results stay. The automatic stop happens at the limit shown. Diagnostics events list both stops. |
| 5 | **Bluetooth disabled** | Turn Bluetooth off in Control Centre (or Settings), then start a scan. | **Bluetooth is off**, nothing new listed, no crash. Turn it on and start again: it scans. |
| 6 | **Wi-Fi connected and disconnected** | Network tab › Wi-Fi. Turn Wi-Fi off, wait 5 s, turn it back on. | Connected: status Online via Wi-Fi, interface `en0`, IPv4, subnet, gateway. Off: "Not on Wi-Fi". Connection changes lists both transitions with times. |
| 7 | **Current network diagnostics** | Wi-Fi screen: compare with iOS Settings › Wi-Fi › (i). Tap **Ask iOS for the network name**. Run Check My Network. | IP address, subnet mask and router match iOS Settings. The SSID request says unavailable with the entitlement reason (expected for this build). Check My Network completes. |
| 8 | **Nearby Wi-Fi discovery** | Wi-Fi screen › Nearby Wi-Fi networks. | Shows **Unsupported** with the reason; no networks are listed. (Expected: this build has no helper.) |
| 9 | **Local Bonjour discovery** | Network tools › Local Network › Browse. | First time: iOS asks for local network access; Allow. Within 20 s services such as AirPlay, printers or HomeKit appear with type, host name and addresses. If refused: the card says so and links to iOS Settings. |
| 10 | **Authorised subnet discovery** | Local Network › range pre-filled with your /24. Try Start without confirming, then try `8.8.8.0/24` and `192.168.0.0/16`. Then confirm and sweep your own range. | Start is disabled until confirmed; the public and /16 ranges are refused with reasons. The sweep shows progress, the router and other devices under **Answered** with method and time; the rest under "No response" with the note that this is not proof of absence. Your own iPhone is not probed. |
| 11 | **ICMP ping to a reachable device** | Network tools › Ping: your router's IP, ICMP Echo, 10 probes. | 10 replies with times in ms; 0 % loss; min/avg/max. If it says ICMP is not available, record the exact message, then try the TCP connect test to port 80 or 443 and note it is labelled "not ICMP". |
| 12 | **Unreachable host** | Ping an unused address in your range (for example `.250`), 5 probes, 1 s timeout. | Each probe "no answer within 1 s" (or "No route to host"); 100 % loss; no crash. |
| 13 | **DNS failure** | Ping `sentinel-test.invalid`. | "DNS: … was not found"; no probes sent. |
| 14 | **Cancellation and cleanup** | Start a 100-probe ping and a sweep; tap Stop on each. Then start both again and use Dashboard › Stop All Operations. | Each stops within a second; the dashboard returns to Idle; Dashboard › Recent activity shows the stops. |
| 15 | **Background and foreground** | Start a Bluetooth scan and a ping, press the Home button, wait 10 s, return. | Both were stopped "because Sentinel moved to the background" (activity log); nothing is running; start again works. |
| 16 | **Respring and relaunch** | Respring (your usual way), then open Sentinel. Force-quit and open again. | Icon still present; the app opens; settings (Scanning switch, labels) are kept. |
| 17 | **HCG Connect authentication** | Settings › HCG account. | "Not signed in · not available yet" with the reason. No sign-in prompt anywhere; every tool works without an account. (A sign-in test is possible only after HCG registers a client.) |
| 18 | **Removal and rollback** | Rollback: in a terminal, `sudo dpkg -i <saved beta1 .deb>` (or install 0.1.0~beta1 from Sileo's version list if HCG Repo offers it), open the app, then reinstall beta2. Removal: remove **HCG Sentinel Unleashed** in the package manager. Then `uicache -l \| grep com.hcg.sentinel` and `ls /var/jb/Applications/HCGSentinelModern.app`. | Downgrade and upgrade both work and the app opens each time. After removal: no icon (if it stays, `uicache -a`), `uicache -l` prints nothing, the folder is gone. The app's data container is not removed by dpkg (expected). |

## Also worth noting (optional)

- iPhone model, iOS version, Dopamine version, Sileo or Zebra version.
- Whether the Bluetooth permission prompt appeared at all (step 2): this decides limitation L2 in [BETA2.md](BETA2.md).
- Any crash: Settings › Privacy & Security › Analytics & Improvements › Analytics Data › `HCGSentinelModern-…`.
