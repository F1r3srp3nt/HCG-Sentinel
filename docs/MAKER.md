# Building with HCG Executable Maker

## What Maker needs, and where it is

| Maker looks for | In this repository |
| --- | --- |
| An Xcode project at the root | `HCGSentinel.xcodeproj` (committed; no generation step is needed before building) |
| Shared schemes | `HCGSentinel` and `HCGSentinelModern` in `HCGSentinel.xcodeproj/xcshareddata/xcschemes` |
| An application target | `HCGSentinel` (iOS 14.7+, builds `HCGSentinel.app`) and `HCGSentinelModern` (iOS 15.0+, builds `HCGSentinelModern.app`). Same sources, resources, Info.plist and features; see [BUILDING.md](BUILDING.md#the-two-targets-exactly). |
| Release configuration with an Archive action | Both schemes archive with `Release` |
| Bundle identifier | `com.hcg.sentinel` (both targets: it is the same app) |
| Signing | Automatic, no team committed. Choose the team in Maker. |
| Dependencies | One local Swift package, `SentinelCore`, inside the repository. Nothing is downloaded. |
| Entitlements, extensions, embedded frameworks | None. |

Maker runs (read from its `XcodePlanner`):

```
xcodebuild -project HCGSentinel.xcodeproj -scheme <scheme> -configuration Release -derivedDataPath <work>/DerivedData -destination generic/platform=iOS -archivePath <work>/<scheme>.xcarchive COMPILER_INDEX_STORE_ENABLE=NO <signing settings> archive
```

`Tools/build.sh archive` runs the same command shape, and CI runs it on every change.

## The archive failure (exit code 65)

**What the screenshot shows.** `xcodebuild archive` for scheme `HCGSentinel` stopped with

```
…/source/HCGSentinel.xcodeproj: error: The iOS deployment target 'IPHONEOS_DEPLOYMENT_TARGET' …
```

The rest of that line is cut off, and exit code 65 only means "the build failed". The line is a project-level
*error*, raised before any source file is compiled.

**What was established.**

* Maker does not override the deployment target. Its command carries no `IPHONEOS_DEPLOYMENT_TARGET` setting, and
  there is no xcconfig in this project. The value Xcode complained about is the project's own: 14.7.
* 14.7 is a valid, resolved value: `xcodebuild -showBuildSettings` reports `IPHONEOS_DEPLOYMENT_TARGET = 14.7` for
  the app, and the package declares iOS 14.
* The same archive command **succeeds** in CI with Xcode 16.4, 26.0.1, 26.2 and 26.6, producing an arm64 app with
  minimum OS 14.7.
* Xcode 26.6 reports its supported range as **12.0 to 26.5.99**, and reports a target outside that range as a
  *warning*, not an error.

**Conclusion.** The failure was not reproduced. On every Xcode that could be tested, 14.7 is accepted. The Xcode
that Maker used on your Mac therefore behaves differently from all of them: it treats 14.7 as outside its supported
range and makes that an error. The most likely reason is that it is a newer Xcode whose supported range starts above
14.7, but that is an inference: no hosted CI runner has an Xcode newer than 26.6, and the visible part of the log
does not show the range or the Xcode version.

**To confirm it,** one of these is enough:

* the full error line from Maker's build log (it ends with "…but the range of supported deployment target versions
  is X to Y"), together with the "Developer directory" and Xcode version lines Maker prints at the start, or
* the output of this, run on the Mac in the repository folder:

```bash
Tools/build.sh range
```

## How to build in Maker

### Route A — one app for both phones (iOS 14.7 and 17.4)

Use this when the Mac has an Xcode that accepts 14.7 (verified: 16.4 and 26.0–26.6).

1. In Maker, open **Toolchains** and select that Xcode. Maker applies it to its own builds only (`DEVELOPER_DIR`);
   the system setting is not changed.
2. Import the repository folder (or its ZIP of `main`).
3. Scheme **HCGSentinel**.
4. Signing: **Automatic**, with your Apple Developer Team ID. Enable "allow provisioning updates" if the Mac has no
   profile for the bundle identifier yet.
5. Output **Archive** or **IPA**; for an IPA choose the **development** (debugging) export method.

The resulting app installs on both the iPhone X (iOS 14.7) and the iPhone 13 Pro Max (iOS 17.4).

### Route B — only a newer Xcode is installed

Use this when the selected Xcode rejects 14.7 and no older Xcode is available.

1. Scheme **HCGSentinelModern**. Everything else as in Route A.
2. The result requires **iOS 15.0 or later**. It installs on the iPhone 13 Pro Max (17.4). It does **not** install
   on the iPhone X while that phone is on iOS 14.7.

If the Xcode's supported range starts above 15.0, this scheme fails with the same kind of error naming the new
range. Change `MODERN_DEPLOYMENT_TARGET` in `Tools/generate_xcodeproj.py` to the lower bound it reports, run
`python3 Tools/generate_xcodeproj.py`, and commit. Route B has been compiled with Xcode 26.6 only.

To still serve the iPhone X from such a Mac, install a second, older Xcode next to the new one (Apple's developer
downloads; any of the verified versions) and use Route A with it selected in Maker.

### What Maker reports

Maker labels an unsigned archive as inspection-only and refuses to export it. A development archive and an exported
IPA are separate results; an archive that succeeded does not mean an IPA exists. Nothing is uploaded to TestFlight
or App Store Connect by Maker or by this repository.

## Same build without Maker

```bash
Tools/build.sh info
```

```bash
DEVELOPMENT_TEAM=YOURTEAMID Tools/build.sh archive
```

```bash
Tools/build.sh inspect
```

```bash
DEVELOPMENT_TEAM=YOURTEAMID Tools/build.sh export
```

Add `FLAVOR=modern` in front for Route B, and `DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer` (or
similar) to choose an Xcode. Without `DEVELOPMENT_TEAM` the archive is unsigned and cannot be exported. Output goes
to `build/`: the archive at `build/HCGSentinel.xcarchive`, complete logs in `build/logs/`, result bundles as
`build/*.xcresult`, and the IPA in `build/ipa/`.

## Sideloading versus App Store

Everything above is for development-signed builds installed on your own registered devices. App Store or TestFlight
distribution has separate, stricter rules (current SDK requirements, an App Store provisioning profile, export
compliance and review) that this project has not been prepared or checked for.

## Maker handoff

### Exactly what to choose

| Maker field | Value |
| --- | --- |
| Project | `HCGSentinel.xcodeproj` (repository root; no workspace, no CocoaPods) |
| Scheme | **`HCGSentinelModern`** with any Xcode whose supported range starts at 15.0 (for example the one reporting "15.0 to 27.2.x"); the app runs on iOS 15.0 and later. **`HCGSentinel`** only with an Xcode that still accepts 14.7 (16.4, 26.x), for the iPhone X on iOS 14.7. Maker's readiness check names the other scheme when the selected one is out of range. |
| Configuration | **Release** (both schemes archive with Release; Maker passes `-configuration Release`) |
| Destination | Generic iOS device (`generic/platform=iOS`) for an archive or IPA; iOS Simulator for an unsigned check |
| Signing | Automatic, your Team ID, "allow provisioning updates" if the Mac has no profile yet |
| Export | IPA, **development** method, for your registered devices |
| Expected product | `HCGSentinel.app` or `HCGSentinelModern.app` in the archive, bundle ID `com.hcg.sentinel`, display name "Sentinel", minimum iOS 14.7 or 15.0 |

### What Maker reads correctly (checked against its current `main`, commit 660fcc3)

* `XcodeProjectAnalyzer` takes each target's settings on top of the project's, so it reports 14.7 for
  `HCGSentinel` (inherited) and 15.0 for `HCGSentinelModern` (set on the target). Correct.
* Schemes: it reads the Archive action's target and configuration from the shared `.xcscheme` files. Both schemes
  name exactly one app target and archive with Release. Correct.
* `MobileReadiness.AddDeploymentRange` now compares those targets with the selected Xcode's
  `SupportedTargets.iphoneos` range from `SDKSettings.json` and names the other scheme as a route when one is out of
  range. That is the preflight proposed in the previous version of this document; no further change is needed for it.
* The planner keeps result bundles and finds the archived app with `Products/Applications/*.app`, so the new
  `HCGSentinelModern.app` name needs no change in Maker.

### What Maker misreads (minor, reported separately)

`XcodeProjectAnalyzer` sets `UsesSwiftPackages` only when the project contains an `XCLocalSwiftPackageReference` or
`XCRemoteSwiftPackageReference`. Sentinel links its local package `SentinelCore` the other valid way: a folder
reference to the package plus `XCSwiftPackageProductDependency` entries on both app targets. Maker therefore labels
the project "Xcode" instead of "Xcode · Swift packages". This changes only the summary text; `xcodebuild` resolves
the package either way and the build is unaffected. Suggested change in Maker: also treat any
`XCSwiftPackageProductDependency` object as package use.

### What was not a Maker problem

The earlier archive failure ("The iOS deployment target 'IPHONEOS_DEPLOYMENT_TARGET' …") came from the selected Xcode
rejecting 14.7, not from Maker misreading the project. The separate problem fixed in this version (both targets
writing `HCGSentinel.app`) did not affect Maker, because Maker always builds a single scheme.
