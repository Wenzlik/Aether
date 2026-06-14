#!/usr/bin/env bash
# Provide libmpv (the engine behind IINA) for the macOS target, plus the tool
# used to bundle it into a self-contained .app.
#
# The AetherMac player uses libmpv via the C module `Cmpv` (headers vendored in
# Vendor/Mpv/include, module.modulemap committed). libmpv itself + its ffmpeg/
# libass/etc. dependency tree are NOT vendored — we link Homebrew's libmpv at
# build time and a post-build phase (dylibbundler) copies the whole tree into
# AetherMac.app/Contents/Frameworks with @rpath install names, so the shipped
# app is self-contained and runs on Macs without Homebrew (Xcode Cloud, users).
#
# Apple Silicon Homebrew lives at /opt/homebrew.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found. Install from https://brew.sh, then re-run." >&2
  exit 1
fi

# Avoid Homebrew's auto-update (ghcr.io portable-ruby flakiness on CI; see
# ci_post_clone.sh). We deliberately do NOT set HOMEBREW_NO_INSTALL_FROM_API:
# on a clean Xcode Cloud VM there's no homebrew-core git tap, so forcing the
# git path makes `brew install` clone the whole tap (slow) or fail outright.
# The JSON API path is the CI-friendly default; only auto-update is the flake.
export HOMEBREW_NO_AUTO_UPDATE=1

for formula in mpv dylibbundler; do
  if brew list "$formula" >/dev/null 2>&1; then
    echo "fetch_mpv: $formula already installed"
    continue
  fi
  # Retry once — brew bottle downloads on CI runners are occasionally flaky, and
  # a failed install here fails the whole macOS archive. Use ${formula} (braced)
  # + ASCII "..." — a bare `$formula...` with a Unicode ellipsis tripped `set -u`
  # on the CI runner (non-UTF-8 locale parsed the ellipsis bytes into the name).
  echo "fetch_mpv: installing ${formula}..."
  brew install "$formula" || { echo "fetch_mpv: ${formula} install failed, retrying..."; sleep 5; brew install "$formula"; }
done

echo "fetch_mpv: libmpv at $(brew --prefix)/lib/libmpv.dylib"
echo "fetch_mpv: dylibbundler at $(command -v dylibbundler)"
