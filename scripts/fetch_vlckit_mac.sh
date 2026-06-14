#!/usr/bin/env bash
# Fetch the macOS-only VLCKit 3.x xcframework for the AetherMac target (#232).
#
# The unified VLCKit 4 (scripts/fetch_vlckit.sh) is built `--disable-macosx`, so
# it can't render video on a Mac. VLCKit 3.x IS the build that powers desktop VLC
# and renders on macOS — but it has no visionOS, so iOS/tvOS/visionOS stay on 4.
# Only AetherMac links this one (Vendor/VLCKitMac). .gitignored (~400 MB).
#
# Pin: VLCKit 3.7.3. Update URL+SHA together.
set -euo pipefail
ASSET="VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
URL="https://download.videolan.org/cocoapods/prod/${ASSET}"
SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/VLCKitMac"
XCF="$DIR/VLCKit.xcframework"
ARCHIVE="$DIR/VLCKit.tar.xz"

if [ -d "$XCF" ]; then echo "VLCKitMac xcframework already present — skipping."; exit 0; fi
mkdir -p "$DIR"
echo "Downloading VLCKit 3.7.3 (macOS, ~97 MB)…"
curl -fSL --retry 3 --retry-all-errors "$URL" -o "$ARCHIVE"
echo "Verifying sha256…"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
echo "Extracting…"
tar -xJf "$ARCHIVE" -C "$DIR"
rm -f "$ARCHIVE"
# VideoLAN nests everything under "VLCKit - binary package/".
if [ -d "$DIR/VLCKit - binary package/VLCKit.xcframework" ]; then
  mv "$DIR/VLCKit - binary package/VLCKit.xcframework" "$XCF"
  cp -f "$DIR/VLCKit - binary package"/COPYING* "$DIR/" 2>/dev/null || true
  rm -rf "$DIR/VLCKit - binary package"
fi
[ -d "$XCF" ] || { echo "error: VLCKit.xcframework missing after extract" >&2; exit 1; }
echo "VLCKitMac ready at $XCF"
