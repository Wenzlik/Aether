#!/usr/bin/env bash
# Fetch the OFFICIAL VideoLAN VLCKit xcframework for the local SPM binaryTarget.
# VideoLAN ships VLCKit as a CocoaPods .tar.xz (no SPM package of their own), so
# we download → verify sha256 → extract the .xcframework here. It's .gitignored
# (~2.4 GB extracted); run this before building. CI runs it too (cached).
#
# Pin: VLCKit 4.0.0a19 — first VLCKit with visionOS. Update URL+SHA together.
#
# Fetch from a mirror on this repo's GitHub Releases FIRST: Xcode Cloud's build
# environment can't resolve download.videolan.org ("Could not resolve host"),
# but it reaches github.com (it clones from there). The mirror is the
# byte-identical official artifact, so the sha256 check below still passes.
# VideoLAN's CDN stays as a fallback for anywhere github is unreachable.
set -euo pipefail
ASSET="VLCKit-4.0.0a19-d7597c1706-85a537d69.tar.xz"
MIRROR_URL="https://github.com/Wenzlik/Aether/releases/download/vlckit-4.0.0a19/${ASSET}"
URL="https://download.videolan.org/cocoapods/unstable/${ASSET}"
SHA256="1172078a43150af202c31feb62db3d6687f242d3aa048cce1b899f51c4f14142"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/VLCKit"
XCF="$DIR/VLCKit.xcframework"
ARCHIVE="$DIR/VLCKit.tar.xz"

if [ -d "$XCF" ]; then echo "VLCKit.xcframework already present — skipping."; exit 0; fi
mkdir -p "$DIR"
echo "Downloading VLCKit 4.0.0a19 (~522 MB)…"
if ! curl -fSL --retry 3 --retry-all-errors "$MIRROR_URL" -o "$ARCHIVE"; then
  echo "GitHub mirror unavailable — falling back to VideoLAN CDN…"
  curl -fSL --retry 3 --retry-all-errors "$URL" -o "$ARCHIVE"
fi
echo "Verifying sha256…"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
echo "Extracting…"
tar -xJf "$ARCHIVE" -C "$DIR"
rm -f "$ARCHIVE"
# VideoLAN nests everything under VLCKit-binary/.
if [ -d "$DIR/VLCKit-binary/VLCKit.xcframework" ]; then
  mv "$DIR/VLCKit-binary/VLCKit.xcframework" "$XCF"
  cp -f "$DIR/VLCKit-binary/COPYING.txt" "$DIR/COPYING.txt" 2>/dev/null || true
  rm -rf "$DIR/VLCKit-binary"
fi
[ -d "$XCF" ] || { echo "error: VLCKit.xcframework missing after extract" >&2; exit 1; }
echo "VLCKit ready at $XCF"
