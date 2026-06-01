#!/bin/sh
# Xcode Cloud pre-xcodebuild — runs after dependencies have resolved but
# before `xcodebuild` itself.
#
# Goal: make `CFBundleVersion` unique per Xcode Cloud build so repeated
# TestFlight uploads aren't rejected with "The bundle version must be higher
# than the previously uploaded version." (code 90060 / 90487).
#
# Xcode Cloud's `CI_BUILD_NUMBER` is unique per build across the team, so we
# use it as the build number. Local runs (no CI_BUILD_NUMBER set) leave
# everything alone — the static "1" from `project.yml` survives.
#
# We patch TWO places, belt-and-suspenders, because Xcode's archive step has
# been observed to re-substitute `$(CURRENT_PROJECT_VERSION)` from the build
# setting at packaging time and overwrite a PlistBuddy-patched Info.plist:
#
#   1. `Info.plist` — direct `CFBundleVersion` literal (covers Xcode reading
#      the file verbatim).
#   2. `project.pbxproj`'s `CURRENT_PROJECT_VERSION` build setting (covers
#      Xcode re-substituting `$(CURRENT_PROJECT_VERSION)` from build
#      settings).
#
# References:
#   https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds
#   https://developer.apple.com/documentation/xcode/environment-variable-reference

set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER is unset; leaving build number alone (local run?)."
  exit 0
fi

WORKSPACE="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"
PLIST="$WORKSPACE/Aether/SupportingFiles/Info.plist"
PROJ="$WORKSPACE/Aether.xcodeproj/project.pbxproj"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [ ! -f "$PLIST" ]; then
  echo "ci_pre_xcodebuild: ERROR — $PLIST not found (did ci_post_clone run xcodegen?)"
  exit 1
fi
if [ ! -f "$PROJ" ]; then
  echo "ci_pre_xcodebuild: ERROR — $PROJ not found (did ci_post_clone run xcodegen?)"
  exit 1
fi

echo "ci_pre_xcodebuild: setting CFBundleVersion=$CI_BUILD_NUMBER"

# 1. Info.plist — replace whatever was there with the literal build number.
"$PLISTBUDDY" -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$PLIST"
echo "ci_pre_xcodebuild: patched $PLIST"
"$PLISTBUDDY" -c "Print :CFBundleVersion" "$PLIST"

# 2. project.pbxproj — overwrite every CURRENT_PROJECT_VERSION = N; line.
#    `sed -i ''` is BSD sed (macOS). Pattern matches any non-semicolon run so
#    we don't care what the previous value was.
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/g" "$PROJ"
echo "ci_pre_xcodebuild: patched CURRENT_PROJECT_VERSION in $PROJ"
grep "CURRENT_PROJECT_VERSION" "$PROJ" | head -2 || true

echo "ci_pre_xcodebuild: done"
