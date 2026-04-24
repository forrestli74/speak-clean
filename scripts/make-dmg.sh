#!/usr/bin/env bash
#
# Wrap a signed SpeakClean.app in a compressed DMG.
#
# Usage:
#   scripts/make-dmg.sh [path/to/SpeakClean.app]
#
# Default app path: build/SpeakClean.app
# Output: build/SpeakClean.dmg
#
# The output filename is intentionally version-free so that
# https://github.com/<user>/<repo>/releases/latest/download/SpeakClean.dmg
# always resolves to the newest release's asset.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${1:-build/SpeakClean.app}"
OUT_DMG="build/SpeakClean.dmg"
VOL_NAME="SpeakClean"
STAGING_DIR="build/dmg-staging"

trap 'rm -rf "$STAGING_DIR"' EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

rm -rf "$STAGING_DIR" "$OUT_DMG"
mkdir -p "$STAGING_DIR"

# Copy the .app with `ditto` so symlinks, extended attributes, and the
# code signature survive intact. Also drop a symlink to /Applications
# so the mounted volume offers drag-to-install.
ditto "$APP_PATH" "$STAGING_DIR/SpeakClean.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUT_DMG"

echo ""
echo "built $OUT_DMG"
