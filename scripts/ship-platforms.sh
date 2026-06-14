#!/usr/bin/env bash
#
# ship-platforms.sh — trigger the per-platform Xcode Cloud archives that are
# gated on git tags.
#
# Aether is one app for many platforms, all built from `main`. Every platform's
# Xcode Cloud workflow is gated on a git tag (none auto-build on a plain push),
# so this one script ships them all from the same commit, on demand:
#
#   • iOS       — "Tag Changes" `ios/…`
#   • tvOS      — "Tag Changes" `tvos/…`
#   • visionOS  — "Tag Changes" `visionos/…`
#   • macOS     — "Tag Changes" `macos/…`
#
# Merging staging → main means "ready"; running this script means "ship". Run it
# right AFTER a release lands on `main` so all platforms build the same commit.
# See RELEASING.md.
#
# Tag format:  <platform>/<MARKETING_VERSION>-<short-sha>
#   e.g. tvos/0.6.4-b436e24 — unique per build (so re-builds of the same
#   marketing version still trigger) and traceable to the exact commit.
#
# Usage:  scripts/ship-platforms.sh [ref]
#         ref defaults to origin/main.
#
set -euo pipefail

# Tag-gated platforms — all of them (macOS workflow now exists).
PLATFORMS=(ios tvos visionos macos)

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
echo "Done. The tags above trigger each platform's Xcode Cloud archive."
