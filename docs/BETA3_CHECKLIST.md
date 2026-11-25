# Physical-device checklist: HCG Sentinel Unleashed 0.1.0~beta3

Device: **iPhone 11 Pro Max, iOS 17.4, Dopamine (rootless)**. Nothing here is done automatically. Record each step
as **pass**, **fail** (what you saw) or **not tried** in `docs/VALIDATION.md` › "Record your own results here",
separately from Simulator and mock results. Only results recorded there count as device evidence.

The beta2 checklist ([BETA_CHECKLIST.md](BETA_CHECKLIST.md)) still applies to Bluetooth, Wi-Fi, ping, local
network, install and removal; this list covers what beta3 adds, plus the install and Nexus regression checks.

| # | Test | Steps | Expected |
| --- | --- | --- | --- |
| 1 | Install / upgrade | Upgrade to **HCG Sentinel Unleashed 0.1.0~beta3** in Sileo or Zebra. Before respringing: `dpkg-query -W com.hakmicapitalgroup.hcgsentinel` and `uicache -l \| grep com.hcg.sentinel`. | Version `0.1.0~beta3`; one path. Icon "Sentinel". Note whether a respring was needed. Settings › About shows 0.1.0 (3). |
| 2 | Nexus regression | From HCG Nexus open each Sentinel shortcut it offers (Dashboard, Security Lab, Check My Network, Capabilities, Network, Bluetooth, Radio, Requests, Settings). | Each opens the same screen as before; nothing starts by itself. |
| 3 | Center | Tab **Center**. Open each of the twelve areas' entries. | Every screen opens; Back returns to the Center. |
| 4 | Capability Center filters | Tab **Capabilities**; switch the filter through All → Planned. | Counts change; Satellite/Cellular/Watch only under Planned; nothing under Verified before you run anything. |
| 5 | Self-test: loopback ping | Capabilities › Ping (ICMP Echo) › Run test. | "ICMP Echo Reply from 127.0.0.1 … ms"; the card turns Verified; Last success shows the time. If it fails, record the exact text. |
| 6 | Self-test: connection | Connection diagnostics › Run test (on Wi-Fi). | Passes; Wi-Fi connection details becomes Verified. |
| 7 | Self-tests: capture, secret scan | Run both tests. | Both pass; the secret-scan result says the key was kept redacted. |
| 8 | Device Security | Center › Device Security › Run checks. | Passcode: Pass (if set). Device environment: /var/jb visible, Sentinel installed there. **Sentinel's package record**: Pass with 0.1.0~beta3, or "Not readable" with the system's reason — record which. **Installed files**: Pass, or the list of differences, or "Not readable". Export the report and keep it. |
| 9 | Persisted evidence | Force-quit Sentinel, open it, open Capabilities › Ping. | This session: Not verified yet. Last success: the earlier time. |
| 10 | Report import | On the Mac, System Tester › Ecosystem › Export security findings for Sentinel; AirDrop the .json to the iPhone (save to Files). Sentinel › Reports › Import a report file…. | "Imported …"; the report opens as text, marked IMPORTED. A random .json or a .txt is refused with a reason. |
| 11 | Network history | Run Check My Network, then ping your router. Open Reports › Network diagnostic history. | Two entries; addresses shown as [REDACTED IP]; Export works. |
| 12 | Capture statistics | Network › import a pcap/pcapng you made (for example with Wireshark on your Mac). Open it. | Traffic statistics, timeline and conversations appear. Share the privacy-preserving report: no real addresses in it. |
| 13 | Request TLS info | Settings › Remote connections on, add an HTTPS endpoint you own; Request Composer › Send. | Response shows TLS protocol and cipher, certificate subjects, "Trusted by iOS", timing phases; History lists the request with a redacted URL. |
| 14 | External Nodes | Center › External Nodes. | Each row's status matches reality (server not paired / paired; radio node not connected; System Tester shows your imported count; helper not set up). |
| 15 | Wi-Fi wording | Network › Wi-Fi. | "iOS path report: IPv4 route yes …"; the dashboard says Idle (not Unsupported) for Wi-Fi when you are on cellular. |
| 16 | Background | Start a 100-probe ping, press Home, come back. | Ping stopped "because Sentinel moved to the background". |
| 17 | Rollback | Install 0.1.0~beta1 from the version list (or `sudo dpkg -i` the beta1 .deb), open Sentinel, then upgrade to beta3 again. | Both work; settings and stored evidence are kept. |

Record also: Sileo/Zebra version, Dopamine version, whether any step needed a respring.
