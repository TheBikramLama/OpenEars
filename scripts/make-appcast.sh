#!/bin/bash
# Signs dist/OpenEar-<version>.dmg and writes dist/appcast.xml, the feed Sparkle checks for updates.
# Run scripts/build.sh and scripts/make-dmg.sh first.
# Needs SPARKLE_PRIVATE_KEY: the key printed by `generate_keys --account openear -x <file>`.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:?set VERSION, e.g. 1.2.0}
BUILD_NUMBER=${BUILD_NUMBER:?set BUILD_NUMBER}
# ::error:: lines show up on the GitHub Actions run page, where the full log needs a login.
if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "::error::The SPARKLE_PRIVATE_KEY secret is not set. See Releasing in README.md."
    exit 1
fi
DMG="dist/OpenEar-$VERSION.dmg"
REPO=https://github.com/TheBikramLama/OpenEars

# SwiftPM unpacks Sparkle's command-line tools next to the framework.
SIGN_UPDATE=$(find .build/artifacts -path "*Sparkle/bin/sign_update" -maxdepth 5 | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "::error::Sparkle's sign_update tool wasn't found under .build/artifacts."
    exit 1
fi

KEY_FILE=$(mktemp)
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
# Prints: sparkle:edSignature="..." length="..."
if ! SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$DMG"); then
    echo "::error::sign_update rejected the key. SPARKLE_PRIVATE_KEY must be the exact contents of the generate_keys -x file."
    exit 1
fi

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenEar</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <enclosure url="$REPO/releases/download/v$VERSION/OpenEar-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

echo "Built dist/appcast.xml"
