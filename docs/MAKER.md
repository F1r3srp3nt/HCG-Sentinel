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

### Maker 0.3.1 or later is required with an Xcode that starts at iOS 15.0

Maker up to 0.3.0 named `HCGSentinelModern` as the route but could not use it: it judged every output with the
project's first scheme (`HCGSentinel`, 14.7), so with an Xcode whose range starts at 15.0 all outputs were unavailable,
the scheme picker never appeared, and its build engine would have refused the modern scheme for the legacy scheme's
reason. The status read "Required toolchain missing". Nothing in this repository caused that and nothing here was
changed for it; the fix is in Maker (scheme chosen before outputs, saved per project, used by every check and by
`xcodebuild -scheme`). Details: Maker's `docs/HCG-PROJECTS.md`, “HCG Sentinel — scheme selection on an iOS 15 Xcode”.

Check on the Mac (sidebar footer, Settings › About, or in Terminal):

```bash
"/Applications/HCG Executable Maker.app/Contents/MacOS/HCGExecutableMaker" --version
```

It must say 0.3.1 or later. Then, in Mobile Build Studio: choose scheme **HCGSentinelModern** in section 2 (or press
“Use scheme HCGSentinelModern”), confirm trust in section 5, build.

### Is Maker building this revision?

Maker builds a **copy** of the folder or ZIP taken at import, not the folder itself. Mobile Build Studio shows under
“Imported copy” whether that copy still matches the original (and the original's Git commit); **Refresh source**
copies it again without losing the project or the scheme choice. **Copy diagnostic report** (or
`HCGExecutableMaker --diagnose-mobile`) lists SHA-256 hashes of the files that decide schemes and deployment targets.
For `main` at 03bc6e5 they are:

| File | SHA-256 at 03bc6e5 (`main`) | at 810c6f9 (older) |
| --- | --- | --- |
| `HCGSentinel.xcodeproj/project.pbxproj` | `8a5c6cfbcd930074f61284538a64fd191bb31f2d3d665b05c5c66f73afe9e0b0` | `38d95aa724b0fad6f99806ff5ccf70d260af0f03433162a9b94ce0b0850b2545` |
| `…/xcschemes/HCGSentinel.xcscheme` | `3cdf71c801f54e86d68b905672bcddf8d70cbf1ab597f00cc66b1ca08ad254a1` | same |
| `…/xcschemes/HCGSentinelModern.xcscheme` | `1e95a1302043a8b80d5a092accd4f5286829a10809fe55aeeee385a8fe1f7b5a` | `bc3e14ca0cfdcf0f2609f053a33dcc7f9e604f2e1fabf070b26a4888d8f5af89` |

A ZIP downloaded from GitHub produces the same files, so the same hashes apply. Any other value means the copy is from
another revision: refresh it from an up-to-date folder or ZIP.

### What Maker reads correctly (checked against its `main`, commit 660fcc3; the scheme handling was corrected in 0.3.1)

* `XcodeProjectAnalyzer` takes each target's settings on top of the project's, so it reports 14.7 for
  `HCGSentinel` (inherited) and 15.0 for `HCGSentinelModern` (set on the target). Correct.
* Schemes: it reads the Archive action's target and configuration from the shared `.xcscheme` files. Both schemes
  name exactly one app target and archive with Release. Correct.
* `MobileReadiness.AddDeploymentRange` compares those targets with the selected Xcode's
  `SupportedTargets.iphoneos` range from `SDKSettings.json` and names the other scheme as a route when one is out of
  range. **Correction:** an earlier version of this document said no further change was needed. That was wrong: up to
  Maker 0.3.0 the check was only scheme-aware when called directly; the output list and the build engine called it
  without the scheme, so the named route could not be taken. Fixed in Maker 0.3.1 (see above).
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
