# Building, signing and exporting

## Requirements

| Need | Notes |
| --- | --- |
| A Mac with Xcode | Archived in CI with Xcode 16.4, 26.0.1, 26.2 and 26.6. Other versions are untested. |
| iOS deployment target | Scheme `HCGSentinel`: 14.7. Scheme `HCGSentinelModern`: 15.0. `SentinelCore` declares iOS 14. |
| Apple ID or developer team | Needed only to run on a physical device or export an IPA. |
| No third-party dependencies | Nothing is downloaded at build time. |

**iPhone X on iOS 14.7:** recent Xcode releases have dropped *on-device debugging* for older iOS versions (check
the release notes of your Xcode; Xcode 15 lists iOS 12 and later, Xcode 16 lists iOS 15 and later). If your Xcode
cannot attach to iOS 14.7, either use an Xcode 15.x install for that device, or build an IPA and install it without
the debugger (see "Installing an IPA" below). Building for a 14.7 deployment target works either way.

## One entry point

`Tools/build.sh` works from a clean clone, from paths with spaces, and never hides a failure:

| Command | Does |
| --- | --- |
| `Tools/build.sh info` | Xcode, SDK, schemes and the effective deployment target, architectures and bundle identifier. |
| `Tools/build.sh range` | Asks the selected Xcode which deployment targets it supports. |
| `Tools/build.sh test-core` | Core tests on the Mac. |
| `Tools/build.sh simulator` | Unsigned Simulator build. |
| `Tools/build.sh device` | Debug build for an iPhone or iPad: generic, or a connected device with `DEVICE_ID`. Signed when `DEVELOPMENT_TEAM` is set. |
| `Tools/build.sh archive` | Archive for a generic iOS device. Signed when `DEVELOPMENT_TEAM` is set, otherwise unsigned. |
| `Tools/build.sh inspect` | Architecture, minimum OS, resources, embedded components and signature of the archived app. |
| `Tools/build.sh export` | Development IPA from a signed archive. |

Set `FLAVOR=modern` for the iOS 15+ variant and `DEVELOPER_DIR` to choose an Xcode. Logs go to `build/logs/`,
result bundles to `build/*.xcresult`. Building through HCG Executable Maker is described in
[MAKER.md](MAKER.md).

## The two targets, exactly

These facts were checked mechanically against `HCGSentinel.xcodeproj` (every build phase and every Debug and Release
setting of both targets compared). "Modern" is **not** a superset of anything: it is the same app with a higher
minimum iOS.

| | `HCGSentinel` | `HCGSentinelModern` |
| --- | --- | --- |
| Shared scheme | `HCGSentinel` (build, run, test, archive) | `HCGSentinelModern` (build, run, archive; no test action) |
| Minimum iOS | 14.7 (inherited from the project) | 15.0 (set on the target) |
| Swift sources | the same 27 files | the same 27 files |
| Resources | `Assets.xcassets` | `Assets.xcassets` |
| `Info.plist` | `HCGSentinel/Resources/Info.plist` | the same file |
| Bundle identifier | `com.hcg.sentinel` | `com.hcg.sentinel` (the same app on a device: installing one replaces the other) |
| Home-screen name | Sentinel | Sentinel |
| App bundle / executable | `HCGSentinel.app` | `HCGSentinelModern.app` |
| Entitlements | none | none |
| Dependencies | local package `SentinelCore` (linked statically) | the same |
| Debug | `-Onone`, `DEBUG` flag, testability on, active architecture only | the same |
| Release | `-O`, whole-module, no `DEBUG` flag, product validation on | the same |
| Signing | Automatic, no team committed | the same |

Features are identical because the sources are identical. Newer APIs are used behind availability checks (for
example `NavigationStack` on iOS 16+, `NavigationView` before), so both targets contain the same screens and
behaviour on the same iOS version. The minimum is a real compiler setting, not an edited `MinimumOSVersion`.

**Fixed in this version:** both targets used to produce `HCGSentinel.app`. Building both targets in one build
stopped with `Multiple commands produce …/Release-iphoneos/HCGSentinel.app` (reproduced in CI with
`xcodebuild -alltargets`). The modern target now produces `HCGSentinelModern.app`, and its bundle identifier and
display name did not change. CI now checks that every target has its own product, and builds both schemes into one
derived-data folder.

Builds that go through a scheme (Xcode, `Tools/build.sh`, HCG Executable Maker) build one target and were never
affected. `xcodebuild -alltargets` remains unusable for this project for a separate reason: without a scheme,
xcodebuild does not build the local `SentinelCore` package (`Unable to resolve module dependency: 'SentinelCore'`).
Always build with `-scheme`.

### Which one to build

| Phone | Xcode on the Mac | Scheme |
| --- | --- | --- |
| iPhone X on iOS 14.7 | one that accepts a 14.7 deployment target (verified: 16.4, 26.0–26.6) | `HCGSentinel` |
| iPhone 13 Pro Max on iOS 17.4 (or any iOS 15+ device) | any verified Xcode | `HCGSentinel` or `HCGSentinelModern`; both produce the same app |
| any device | an Xcode whose supported range starts above 14.7 | `HCGSentinelModern` (does not install on iOS 14) |

The legacy target stays at 14.7 on purpose. It is never raised silently. If an Xcode rejects 14.7, the build fails
with an explicit message, and the choice of scheme is yours.

### Building for a modern iPhone, step by step

