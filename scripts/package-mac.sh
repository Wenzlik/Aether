#!/usr/bin/env bash
#
# package-mac.sh — build, sign (Developer ID), notarize, staple, and DMG the
# macOS app for **direct web distribution** (not the App Store — the bundled
# mpv/FFmpeg stack is GPL).
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   2. notarytool credentials stored once in the keychain:
#        xcrun notarytool store-credentials aether-notary \
#          --apple-id "you@apple.id" --team-id 8PW5FWH7P2 \
#          --password "<app-specific-password>"
#      (app-specific password: appleid.apple.com ▸ Sign-In & Security ▸ App-Specific Passwords)
#
# Usage:
#   scripts/package-mac.sh                 # build number from the date
#   BUILD_NUMBER=42 scripts/package-mac.sh # explicit build number
#
# Output: build/Aether-<version>.dmg  (notarized + stapled, ready to upload).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
BUILD="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-aether-notary}"

ARCHIVE="$ROOT/build/Aether-mac.xcarchive"
EXPORT_DIR="$ROOT/build/export"
STAGE="$ROOT/build/dmg"

echo "==> regenerating project (xcodegen)"
xcodegen generate

echo "==> archiving AetherMac (build $BUILD)"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project Aether.xcodeproj -scheme AetherMac \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true

[ -d "$ARCHIVE" ] || { echo "error: archive failed"; exit 1; }

echo "==> exporting (Developer ID)"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/ci_scripts/ExportOptions-DeveloperID.plist" \
  -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/Aether.app"
[ -d "$APP" ] || { echo "error: $APP not found after export"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> exported Aether.app  version $VERSION ($BUILD)"

echo "==> notarizing (this can take a few minutes)"
NOTARY_ZIP="$ROOT/build/Aether-notarize.zip"
rm -f "$NOTARY_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> building DMG"
DMG="$ROOT/build/Aether-$VERSION.dmg"
rm -f "$DMG"

# Prefer create-dmg for a proper installer window (sized layout, big icons, the
# app on the left and an Applications drop-target on the right). Fall back to a
# bare hdiutil image if create-dmg isn't installed.
if command -v create-dmg >/dev/null 2>&1; then
  echo "    using create-dmg (drag-to-install window)"
  # create-dmg returns non-zero if it can't bless the volume on a headless box,
  # even when the DMG is written fine — so don't let `set -e` kill us here.
  create-dmg \
    --volname "Aether $VERSION" \
    --window-pos 200 120 \
    --window-size 560 380 \
    --icon-size 120 \
    --icon "Aether.app" 150 190 \
    --app-drop-link 410 190 \
    --hide-extension "Aether.app" \
    --no-internet-enable \
    "$DMG" \
    "$APP" || true
fi

if [ ! -f "$DMG" ]; then
  echo "    create-dmg unavailable or failed — falling back to hdiutil"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"        # drag-to-install affordance
  hdiutil create -volname "Aether $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

[ -f "$DMG" ] || { echo "error: DMG was not created"; exit 1; }
echo "==> notarizing the DMG (the .app inside is already notarized+stapled)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "==> done: $DMG"
echo "    Upload it to the web download section (scripts/deploy-web.sh / NAS web/aether/downloads/)."
