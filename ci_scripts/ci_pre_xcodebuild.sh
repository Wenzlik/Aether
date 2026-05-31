#!/bin/sh
# Xcode Cloud pre-xcodebuild — runs after dependencies have resolved but
# before `xcodebuild` itself.
#
# Aether's `CFBundleVersion` is `"1"` in `project.yml`, which is fine for
# local builds but breaks repeated TestFlight uploads (Apple rejects a
# duplicate `CFBundleShortVersionString` + `CFBundleVersion` pair). Apple's
# Xcode Cloud sets `CI_BUILD_NUMBER` per-build; we use it here to overwrite
# the generated Info.plist files so every cloud archive ships a unique
# build number. Marketing version (`CFBundleShortVersionString`) stays in
# `project.yml` and is bumped manually between trains.
#
# References:
#   https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds
#   https://developer.apple.com/documentation/xcode/environment-variable-reference

set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER is unset; leaving Info.plist files alone (local run?)."
  exit 0
fi

PLISTBUDDY="/usr/libexec/PlistBuddy"
WORKSPACE="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"

for plist in \
  "$WORKSPACE/Aether/SupportingFiles/Info.plist" \
  "$WORKSPACE/Aether/SupportingFiles/Info-tvOS.plist" \
  "$WORKSPACE/Aether/SupportingFiles/Info-visionOS.plist"; do
  if [ -f "$plist" ]; then
    echo "ci_pre_xcodebuild: setting CFBundleVersion=$CI_BUILD_NUMBER in $plist"
    "$PLISTBUDDY" -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$plist"
  else
    # Don't hard-fail: an Info.plist for a platform we don't archive yet
    # (e.g. tvOS before its first cloud workflow) is allowed to be missing.
    echo "ci_pre_xcodebuild: warning — $plist not found (xcodegen didn't produce it?)"
  fi
done

echo "ci_pre_xcodebuild: done"
