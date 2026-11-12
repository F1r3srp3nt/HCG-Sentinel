# Validation report

What has actually been checked, and how. "Not done" means exactly that.

Last updated for CI run 3 (commit `1d2d0d5`):
<https://github.com/F1r3srp3nt/HCG-Sentinel/actions/runs/43167233842>

## Summary

| Level | Status |
| --- | --- |
| Implemented | App, core package, tools and documentation as described in the README. |
| Compiled | Yes — on GitHub's `macos-15` runner with its default Xcode, and the core package on Linux. |
| Unit-tested | Yes — 108 core tests on macOS, 107 on Linux, and the full scheme on an iOS simulator, all passing. |
| Launched on simulator | Yes — iPhone and iPad simulators, by script. **Screens were not reviewed by a person or by the author.** |
| Tested on a physical device | **No.** Neither the iPhone 13 Pro Max (iOS 17.4) nor the iPhone X (iOS 14.7). |
| Run on iOS 14 or 15 at all | **No.** Only an iOS 26.2 simulator was available in CI. |

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
| Signing, archive, IPA export | No signing identity. | `docs/BUILDING.md`. |
| Real-world capture files | Only synthetic captures have been parsed. Files from tcpdump/Wireshark may contain link types or blocks that are shown undecoded. | Import your own captures. |

## Record your own results here

| Date | Device / OS | Xcode | Checklist items run | Result |
| --- | --- | --- | --- | --- |
| | | | | |