1. On the Mac: `Tools/build.sh range` shows which deployment targets the selected Xcode accepts.
2. Debug build for the connected phone (signed with your team; install from Xcode):

   ```bash
   FLAVOR=modern DEVELOPMENT_TEAM=YOURTEAMID DEVICE_ID=<udid> Tools/build.sh device
   ```

   Or in Xcode: scheme **HCGSentinelModern**, choose the phone, Run.
3. Release IPA for installing without Xcode:

   ```bash
   FLAVOR=modern DEVELOPMENT_TEAM=YOURTEAMID Tools/build.sh archive
   ```

   ```bash
   FLAVOR=modern DEVELOPMENT_TEAM=YOURTEAMID Tools/build.sh export
   ```

Leave out `FLAVOR=modern` to build the 14.7 target the same way. Nothing is installed or uploaded automatically.

## Open and run

```bash
open HCGSentinel.xcodeproj
```

Select the shared scheme **HCGSentinel**, pick a simulator or device, and Run. `SentinelCore` is a local package
inside the repository and resolves without network access.

If you add, rename or remove source files outside Xcode, regenerate the project:

```bash
python3 Tools/generate_xcodeproj.py
```

## Command line

Core logic only (macOS or Linux, no simulator needed):

```bash
swift test --package-path SentinelCore
```

Everything, on a simulator (replace the device name with one you have; `xcrun simctl list devices available`):

```bash
xcodebuild test -project HCGSentinel.xcodeproj -scheme HCGSentinel -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Compile check for a real device without signing:

```bash
xcodebuild build -project HCGSentinel.xcodeproj -scheme HCGSentinel -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO
```

## Manual signing for a physical device

1. Xcode › Settings › Accounts: add your Apple ID.
2. Select the project › target **HCGSentinel** › **Signing & Capabilities**.
3. Tick **Automatically manage signing** and choose your **Team**.
4. Change **Bundle Identifier** from `com.hcg.sentinel` to one you own (for example `com.yourname.sentinel`). Do the
   same prefix change on **HCGSentinelTests** if you want to run tests on the device.
5. Connect the device, trust the Mac, enable Developer Mode on iOS 16+ (Settings › Privacy & Security › Developer
   Mode), then Run.
6. With a free Apple ID, open Settings › General › VPN & Device Management on the device and trust your developer
   certificate. Free provisioning profiles expire after 7 days.

To sign manually instead: untick automatic signing, create an iOS App Development certificate and a development
provisioning profile for your bundle identifier that includes the device's UDID, and select that profile for Debug
and Release.

The app needs **no special entitlements or capabilities**. Do not add background modes, Network Extension or other
entitlements to make it "do more"; the capability model is built around not having them.

Never commit certificates, `.p12` files or provisioning profiles. `.gitignore` already excludes them.

## Exporting an IPA

```bash
xcodebuild archive -project HCGSentinel.xcodeproj -scheme HCGSentinel -destination 'generic/platform=iOS' -archivePath build/HCGSentinel.xcarchive DEVELOPMENT_TEAM=YOUR_TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=com.yourname.sentinel -allowProvisioningUpdates
```

```bash
cp Tools/ExportOptions.development.plist ExportOptions.local.plist
```

Edit `ExportOptions.local.plist` and replace `YOUR_TEAM_ID`, then:

```bash
xcodebuild -exportArchive -archivePath build/HCGSentinel.xcarchive -exportOptionsPlist ExportOptions.local.plist -exportPath build/ipa -allowProvisioningUpdates
```

The IPA is written to `build/ipa/HCGSentinel.ipa`. In Xcode the equivalent is Product › Archive, then Distribute
App › Debugging (called "Development" in older versions) › Export.

A development-signed IPA installs only on devices whose UDIDs are in the provisioning profile.

### Installing an IPA

* Xcode › Window › Devices and Simulators › select the device › drag the IPA onto **Installed Apps**, or
* Apple Configurator on the Mac › select the device › Add › Apps › Choose from my Mac.

### What this project does not automate

Uploading to TestFlight or the App Store, publishing packages, installing a jailbreak, and respringing devices are
deliberately not scripted anywhere in this repository.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, with time limits on each job:

* **Linux:** `swift test` for `SentinelCore` (uses the portable SHA-256 path).
* **macOS:** `swift test` (CryptoKit path), an unsigned Release build for a generic iOS device, the full scheme's
  tests on an iPhone simulator.
* **Screenshots:** two further jobs (iPhone, iPad) launch the app built by the test job and upload screenshots of
  every section. They are separate so that a slow simulator boot cannot fail the build-and-test job.

`.github/workflows/archive.yml` is the focused archive check. With explicitly selected Xcode versions (16.4 and
26.6) it runs `Tools/build.sh info`, `range`, `simulator`, `archive` and `inspect` for the default scheme, and for
`HCGSentinelModern` on 26.6. Complete logs and `.xcresult` bundles are uploaded as artifacts whether the job passes
or fails. It archives unsigned: CI has no signing identity, so it never produces an installable app or an IPA.

`.github/workflows/build-matrix.yml` builds **both schemes in Debug and Release** with Xcode 26.6, and the modern
scheme in Debug and Release with Xcode 16.4 (the legacy scheme on 16.4 is covered by the archive check's device build
and archive), for a generic iOS device and for the Simulator, unsigned, and prints the effective settings and the built app's minimum iOS and
architectures. A separate job builds both app targets together, which is what used to fail.

macOS runners are billed at a higher rate than Linux on private repositories. Remove or restrict the `app-macos` job
if that matters to you.
