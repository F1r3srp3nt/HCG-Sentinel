# Validation report

What has actually been checked, and how. "Not done" means exactly that.

Sources: CI runs on GitHub Actions. Complete logs and `.xcresult` bundles are attached to each *Archive check*
run as artifacts: <https://github.com/F1r3srp3nt/HCG-Sentinel/actions/workflows/archive.yml>

## Beta2: 0.1.0~beta2 (21 November 2026)

HCG Sentinel Unleashed 0.1.0~beta2, source commit `680cb3f`. Every result below comes from a CI run on that commit;
none comes from a device. Details of what was built: [BETA2.md](BETA2.md).

| Check | Result | Evidence |
| --- | --- | --- |
| SentinelCore on Linux | **Passed**: 256 tests, 0 skipped. Includes a real ICMP Echo round trip to 127.0.0.1 over an unprivileged ICMP socket (the runner was set to allow them, as iOS does), real TCP connect accepted/refused, the real resolver's "not found", Bluetooth watchdog and diagnostics, sweep scope rules | CI › SentinelCore tests (Linux) |
| App and core tests in the iOS Simulator (scheme `HCGSentinel`, Xcode 26.6) | **Passed** ("TEST SUCCEEDED"). Core: 257 tests, 7 skipped (live local services or the mock node not reachable from that step). The real ICMP loopback test passed on Darwin (replies arrive with an IPv4 header there). App tests include the new Ping and Local Network wiring | CI › App build and tests (Xcode) |
| Build matrix | __MATRIX__ | Build matrix |
| Simulator screenshots of the network tools | __SHOTS__ | CI › Simulator screenshots |
| Real iOS arm64 Release build | **Passed**: `HCGSentinelModern`, Release, generic iOS device, Xcode 26.6; arm64 only; `minos 15.0` | Beta package run [44886884963](https://github.com/F1r3srp3nt/HCG-Sentinel/actions/runs/44886884963) |
| Rootless package | **Passed**: `com.hakmicapitalgroup.hcgsentinel` `0.1.0~beta2` `iphoneos-arm64`, Name "HCG Sentinel Unleashed", every file under `/var/jb/Applications/HCGSentinelModern.app` | same run |
| Identifiers | **Unchanged**: bundle ID `com.hcg.sentinel`, Home Screen name `Sentinel`, app 0.1.0 build 2 (beta1: build 1) | same run |
| Dependencies | `firmware (>= 15.0), uikittools`, the same as beta1 | same run |
| Signing and entitlements | ldid pseudo-signature (CodeDirectory present); **no entitlements**, the same as beta1 (the run fails if they differ) | Maker validator "[Passed] Entitlements: No entitlements embedded" |
| Package scripts | `postinst` (`uicache -p`) and `postrm` (`uicache -u`) **byte-identical** to beta1; no other scripts | same run |
| Maker's rootless validator, iOS 16.5 and 17.4 | **Passed**, including "0.1.0~beta2 is new and sorts above every published version (0.1.0~beta1)" | same run |
| SHA-256 | `6d783bdb4d529fe6d0fb340b6ae04462484376fce87565b0922fcfedfd6e4e61`, 3,668,560 bytes | artifact `hcg-sentinel-unleashed-0.1.0-beta2-deb` |
| HCG Repo inspector (HCG Repo `4aa36a0`) | **OK**: package passes package-level validation | same run |
| HCG Repo importer dry run, as exported | Bytes **validated** for Candidate; HCG Repo would keep the version protected and not serve it until the owner's approval is recorded. (The script prints "REJECTED" for this case because nothing would be served; that is the intended state.) | same run |
| HCG Repo importer dry run, throwaway copy with beta1's approval kept and a labelled hypothetical one for beta2 | **VALIDATED**: the importer accepts these exact bytes for Candidate. Nothing written to HCG Repo | same run |
| Upgrade from beta1 and rollback (Linux dpkg sandbox, the uploaded artifact's bytes) | **Passed**: install beta1 → upgrade to beta2 → roll back to beta1 → upgrade again → remove (0 files left) → purge. `uicache -p` ran on each configure, `uicache -u` on removal; upgrades did not unregister the app | Beta package › dpkg sandbox |
| Physical device | **Not tested.** No iPhone is reachable from CI or this session | [BETA_CHECKLIST.md](BETA_CHECKLIST.md) |
| Publication | **Not done.** Awaiting the owner's approval ([release/0.1.0-beta2.md](release/0.1.0-beta2.md)) | — |

## Beta: Maker route, header, Bluetooth day one, HCG Connect (21 November 2026)

Runs on branch `claude/festive-shannon-1nfggt`: build matrix 44862482640, CI 44862482689, archive check 44862482520,
HCG Connect readiness 44859350703.

| Step | How | Result |
| --- | --- | --- |
| `HCGSentinelModern` resolves to iOS 15.0, app and tests | Build matrix: Debug and Release, device and Simulator, Xcode 16.4 and 26.6; newest-Xcode job reads `IPHONEOS_DEPLOYMENT_TARGET` of both modern targets | 15.0 for `HCGSentinelModern` and `HCGSentinelModernTests`; archived binary `minos 15.0`, `MinimumOSVersion 15.0`. |
| Legacy `HCGSentinel` (iOS 14.7) preserved | Same matrix, Xcode 26.6; archive check with Xcode 16.4 and 26.6 | Builds and archives; `minos 14.7`. Unchanged. |
| **Simulator tests** (`HCGSentinelModern`) | Xcode 26.6, iOS 26 Simulator, newest-Xcode job | **Passed**: 27 app tests (6 skipped: live network, mock node and Keychain tests that need a person or a local service), 230 SentinelCore tests. Legacy scheme's tests also passed (CI "App build and tests"). |
| **Archive** (`HCGSentinelModern`, Release, generic iOS device) | `xcodebuild archive`, unsigned, Xcode 26.6 | **Succeeded**, arm64, `minos 15.0`. Unsigned: not installable. |
| **Through Maker, `main` (2842998, "0.3.1")** | Maker's real Mobile Build Studio driven by its UI driver, Xcode 26.6 with the SDK minimum raised to 15.0 | **Blocked, as on the user's Mac**: every output "unavailable — HCGSentinel (scheme HCGSentinel) needs iOS 14.7 …", no scheme selectable, "Required toolchain missing". A Maker bug; see MAKER.md. |
| **Through Maker, `fix/sentinel-end-to-end` (46205f0)** | Same | **Passed**: `HCGSentinelModern` Simulator app built and verified by Maker (24.0 MB); unsigned archive built and verified (`HCGSentinelModern.xcarchive`, 21.7 MB); deployment target reported "iOS 15.0 — within … iOS 15.0–26.5.99". `HCGSentinel` correctly blocked ("Blocked by the deployment target"). |
| **Signed export (development IPA)** | Maker and `Tools/build.sh export` | **Not produced.** Maker: "iOS IPA (export from archive): unavailable — No Apple Development certificate in the keychain (no code-signing identities were found for this destination)". CI has no signing identity and no Mac is attached to this session. Finish on your Mac: MAKER.md and BETA_CHECKLIST.md step 0. |
| **Physical device** | — | **Not tested.** No iPhone is reachable from this environment. Use BETA_CHECKLIST.md. |
| Header on compact iPhone and large text | Screenshots on a 375-point iPhone SE Simulator at default, XXXL and accessibility XXL, plus iPad | Lockup fits and keeps proportions; status badge wraps below it. |
| Moving light subtle; static without motion | Recording `dashboard-header.mp4`; screenshot with `-SentinelStaticMotion` (DEBUG flag driving the same `motionAllowed` switch as Reduce Motion and the Animations setting) | Light is narrower and dimmer and travels slowly; with motion off only the static divider shows. The system Reduce Motion switch itself was not toggled in a scripted run. |
| Bluetooth states distinct | Screenshots with the DEBUG-only fixture radio: denied, Bluetooth off, scanning with nothing heard (after 15 s), scanning with results, device detail | Each has its own icon, title, explanation and action; denied offers iOS Settings; off offers Start. **Fixtures only.** |
| Bluetooth status and signal history logic | `BluetoothScreenStatusTests` (Linux and macOS) and `BluetoothModelTests` (Simulator) | Passed. |
| Results near the top on small phones | Same screenshots, reviewed | First review: one row visible and the signal value truncated. Fixed (status detail hidden while devices are heard, top footnote removed, signal value never truncates) and re-checked in the CI run above. |
| Real Bluetooth discovery | Needs a physical iPhone | **Not tested.** |
| HCG Connect | Read-only checks from GitHub Actions; repository and HCG records reviewed | No Sentinel client, product ID or entitlement contract exists. Issuer, endpoints and ES256 key confirmed; unknown client refused (`oauth_client_not_found`); `/me` without a token is 401. Registration request: HCG_CONNECT.md. Sentinel needs no account. |

## Dashboard header: HCG Store lockup

| What | How it was checked | Result |
| --- | --- | --- |
| Mark is HCG Store's own asset | SHA-256 of `HCGSentinel/Resources/Brand/hcg-mark-{240,480}.webp` against `web-hcg-store/public/brand/` (store commit 835ac1a) | Identical; alpha channel present; 240×109 and 480×218. |
| Bundled and loads offline, font registered | `BrandLockupTests` (Simulator, hosted in the app) | Passed: both WebP files decode from the bundle with alpha and the 240:109 ratio; `SpaceGrotesk-SemiBold` is registered; the OFL licence is bundled. |
| Fits the narrowest iPhone | `BrandLockupTests.testLockupFitsTheNarrowestIPhone` (320-point screen) and Simulator screenshots on an iPhone SE (375 points) | Passed; no clipping. |
| Larger text sizes | Screenshots at XXXL and accessibility XXL | The lockup keeps its size (a brand mark); the status badge and text below scale and wrap. |
| Moving light under the lockup | 8-second Simulator recording of the dashboard (CI artifact `dashboard-header.mp4`) | The light travels along the divider as before; still respects Reduce Motion and the Animation switch (unchanged code). |

## Repair: build targets, Bluetooth discovery, truthful capabilities

| What | How it was checked | Result |
| --- | --- | --- |
| Difference between `HCGSentinel` and `HCGSentinelModern` | Every build phase and every Debug/Release setting of both targets compared from `project.pbxproj` | Same 27 sources, resources, Info.plist, package, bundle ID and settings; only the minimum iOS differs (14.7 / 15.0). No entitlements in either. |
| Both targets producing `HCGSentinel.app` | Reproduced in CI: `xcodebuild -alltargets` → `Multiple commands produce …/HCGSentinel.app` | Fixed: the modern target builds `HCGSentinelModern.app`. CI checks every target has its own product and builds both schemes into one derived-data folder. |
| Every scheme × Debug/Release, device and Simulator | CI build matrix, unsigned, Xcode 26.6 (both schemes) and 16.4 (modern) | All succeeded. Built apps: `HCGSentinel.app` minimum iOS 14.7, `HCGSentinelModern.app` 15.0. |
| Device Debug build and Release archive, legacy and modern | Archive check (`Tools/build.sh device`, `archive`, `inspect`), Xcode 16.4 and 26.6 | Succeeded; arm64; Mach-O `minos` 14.7 (legacy) and 15.0 (modern). |
| Maker reads the project correctly | Maker's analyzer and readiness code read at commit 660fcc3 (not executed: no .NET SDK in this environment) | Deployment targets and schemes read correctly; one cosmetic misread (no "Swift packages" label), see MAKER.md. |
| Bluetooth merge, name sources, scan sessions, filters, labels, permission and radio states | `BluetoothScanTests`, `BluetoothDiscoveryQualityTests` (Linux and macOS), `BluetoothModelTests` (app, Simulator) | Passed. **Fixtures only**: a fake Bluetooth central, no radio. |
| Feasibility items can never run or verify | `CapabilityTests.testFeasibilityItemsCanNeverRunOrVerify` | Passed. |
| Bluetooth Explorer, dashboard banner, capabilities at default and largest accessibility text | CI screenshots (iPhone and iPad, Simulator) | Reviewed: readable, no clipped text; Simulator has no Bluetooth, so no live devices appear. |
| **Real-device Bluetooth discovery** | Needs a physical iPhone | **Not tested.** No device is available to this environment. Checklist: TESTING.md, common checklist item 2. |

## Upgrade: banner, Check My Network, authenticated node protocol, switches (commit 533449e)

| Item | Status |
| --- | --- |
| Core tests (Linux and macOS) | Pass, including new tests: node protocol v2 handshake, wrong key, tampered capabilities, unauthenticated/forged/replayed/skipped messages, v1 node rejection, malformed envelopes and payloads, Wi-Fi scan validation, request/cancel/timeout; Check My Network cancellation, offline, unavailable data, connectivity-vs-threat classification, engine time limits, wording never claiming "safe"; full-URL endpoint allowlist; response formatting; settings migration. |
| App compile and unsigned archive, iOS 14.7 minimum | Pass with Xcode 16.4 and 26.6 (`HCGSentinel`), and 26.6 for the iOS 15.0 `HCGSentinelModern` scheme. |
| CI on `main` for 533449e | All green: core tests (Linux, macOS), device build, simulator tests, both screenshot jobs ([CI run](https://github.com/F1r3srp3nt/HCG-Sentinel/actions/runs/43482872897)), and all three archives ([archive run](https://github.com/F1r3srp3nt/HCG-Sentinel/actions/runs/43482873186); the Xcode 26.6 job needed one re-run after it never got a runner). |
| App tests on iPhone simulator | Pass (branch run 43480850553 and `main`), including switches stopping operations, requests needing an endpoint and Remote connections, Radio Lab refusing to connect without a key, filtering explaining its missing requirement, Preview mode blocking Check My Network. |
| Mock node v2 | Exercised from a scripted client here: handshake, status, Wi-Fi scan, spectrum; a forged client message ended the session. |
| Large-text and small-screen layout | **Reviewed** from CI screenshots on a 375-point iPhone SE simulator (the iPhone X's width, iOS 26.5) at default, XXXL and accessibility-XXL text sizes, at the top of every screen and scrolled to the end, plus iPad. A first review found three rows that squeezed text at accessibility size (Bluetooth status title, log Export/Delete buttons, activity timestamps); they now stack and were re-checked. The banner keeps its aspect ratio at every size. On iOS 26 the tab bar is the system's floating glass bar, so content passes beneath it while scrolling; on iOS 14–17 the bars are opaque black (not yet seen on a device). |
| Check My Network against a real network | **Not run.** The engine and analysis are unit-tested with a mock probe; the iOS probe (path monitor, Wi-Fi identity API, proxy settings, getaddrinfo, URL session) has not executed on a device or simulator in a scripted run. |
| Radio Lab against the v2 mock node in the app | **Not run.** The Swift session is tested against an in-memory node; the app's WebSocket path to `mock_radio_node.py` is untested. |
| Own-device filtering | Only the "requirement missing" path can be exercised; no helper exists, so rule sending has never reached a helper. |
| Physical devices | **Not tested.** |

## Summary

| Level | Status |
| --- | --- |
| Implemented | App, core package, tools and documentation as described in the README. |
| Compiled | Yes, in CI only. Core on Linux and macOS; app for Simulator and for a generic iOS device. |
| Archived | Yes, **unsigned**, with Xcode 16.4, 26.0.1, 26.2 and 26.6 (`HCGSentinel`), and 26.6 (`HCGSentinelModern`). |
| Reported archive failure | **Not reproduced.** See "The archive failure" in `docs/MAKER.md`. |
| Signed archive / IPA | **Not produced.** No signing identity is available to CI or to the author. |
| Unit-tested | 108 core tests on macOS, 107 on Linux, and the full scheme on an iOS simulator, all passing. |
| Launched on simulator | Yes, by script, on iPhone and iPad simulators (iOS 26.2). Screens were not reviewed. |
| Tested on a physical device | **No.** Neither the iPhone 13 Pro Max (iOS 17.4) nor the iPhone X (iOS 14.7). |
| Run on iOS 14 or 15 at all | **No.** |
| Built through HCG Executable Maker | **Yes, in CI**, with Maker's branch `fix/sentinel-end-to-end`: Simulator app and unsigned archive of `HCGSentinelModern`. Maker's `main` cannot select the scheme (see the beta section). |

## Archive inspection

From `Tools/build.sh inspect` on the unsigned CI archives:

| Property | `HCGSentinel` (Xcode 26.6) | `HCGSentinelModern` (Xcode 26.6) |
| --- | --- | --- |
| Executable architecture | arm64 | arm64 |
| Minimum OS in the Mach-O load command | 14.7 | 15.0 |
| `MinimumOSVersion` in Info.plist | 14.7 | not captured in the log excerpt read; the Mach-O value above is authoritative |
| SDK | iphoneos 26.5 | same |
| Bundle identifier, version | `com.hcg.sentinel`, 0.1.0 (1) | same |
| Resources | `Assets.car`, `AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png`, `Info.plist`, `PkgInfo` | same |
| Embedded components | `Frameworks/libswift_Concurrency.dylib` (Swift's back-deployment library, added by Xcode for iOS 14); no app extensions; `SentinelCore` is linked statically | no embedded frameworks; no app extensions |
| Signature, entitlements | none (unsigned) | none |

Both columns are measured values from CI run <https://github.com/F1r3srp3nt/HCG-Sentinel/actions/runs/43179079236>.

Toolchain facts measured in CI: Xcode 26.6 reports a supported deployment range of 12.0 to 26.5.99 and treats a
target outside it as a warning. `RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET` there is 15.0.

## Compiled

| What | Where | Result |
| --- | --- | --- |
| `SentinelCore` | Linux (`ubuntu-latest`, preinstalled Swift) | Built. |
| `SentinelCore` | macOS (`macos-15`) | Built. |
| `HCGSentinel` app, Release, generic iOS device (arm64), unsigned | `macos-15`, `xcodebuild` | Built. |
| `HCGSentinel` app + `HCGSentinelTests`, Debug, iOS simulator | `macos-15`, `xcodebuild` | Built. |
| Asset catalog with the supplied HCG app icon | Same builds | Compiled. One notice (an unused iPad 76pt @1x slot) has since been removed. |

The development environment the code was written in had no Swift or Xcode toolchain, so nothing was compiled
locally; all compilation evidence comes from CI. No signed build and no IPA has been produced, because no signing
identity is available to CI. The signing and export instructions in `docs/BUILDING.md` are therefore untested.

## Automated tests

| Suite | Platform | Result |
| --- | --- | --- |
| `SentinelCoreTests` | Linux | 107 executed, 0 failures. |
| `SentinelCoreTests` | macOS | 108 executed, 0 failures (one extra test cross-checks the portable SHA-256 against CryptoKit). |
| Scheme `HCGSentinel` (`HCGSentinelTests` + `SentinelCoreTests`) | iPhone 17 Pro simulator, iOS 26.2 | Passed. Run with `-quiet`, so the per-suite count is not in the log. |

The request integration tests ran against `Tools/local_test_service.py` in the Linux and macOS package runs
(`SENTINEL_TEST_SERVICE_URL` was set). In the simulator run that variable is not forwarded, so those two tests are
skipped there.

The Python tools were exercised by hand in the development environment: the test service answered echo, status and
redirect requests, and the mock node completed a WebSocket handshake and streamed a spectrum frame to a scripted
client.

## Simulator

CI installs and launches the app on an iPhone 17 Pro and an iPad Pro 13-inch (M5) simulator (iOS 26.2), opens each
section through its deep link, and uploads 14 screenshots as the `simulator-screenshots` artifact of the run above.

* The app launched and stayed running through all seven sections on both devices.
* **Nobody has looked at those screenshots.** The author could not download them from the development environment.
  Layout, contrast, clipping and the iPad sidebar are unreviewed. Please open the artifact and check them.
* No interaction was scripted: no scan was started, no file imported, no request sent, no node connected, in the
  running app. Those paths are covered by unit tests of the underlying logic only.

## Simulator integration runs (CI, Xcode 26.6, iOS 26 simulator)

Run 43526578068 on commit e5e2af0; every job passed, including the archive check on Xcode 16.4 and 26.6.

- **Mock radio node** (`MockNodeIntegrationTests`, real `WebSocketNodeTransport` against `Tools/mock_radio_node.py` with a random 32-byte key): authenticated v2 handshake, spectrum frames, Wi-Fi scan (3 simulated networks, none treated as verified), wrong key rejected before anything is kept, unreachable node fails clearly. 3 passed, 1 skipped (Keychain, see below).
- **Check My Network live** (`NetworkCheckLiveTests`, the app's real `PlatformNetworkProbe`): all 8 steps finished in 0.57 s. Findings: wired connection (notice: not Wi-Fi); Wi-Fi identity unavailable with the entitlement reason; no proxy; DNS resolves; a random non-existent name gets "not found"; captive.apple.com page unmodified; HTTPS to example.com and www.apple.com trusted with certificate chains recorded. Headline: "No security concerns found by these checks" — never "safe".
- **Cancel during the live check**: cancelled as the first DNS step started; report marked cancelled after 3 of 8 steps, the remaining five "not checked", and no late changes 3 s later.
- **Screenshots** of an automatic run in the app (`-SentinelRunNetworkCheck`) are in the run's `simulator-screenshots-*` artifacts.

## Not validated

| Area | Why | How to close it |
| --- | --- | --- |
| Anything on iOS 14.7 / the iPhone X | No iOS 14 runtime in CI and no device access. The iOS 14/15 code paths (`NavigationView` fallback, appearance configuration, `onChange`, sheets) compile but have never executed. This is the highest-risk gap. | Run the checklist in `docs/TESTING.md` on the iPhone X. |
| iPhone 13 Pro Max / iOS 17.4 | No device access. | Same checklist. |
| Bluetooth discovery against a real radio | Simulators have no Bluetooth. The scan state machine and permission failures are tested with a mock central; the Core Bluetooth adapter itself has never run. | Device checklist, Bluetooth section. |
| Document picker import | Not scripted. Parsing is heavily tested; the picker hand-off is not. | Simulator checklist step 8. |
| Request Composer end to end in the app | Core transport tested against the local service on macOS/Linux, not from the running iOS app. Local Network permission and App Transport Security behaviour are untested. | Simulator step 6, device step 4. |
| Radio Lab screen model with a stored pairing key | The app's WebSocket transport is now tested against `Tools/mock_radio_node.py` in the simulator (see below), but `testRadioLabModelConnectsAndRecordsCapabilities` skips in CI because the simulator Keychain refuses items for the unsigned test build. | Simulator step 7, or run the test from a signed build. |
| Check My Network on Wi-Fi, cellular, a captive portal or a proxy | CI ran it only on a wired, unproxied runner. | Device checklist on each network type. |
| Real radio hardware | No node implementation and no hardware exist. | Build a node to `docs/NODE_PROTOCOL.md`. |
| Privileged helper | No helper exists; the jailbreak environment is unknown. Only the protocol, client and reference server logic are tested, in memory. The loopback transport and Keychain storage have not been run. | See `docs/HELPER_INTERFACE.md`. |
| Mac debugging proxy, Nexus | Interface and documentation only. | See the respective documents. |
| Reduce Motion, Dynamic Type, VoiceOver | Implemented but unobserved. | Simulator steps 3–4. |
| Signed archive and IPA export | No signing identity. Unsigned archives are verified; `Tools/build.sh export` has never run. | `docs/MAKER.md`, `docs/BUILDING.md`. |
| The Xcode that produced the reported failure | Its version and supported range are unknown; no hosted runner has an Xcode newer than 26.6. | `Tools/build.sh range` on that Mac. |
| Real-world capture files | Only synthetic captures have been parsed. Files from tcpdump/Wireshark may contain link types or blocks that are shown undecoded. | Import your own captures. |

## Record your own results here

| Date | Device / OS | Xcode | Checklist items run | Result |
| --- | --- | --- | --- | --- |
| | | | | |
