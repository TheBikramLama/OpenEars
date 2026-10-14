#!/bin/bash
# Packs build/OpenEar.app into dist/OpenEar-<version>.dmg with a drag-to-Applications shortcut.
# Run scripts/build.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.0.0-dev}
DMG="dist/OpenEar-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/OpenEar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname OpenEar -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
shasum -a 256 "$DMG" | sed 's|dist/||' > "$DMG.sha256"

echo "Built $DMG"
