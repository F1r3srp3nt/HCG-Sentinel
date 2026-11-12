# Building with HCG Executable Maker

## What Maker needs, and where it is

| Maker looks for | In this repository |
| --- | --- |
| An Xcode project at the root | `HCGSentinel.xcodeproj` (committed; no generation step is needed before building) |
| Shared schemes | `HCGSentinel` and `HCGSentinelModern` in `HCGSentinel.xcodeproj/xcshareddata/xcschemes` |
| An application target | `HCGSentinel` (iOS 14.7+) and `HCGSentinelModern` (iOS 15.0+) |
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

## Companion changes proposed for HCG Executable Maker

Maker is not the cause of this failure, and no change to it is required for Route A or B. These would have made the
problem obvious and are specified here rather than applied, because that repository is a separate product:

1. **Preflight deployment-range check.** `XcodeProjectAnalyzer` already reads each target's
   `IPHONEOS_DEPLOYMENT_TARGET`. In readiness, compare it with the selected Xcode's supported range and report,
   before building: "Target HCGSentinel needs iOS 14.7; the selected Xcode supports X–Y. Select another Xcode in
   Toolchains or choose a scheme whose target is within range." The range can be read from the selected Xcode's
   iOS platform metadata (`DEVELOPER_DIR/Platforms/iPhoneOS.platform` SDK settings: minimum and maximum deployment
   target).
2. **Show the whole first error.** The build view truncates long lines. Surface the first `error:` line in full
   (wrapped) in the failure summary instead of only "failed with exit code 65".
3. **Expose the build configuration for iOS.** `MobileBuildOptions.Variant` is already honoured by `XcodePlanner`
   (`-configuration`), but the iOS options screen only offers schemes. Listing the project's configurations would
   let projects offer variants without extra targets.
4. **Keep the result bundle.** Add `-resultBundlePath <work>/<scheme>.xcresult` to archive and export steps and
   keep it with the log on failure.
