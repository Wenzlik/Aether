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

# ── Sparkle appcast (#405) ───────────────────────────────────────────────────
# EdDSA-sign the DMG and write the appcast Sparkle clients poll (SUFeedURL).
# We build the item directly around `sign_update` rather than letting
# `generate_appcast` sign: in 2.9.3 generate_appcast silently omits the
# edSignature when given --ed-key-file, and a SILENTLY unsigned appcast makes
# every client REJECT the update (SUPublicEDKey is set) — worse than a hard
# fail. So we sign explicitly and assert the signature is present.
#
# Signing key: the EdDSA private key in the login Keychain (account "ed25519",
# created by `generate_keys` — see RELEASING-macos.md). First use in a Terminal
# session prompts once to allow access ("Always Allow"). For CI / a second Mac,
# set SPARKLE_ED_KEY_FILE to an exported key file (`generate_keys -x`).
SPARKLE_BIN="$ROOT/Vendor/Sparkle/bin"
if [ -x "$SPARKLE_BIN/sign_update" ]; then
  echo "==> signing update + writing appcast"
  APPCAST_DIR="$ROOT/build/appcast"
  mkdir -p "$APPCAST_DIR"

  KEY_ARGS=()
  [ -n "${SPARKLE_ED_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")

  # sign_update prints: sparkle:edSignature="…" length="…"
  SIGN_OUT="$("$SPARKLE_BIN/sign_update" "${KEY_ARGS[@]}" "$DMG")"
  EDSIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  LENGTH="$(stat -f%z "$DMG")"
  MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 26.0)"
  PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

  [ -n "$EDSIG" ] || { echo "error: failed to EdDSA-sign the DMG (no key access?). $SIGN_OUT" >&2; exit 1; }

  # Single-item appcast: the latest release. That's all Sparkle needs to detect
  # an update; sparkle:version is the (monotonic) build number it compares.
  cat > "$APPCAST_DIR/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Aether</title>
        <link>https://aetherplayer.com/appcast.xml</link>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <link>https://aetherplayer.com</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <enclosure url="https://aetherplayer.com/downloads/$(basename "$DMG")" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$EDSIG"/>
        </item>
    </channel>
</rss>
XML
  echo "    appcast: $APPCAST_DIR/appcast.xml  (version $VERSION build $BUILD, signed)"
else
  echo "==> WARNING: Sparkle tools not found ($SPARKLE_BIN)"
  echo "    Run scripts/fetch-sparkle-tools.sh, then re-run — without the appcast"
  echo "    clients won't see this release as an update."
fi

echo
echo "==> done: $DMG"
echo "    Deploy with scripts/deploy-dmg.sh (uploads the DMG + appcast.xml)."
