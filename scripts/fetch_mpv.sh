#!/usr/bin/env bash
# Ensure libmpv (the engine behind IINA) is available for the macOS target.
#
# The AetherMac player uses libmpv via the C module `Cmpv` (headers vendored in
# Vendor/Mpv/include, module.modulemap committed). The dynamic library itself is
# NOT vendored — for dev builds we link Homebrew's libmpv, which also brings its
# ffmpeg/etc. dependency tree. This script just guarantees it's installed.
#
# Distribution (bundling libmpv + deps into the .app, fixing rpaths) comes later;
# this is the dev/local-build path. Apple Silicon Homebrew lives at /opt/homebrew.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found. Install from https://brew.sh, then re-run." >&2
  exit 1
fi

if [ ! -f "$(brew --prefix)/lib/libmpv.dylib" ]; then
  echo "Installing mpv (provides libmpv)…"
  brew install mpv
else
  echo "libmpv already present at $(brew --prefix)/lib/libmpv.dylib"
fi

echo "libmpv: $(brew --prefix)/lib/libmpv.dylib"
echo "headers: vendored in Vendor/Mpv/include/mpv"
