#!/usr/bin/env bash
#
# ship-platforms.sh — trigger the per-platform Xcode Cloud archives that are
# gated on git tags.
#
# Aether is one app for many platforms, all built from `main`. To let each
# platform ship on its own cadence (and to avoid App Store Connect rejecting
# simultaneous deliveries), the Xcode Cloud workflows are split:
#
#   • iOS       — "Branch Changes" on `main`  → builds AUTOMATICALLY on every push.
#   • tvOS      — "Tag Changes" `tvos/…`      → builds only when a tvos/ tag is pushed.
#   • visionOS  — "Tag Changes" `visionos/…`  → builds only when a visionos/ tag is pushed.
#   • macOS     — (added later, gated on `macos/…`)
#
# So a plain promotion to `main` ships iOS; this script pushes the tags that
# ship the rest. Run it right AFTER a release lands on `main`, so every platform
# gets the same build iOS just got. See RELEASING.md.
#
# Tag format:  <platform>/<MARKETING_VERSION>-<short-sha>
#   e.g. tvos/0.6.4-b436e24 — unique per build (so re-builds of the same
#   marketing version still trigger) and traceable to the exact commit.
#
# Usage:  scripts/ship-platforms.sh [ref]
#         ref defaults to origin/main.
#
set -euo pipefail

# Tag-gated platforms. iOS is intentionally absent (it auto-builds on `main`).
# Add "macos" here once its workflow exists.
PLATFORMS=(tvos visionos)

REF="${1:-origin/main}"
git fetch origin --quiet --tags

SHA=$(git rev-parse --short "$REF")
VERSION=$(git show "$REF:project.yml" | grep -m1 'MARKETING_VERSION:' | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$VERSION" ] || { echo "error: could not read MARKETING_VERSION from $REF:project.yml" >&2; exit 1; }

echo "Shipping $VERSION ($SHA) to: ${PLATFORMS[*]}"
for plat in "${PLATFORMS[@]}"; do
  TAG="$plat/$VERSION-$SHA"
  if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    echo "  · $TAG already exists — skipping"
    continue
  fi
  git tag "$TAG" "$REF"
  git push origin "$TAG" >/dev/null
  echo "  ✓ pushed $TAG"
done
echo "Done. iOS builds from the main push; the tags above trigger tvOS / visionOS."
