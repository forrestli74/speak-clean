#!/usr/bin/env bash
#
# Regenerate Resources/AppIcon/AppIcon.icns from the Swift renderer.
# Run this by hand whenever scripts/render-icon.swift changes. The result
# is committed to git; scripts/build-app.sh just copies the .icns into
# the bundle and does not invoke this script.
#
# Requires: swift, sips, iconutil (all built into macOS, no Homebrew).
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="Resources/AppIcon"
ICONSET="${OUT_DIR}/AppIcon.iconset"
SOURCE_PNG="${OUT_DIR}/icon-1024.png"
ICNS="${OUT_DIR}/AppIcon.icns"

mkdir -p "$OUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> rendering 1024 source PNG"
swift scripts/render-icon.swift "$SOURCE_PNG"

# iconutil expects these exact filenames. See `man iconutil`.
# size_at_1x  filename                    source-size
#    16       icon_16x16.png              16
#    32       icon_16x16@2x.png           32
#    32       icon_32x32.png              32
#    64       icon_32x32@2x.png           64
#   128       icon_128x128.png           128
#   256       icon_128x128@2x.png        256
#   256       icon_256x256.png           256
#   512       icon_256x256@2x.png        512
#   512       icon_512x512.png           512
#  1024       icon_512x512@2x.png       1024
echo "==> downscaling to iconset sizes"
for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size="${spec%% *}"
    name="${spec##* }"
    sips -Z "$size" "$SOURCE_PNG" --out "${ICONSET}/${name}" >/dev/null
done

echo "==> packaging .icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# Intermediate iconset is not checked in.
rm -rf "$ICONSET"

echo ""
echo "wrote $ICNS"
ls -l "$ICNS" "$SOURCE_PNG"
