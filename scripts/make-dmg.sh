#!/bin/bash
# Packs build/OpenEar.app into dist/OpenEar-<version>.dmg with a styled drag-to-Applications window.
# Run scripts/build.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.0.0-dev}
DMG="dist/OpenEar-$VERSION.dmg"

# dmgbuild writes the window layout directly, so it works on CI without scripting Finder.
VENV=.build/dmg-venv
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet "dmgbuild>=1.6,<2"
fi

mkdir -p dist
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app=build/OpenEar.app \
    -D icon=assets/AppIcon.icns \
    -D background=assets/dmg-background.tiff \
    OpenEar "$DMG"
shasum -a 256 "$DMG" | sed 's|dist/||' > "$DMG.sha256"

echo "Built $DMG"
