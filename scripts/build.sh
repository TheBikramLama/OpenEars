#!/bin/bash
# Builds build/OpenEar.app with SoX bundled inside, so users don't need Homebrew.
# Needs: brew install sox dylibbundler
# Optional env: VERSION (e.g. 1.2.0), BUILD_NUMBER
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.0.0-dev}
BUILD_NUMBER=${BUILD_NUMBER:-1}
SOX_PREFIX=$(brew --prefix sox)

swift build -c release

APP=build/OpenEar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/OpenEar "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Copy SoX and rewrite its Homebrew library paths to point inside the app.
cp "$SOX_PREFIX/bin/sox" "$APP/Contents/MacOS/sox"
chmod u+w "$APP/Contents/MacOS/sox"
dylibbundler --overwrite-files --bundle-deps \
    --fix-file "$APP/Contents/MacOS/sox" \
    --dest-dir "$APP/Contents/Frameworks" \
    --install-path @executable_path/../Frameworks/ > /dev/null 2>&1

# SoX is GPL. It ships as a separate program, and its licence travels with it.
cp "$SOX_PREFIX/LICENSE.GPL" "$APP/Contents/Resources/SoX-LICENSE.GPL"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing lets macOS remember the microphone permission between launches.
# Sign the insides first; the app signature seals them.
codesign --force --sign - "$APP"/Contents/Frameworks/*.dylib "$APP/Contents/MacOS/sox"
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION)"
