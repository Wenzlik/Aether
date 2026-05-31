#!/bin/sh
# Xcode Cloud pre-xcodebuild — runs after dependencies have resolved but
# before `xcodebuild` itself.
#
# Aether's Info.plist sets `CFBundleVersion` to `$(CURRENT_PROJECT_VERSION)`,
# which is `"1"` locally (from `project.yml`). That's fine for local builds
# but breaks repeated TestFlight uploads — App Store Connect rejects a
# duplicate `CFBundleShortVersionString` + `CFBundleVersion` pair.
#
# Xcode Cloud sets `CI_BUILD_NUMBER` per-build. We rewrite the single Info.plist
# with PlistBuddy to that number so every cloud archive ships a unique build
# number. Marketing version (`CFBundleShortVersionString`) stays in
# `project.yml` and is bumped manually between trains.
#
# References:
#   https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds
#   https://developer.apple.com/documentation/xcode/environment-variable-reference

set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER is unset; leaving Info.plist alone (local run?)."
  exit 0
fi

PLISTBUDDY="/usr/libexec/PlistBuddy"
WORKSPACE="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"
PLIST="$WORKSPACE/Aether/SupportingFiles/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "ci_pre_xcodebuild: ERROR — $PLIST not found (did ci_post_clone run xcodegen?)"
  exit 1
fi

echo "ci_pre_xcodebuild: setting CFBundleVersion=$CI_BUILD_NUMBER in $PLIST"
"$PLISTBUDDY" -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$PLIST"

echo "ci_pre_xcodebuild: done"
