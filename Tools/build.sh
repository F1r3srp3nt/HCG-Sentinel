#!/bin/bash
# HCG Sentinel build entry point. Works from a clean clone and from paths containing spaces.
#
#   Tools/build.sh info        Print toolchain and effective build settings.
#   Tools/build.sh range       Ask the selected Xcode which iOS deployment targets it supports.
#   Tools/build.sh test-core   Run the SentinelCore tests on this Mac (no simulator).
#   Tools/build.sh simulator   Build the app for the iOS Simulator (unsigned).
#   Tools/build.sh archive     Archive for a generic iOS device.
#   Tools/build.sh inspect     Inspect the app inside the last archive.
#   Tools/build.sh export      Export an IPA from the last archive (needs a signed archive).
#
# Environment:
#   DEVELOPER_DIR      Xcode to use, e.g. /Applications/Xcode_16.4.app/Contents/Developer
#   DEVELOPMENT_TEAM   Apple team ID. When set, archive is signed (automatic signing). When unset, the archive
#                      is UNSIGNED: good for checking the build, not installable, not exportable.
#   BUNDLE_ID          Optional bundle identifier override for signing with your own team.
#   FLAVOR             "legacy" (default): scheme HCGSentinel, iOS 14.7 and later.
#                      "modern": scheme HCGSentinelModern, iOS 15.0 and later. Will not install on iOS 14.
#   IOS_DEPLOYMENT_TARGET  Optional explicit minimum iOS for this build only (e.g. 16.0). Use it only when the
#                      selected Xcode rejects the flavor's target; the result is reported by 'inspect'.
#   BUILD_DIR          Output directory (default: <repo>/build).
#
# Nothing here uploads anything, and a failed step always exits non-zero.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
PROJECT="$ROOT/HCGSentinel.xcodeproj"
ARCHIVE="$BUILD_DIR/HCGSentinel.xcarchive"
LOGS="$BUILD_DIR/logs"
mkdir -p "$LOGS"

FLAVOR="${FLAVOR:-legacy}"
RELEASE_CONFIG="Release"
DEBUG_CONFIG="Debug"
case "$FLAVOR" in
  legacy) SCHEME="HCGSentinel" ;;
  modern) SCHEME="HCGSentinelModern" ;;
  *) echo "FLAVOR must be 'legacy' or 'modern', not '$FLAVOR'."; exit 2 ;;
esac

target_args() {
  if [ -n "${IOS_DEPLOYMENT_TARGET:-}" ]; then printf '%s\n' "IPHONEOS_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"; fi
}

# Asks the selected Xcode which deployment targets it accepts: starts a throwaway build with a deliberately
# ancient target (iOS 8.0), waits for Xcode's own diagnostic about the supported range, then stops the build.
# The diagnostic's severity (warning or error) is printed as Xcode gave it.
supported_range() {
  local probe="$BUILD_DIR/range-probe" log="$LOGS/range-probe.log" waited=0 pid
  rm -rf "$probe"
  xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$probe" \
    CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=8.0 > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 180 ]; do
    if grep -q "deployment target" "$log" 2>/dev/null; then break; fi
    sleep 3; waited=$((waited + 3))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E "(error|warning): .*deployment target" "$log" | sed -E 's/^.*(error|warning): /\1: /' | sort -u | head -n 4
  rm -rf "$probe"
}

signing_args() {
  if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    printf '%s\n' "CODE_SIGN_STYLE=Automatic" "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" "-allowProvisioningUpdates"
    if [ -n "${BUNDLE_ID:-}" ]; then printf '%s\n' "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"; fi
  else
    printf '%s\n' "CODE_SIGNING_ALLOWED=NO" "CODE_SIGNING_REQUIRED=NO" "CODE_SIGN_IDENTITY="
  fi
  target_args
}

# Runs xcodebuild, keeps the complete log, and lists every error line on failure.
run_xcodebuild() {
  local name="$1"; shift
  local log="$LOGS/$name.log"
  local result="$BUILD_DIR/$name.xcresult"
  rm -rf "$result"
  echo "==> xcodebuild $name (full log: $log)"
  set +e
  xcodebuild "$@" -resultBundlePath "$result" > "$log" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "xcodebuild $name FAILED with exit code $status. Error lines, first to last:"
    grep -n -E "(error:|fatal error|\*\* .* FAILED \*\*)" "$log" | cut -c1-600 || true
    echo "--- last 30 log lines ---"
    tail -n 30 "$log" | cut -c1-600
    return "$status"
  fi
  grep -E "warning: .*deployment target" "$log" | sort -u | cut -c1-400 || true
  echo "xcodebuild $name succeeded."
}

