#!/bin/bash
# Builds build/OpenEar.app. No dependencies beyond the Xcode Command Line Tools.
# Optional env: VERSION (e.g. 1.2.0), BUILD_NUMBER
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.0.0-dev}
BUILD_NUMBER=${BUILD_NUMBER:-1}

swift build -c release

APP=build/OpenEar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenEar "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing lets macOS remember the microphone permission between launches.
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION)"
