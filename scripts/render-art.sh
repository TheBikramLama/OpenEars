#!/bin/bash
# Regenerates the app icon, DMG background and install guide GIF in assets/.
# The outputs are committed, so builds don't need to run this.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift scripts/render-art.swift "$WORK"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

mkdir -p assets
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
# One TIFF holding both resolutions, so the DMG window is sharp on Retina screens.
tiffutil -cathidpicheck "$WORK/dmg-background.png" "$WORK/dmg-background@2x.png" -out assets/dmg-background.tiff 2> /dev/null
cp "$WORK/icon-1024.png" assets/icon-1024.png
swift scripts/render-install-guide.swift assets/install-guide.gif assets/icon-1024.png

echo "Rendered assets/"