cmd_info() {
  echo "Developer directory: $(xcode-select -p) ${DEVELOPER_DIR:+(DEVELOPER_DIR is set)}"
  xcodebuild -version
  echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version) at $(xcrun --sdk iphoneos --show-sdk-path)"
  echo "Project: $PROJECT"
  xcodebuild -list -project "$PROJECT" 2>/dev/null | sed -n '/Targets:/,$p'
  echo "Flavor: $FLAVOR (scheme $SCHEME)${IOS_DEPLOYMENT_TARGET:+, IOS_DEPLOYMENT_TARGET override $IOS_DEPLOYMENT_TARGET}"
  echo "Effective settings (scheme $SCHEME, $RELEASE_CONFIG, generic iOS device):"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$RELEASE_CONFIG" -destination 'generic/platform=iOS' \
    -showBuildSettings 2>/dev/null \
    | grep -E "^ +(IPHONEOS_DEPLOYMENT_TARGET|RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET|SDK_VERSION|ARCHS|TARGETED_DEVICE_FAMILY|PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_FILE|SWIFT_VERSION|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|MARKETING_VERSION|CURRENT_PROJECT_VERSION) = " \
    || echo "  (could not read build settings)"
  echo "SentinelCore package platforms: $(grep -E 'platforms:' "$ROOT/SentinelCore/Package.swift" | sed 's/^ *//')"
}

cmd_range() {
  echo "Xcode $(xcodebuild -version | sed -n '1s/Xcode //p'), when asked to build for iOS 8.0, reports:"
  local range; range="$(supported_range)"
  if [ -n "$range" ]; then echo "$range" | cut -c1-400 | sed 's/^/  /'
  else echo "  no deployment-target diagnostic (see $LOGS/range-probe.log)"; tail -n 5 "$LOGS/range-probe.log" | cut -c1-300 | sed 's/^/  | /'; fi
}

cmd_test_core() {
  swift test --package-path "$ROOT/SentinelCore"
}

cmd_simulator() {
  local extra=()
  while IFS= read -r line; do extra+=("$line"); done < <(target_args)
  run_xcodebuild simulator build -project "$PROJECT" -scheme "$SCHEME" -configuration "$DEBUG_CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO ${extra[@]+"${extra[@]}"}
}

cmd_archive() {
  local extra=()
  while IFS= read -r line; do extra+=("$line"); done < <(signing_args)
  rm -rf "$ARCHIVE"
  run_xcodebuild archive archive -project "$PROJECT" -scheme "$SCHEME" -configuration "$RELEASE_CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    "${extra[@]}"
  if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    echo "Signed archive: $ARCHIVE"
  else
    echo "UNSIGNED archive (inspection only, not installable): $ARCHIVE"
  fi
}

cmd_inspect() {
  local app="$ARCHIVE/Products/Applications/HCGSentinel.app"
  [ -d "$app" ] || { echo "No app at $app. Run 'Tools/build.sh archive' first."; exit 1; }
  local plist="$app/Info.plist" binary="$app/HCGSentinel"
  echo "App: $app"
  echo "Bundle identifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
  echo "Info.plist MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")"
  echo "Built with: Xcode $(/usr/libexec/PlistBuddy -c 'Print :DTXcode' "$plist"), SDK $(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$plist")"
  echo "Executable architectures: $(lipo -archs "$binary")"
  echo "Executable minimum OS (from the Mach-O load command):"
  xcrun vtool -show-build "$binary" | grep -E "platform|minos|sdk" | sed 's/^/  /'
  echo "Icon files in Info.plist: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles' "$plist" 2>/dev/null | tr -d '\n' || echo none)"
  echo "Bundle contents:"
  (cd "$app" && find . -maxdepth 2 | sort | sed 's/^/  /')
  if [ -d "$app/Frameworks" ]; then echo "Embedded frameworks: $(ls "$app/Frameworks")"; else echo "Embedded frameworks: none (SentinelCore is linked statically)"; fi
  if [ -d "$app/PlugIns" ]; then echo "Embedded extensions: $(ls "$app/PlugIns")"; else echo "Embedded extensions: none"; fi
  if codesign -dv "$app" 2>/dev/null; then
    echo "Signature:"; codesign -dv "$app" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" | sed 's/^/  /'
    echo "Entitlements:"; codesign -d --entitlements - "$app" 2>/dev/null | sed 's/^/  /' || true
  else
    echo "Signature: none (unsigned build)"
  fi
}

cmd_export() {
  [ -d "$ARCHIVE" ] || { echo "No archive at $ARCHIVE. Run 'Tools/build.sh archive' first."; exit 1; }
  [ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "DEVELOPMENT_TEAM is not set. An unsigned archive cannot be exported to an IPA."; exit 1; }
  local options="$BUILD_DIR/ExportOptions.plist"
  sed "s/YOUR_TEAM_ID/$DEVELOPMENT_TEAM/" "$ROOT/Tools/ExportOptions.development.plist" > "$options"
  echo "==> xcodebuild -exportArchive (full log: $LOGS/export.log)"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$options" -exportPath "$BUILD_DIR/ipa" \
    -allowProvisioningUpdates > "$LOGS/export.log" 2>&1 || { grep -n "error" "$LOGS/export.log" | cut -c1-600; exit 1; }
  echo "IPA: $(ls "$BUILD_DIR"/ipa/*.ipa)"
}

case "${1:-}" in
  info) cmd_info ;;
  range) cmd_range ;;
  test-core) cmd_test_core ;;
  simulator) cmd_simulator ;;
  archive) cmd_archive ;;
  inspect) cmd_inspect ;;
  export) cmd_export ;;
  *) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
