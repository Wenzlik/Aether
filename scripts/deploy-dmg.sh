#!/usr/bin/env bash
#
# deploy-dmg.sh — upload a built+notarized macOS DMG to the website download
# section (Synology web/aether/downloads) and verify it's live.
#
# Build the DMG first with scripts/package-mac.sh, then:
#   scripts/deploy-dmg.sh                       # newest build/Aether-*.dmg
#   scripts/deploy-dmg.sh build/Aether-0.7.3.dmg
#
# Uses an SSH key (keyless) and pipes via the login shell — the NAS's SFTP/scp is
# chrooted to the home dir and can't reach /volume1/web, but the shell can.
# Overridable via env: NAS_HOST, NAS_PORT, NAS_USER, SSH_KEY, WEB_ROOT, SITE_URL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$(ls -t "$ROOT"/build/Aether-*.dmg 2>/dev/null | head -1 || true)}"
[ -n "${DMG:-}" ] && [ -f "$DMG" ] || {
  echo "usage: $0 <path-to-dmg>   (defaults to newest build/Aether-*.dmg)" >&2; exit 1; }

NAS_HOST="${NAS_HOST:-192.168.1.10}"
NAS_PORT="${NAS_PORT:-5002}"
NAS_USER="${NAS_USER:-venda}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/aether_synology}"
WEB_ROOT="${WEB_ROOT:-/volume1/web/aether}"
SITE_URL="${SITE_URL:-https://aetherplayer.com}"

NAME="$(basename "$DMG")"
DEST="$WEB_ROOT/downloads/$NAME"
SSH=(ssh -i "$SSH_KEY" -p "$NAS_PORT" -o BatchMode=yes "$NAS_USER@$NAS_HOST")

echo "==> uploading $NAME ($(du -h "$DMG" | cut -f1)) → $NAS_HOST:$DEST"
"${SSH[@]}" "mkdir -p '$WEB_ROOT/downloads'; cat > '$DEST'" < "$DMG"
"${SSH[@]}" "chmod 644 '$DEST'"

echo "==> verifying integrity (sha256)"
LOCAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
REMOTE="$("${SSH[@]}" "sha256sum '$DEST' 2>/dev/null | awk '{print \$1}'")"
if [ "$LOCAL" = "$REMOTE" ]; then echo "    checksum OK ($LOCAL)"; else
  echo "    CHECKSUM MISMATCH  local=$LOCAL  remote=$REMOTE" >&2; exit 1; fi

echo "==> verifying https"
curl -sS -m 30 -o /dev/null -w "    HTTP %{http_code}  (%{size_download} bytes)\n" "$SITE_URL/downloads/$NAME" || true

echo "==> done: $SITE_URL/downloads/$NAME"
