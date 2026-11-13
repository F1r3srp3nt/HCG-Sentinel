# Validation report

What has actually been checked, and how. "Not done" means exactly that.

Sources: CI runs on GitHub Actions. Complete logs and `.xcresult` bundles are attached to each *Archive check*
run as artifacts: <https://github.com/F1r3srp3nt/HCG-Sentinel/actions/workflows/archive.yml>

## Upgrade: banner, Check My Network, authenticated node protocol, switches (commit 533449e)

| Item | Status |
| --- | --- |
| Core tests (Linux and macOS) | Pass, including new tests: node protocol v2 handshake, wrong key, tampered capabilities, unauthenticated/forged/replayed/skipped messages, v1 node rejection, malformed envelopes and payloads, Wi-Fi scan validation, request/cancel/timeout; Check My Network cancellation, offline, unavailable data, connectivity-vs-threat classification, engine time limits, wording never claiming "safe"; full-URL endpoint allowlist; response formatting; settings migration. |
| App compile and unsigned archive, iOS 14.7 minimum | Pass with Xcode 16.4 and 26.6 (`HCGSentinel`), and 26.6 for the iOS 15.0 `HCGSentinelModern` scheme. |
| App tests on iPhone simulator | Pass (branch run 43480850553), including switches stopping operations, requests needing an endpoint and Remote connections, Radio Lab refusing to connect without a key, filtering explaining its missing requirement, Preview mode blocking Check My Network. |
| Mock node v2 | Exercised from a scripted client here: handshake, status, Wi-Fi scan, spectrum; a forged client message ended the session. |
| Large-text and small-screen layout | Screenshots are produced in CI (375-point iPhone at default, XXXL and accessibility-XXL, top and scrolled; iPad) as the `simulator-screenshots-*` artifacts. **Not reviewed:** this environment cannot download CI artifacts, so the overlap fixes are implemented but not visually confirmed. |
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
| Built through HCG Executable Maker | **No.** Maker's command was read from its source and reproduced; Maker itself was not run. |

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

## Not validated

| Area | Why | How to close it |
| --- | --- | --- |
| Anything on iOS 14.7 / the iPhone X | No iOS 14 runtime in CI and no device access. The iOS 14/15 code paths (`NavigationView` fallback, appearance configuration, `onChange`, sheets) compile but have never executed. This is the highest-risk gap. | Run the checklist in `docs/TESTING.md` on the iPhone X. |
| iPhone 13 Pro Max / iOS 17.4 | No device access. | Same checklist. |
| Bluetooth discovery against a real radio | Simulators have no Bluetooth. The scan state machine and permission failures are tested with a mock central; the Core Bluetooth adapter itself has never run. | Device checklist, Bluetooth section. |
| Document picker import | Not scripted. Parsing is heavily tested; the picker hand-off is not. | Simulator checklist step 8. |
| Request Composer end to end in the app | Core transport tested against the local service on macOS/Linux, not from the running iOS app. Local Network permission and App Transport Security behaviour are untested. | Simulator step 6, device step 4. |
| Radio Lab WebSocket transport | The session logic is tested with a mock transport. `URLSessionWebSocketTask` against the mock node has not been run. | Simulator step 7. |
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
