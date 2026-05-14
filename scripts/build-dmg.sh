#!/usr/bin/env bash
# Build a Release AutoRecord.app and package it into a DMG that contains
# the app + an alias to /Applications + a README explaining the unsigned-app
# Gatekeeper caveat. Run from the repo root.
#
# Output: dist/AutoRecord.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/dmg-stage"
ARCHIVE="$DIST/AutoRecord.xcarchive"
DMG_PATH="$DIST/AutoRecord.dmg"
VOL_NAME="AutoRecord"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Cleaning previous outputs"
rm -rf "$STAGE" "$ARCHIVE" "$DMG_PATH"
mkdir -p "$STAGE"

echo "==> Archiving Release build (this also runs the preBuildScript that embeds autorecord-mcp)"
xcodebuild \
  -project AutoRecord.xcodeproj \
  -scheme AutoRecord \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/AutoRecord.app"
if [ ! -d "$APP_IN_ARCHIVE" ]; then
  echo "ERROR: AutoRecord.app not found inside archive at $APP_IN_ARCHIVE" >&2
  exit 1
fi

echo "==> Verifying embedded MCP binary is present"
MCP_IN_APP="$APP_IN_ARCHIVE/Contents/Resources/autorecord-mcp"
if [ ! -x "$MCP_IN_APP" ]; then
  echo "ERROR: autorecord-mcp not embedded at $MCP_IN_APP" >&2
  exit 1
fi
file "$MCP_IN_APP"

echo "==> Staging DMG contents"
cp -R "$APP_IN_ARCHIVE" "$STAGE/AutoRecord.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-README.txt "$STAGE/README.txt"

echo "==> Creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Cleaning staging directory"
rm -rf "$STAGE"

echo
echo "Done. DMG at: $DMG_PATH"
du -h "$DMG_PATH"
