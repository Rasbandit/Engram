#!/usr/bin/env bash
# Keep the runner's Obsidian AppImage at the latest released version.
#
# Idempotent: safe to run on every setup or on a schedule.
# Runs as the runner user (no sudo) — everything lives under $HOME/Applications.
#
# Usage:
#   bash .github/update-obsidian.sh           # update if newer version available
#   bash .github/update-obsidian.sh --force   # re-download + re-extract always
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

OBSIDIAN_DIR="$HOME/Applications"
OBSIDIAN_APPIMAGE="$OBSIDIAN_DIR/Obsidian.AppImage"
OBSIDIAN_EXTRACTED="$OBSIDIAN_DIR/obsidian-extracted"
OBSIDIAN_VERSION_FILE="$OBSIDIAN_DIR/.obsidian-version"

mkdir -p "$OBSIDIAN_DIR"

LATEST=$(curl -sfL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
  | grep -oE '"tag_name":[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
  | head -1 \
  | sed -E 's/.*"v([0-9.]+)".*/\1/')

if [ -z "$LATEST" ]; then
  echo "WARNING: could not query latest Obsidian version — keeping current install" >&2
  exit 0
fi

INSTALLED=""
[ -f "$OBSIDIAN_VERSION_FILE" ] && INSTALLED=$(cat "$OBSIDIAN_VERSION_FILE")

if [ "$FORCE" -eq 0 ] && [ "$INSTALLED" = "$LATEST" ] && [ -d "$OBSIDIAN_EXTRACTED" ] && [ -f "$OBSIDIAN_APPIMAGE" ]; then
  echo "Obsidian ${LATEST} already installed and extracted"
  exit 0
fi

echo "Updating Obsidian: ${INSTALLED:-none} → ${LATEST}"

URL="https://github.com/obsidianmd/obsidian-releases/releases/download/v${LATEST}/Obsidian-${LATEST}.AppImage"
TMP="${OBSIDIAN_APPIMAGE}.new"

# Download to .new, then atomic-move so a failed download doesn't nuke the working copy
curl -fL --retry 3 --retry-delay 2 -o "$TMP" "$URL"
chmod +x "$TMP"
mv -f "$TMP" "$OBSIDIAN_APPIMAGE"

# Re-extract (pre-extraction eliminates ~15-30s per Obsidian boot in tests)
rm -rf "$OBSIDIAN_EXTRACTED" "$OBSIDIAN_DIR/squashfs-root"
(
  cd "$OBSIDIAN_DIR"
  "$OBSIDIAN_APPIMAGE" --appimage-extract > /dev/null
  mv squashfs-root "$OBSIDIAN_EXTRACTED"
)

echo "$LATEST" > "$OBSIDIAN_VERSION_FILE"
echo "  ✓ Obsidian ${LATEST} extracted to ${OBSIDIAN_EXTRACTED}"
