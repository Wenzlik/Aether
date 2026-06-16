#!/usr/bin/env bash
# Fetch the OFFICIAL Sparkle CLI tools (generate_keys / sign_update /
# generate_appcast) used to sign macOS auto-update releases (#405).
#
# The app links Sparkle via SPM (see project.yml); these are just the companion
# command-line tools, which SPM does NOT install. We pull them from Sparkle's
# official GitHub release tarball — the same version we link — and drop the
# binaries in Vendor/Sparkle/bin (gitignored). The release scripts add that to
# PATH automatically.
#
# We deliberately do NOT use `brew install sparkle`: that formula is deprecated
# (fails Gatekeeper) and slated for removal. The release tarball is the canonical
# distribution.
#
# Pin: Sparkle 2.9.3. Bump URL + SHA256 together with the SPM version.
set -euo pipefail
VERSION="2.9.3"
ASSET="Sparkle-${VERSION}.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/${ASSET}"
SHA256="74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/Sparkle"
BIN="$DIR/bin"
ARCHIVE="$DIR/${ASSET}"

if [ -x "$BIN/generate_appcast" ] && [ -x "$BIN/sign_update" ] && [ -x "$BIN/generate_keys" ]; then
  echo "Sparkle tools already present ($BIN) — skipping."
  exit 0
fi
mkdir -p "$DIR"
echo "Downloading Sparkle ${VERSION} tools (~15 MB)…"
curl -fSL --retry 3 --retry-all-errors "$URL" -o "$ARCHIVE"
echo "Verifying sha256…"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
echo "Extracting bin/…"
# Tarball entries are prefixed with ./ — extract just the CLI tools.
tar -xJf "$ARCHIVE" -C "$DIR" --strip-components=1 ./bin/generate_keys ./bin/sign_update ./bin/generate_appcast
rm -f "$ARCHIVE"
chmod +x "$BIN"/*
echo "Sparkle tools ready: $BIN"
