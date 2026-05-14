#!/usr/bin/env bash
# Build a Release AutoRecord.app and package it into a polished DMG with a
# custom background image, an /Applications drop-target alias, and a Finder
# layout that opens to the same window every time.
#
# Output: dist/AutoRecord.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
ARCHIVE="$DIST/AutoRecord.xcarchive"
DMG_RW="$DIST/AutoRecord-rw.dmg"
DMG_PATH="$DIST/AutoRecord.dmg"
VOL_NAME="AutoRecord"
VOL_MOUNT="/Volumes/$VOL_NAME"
BACKGROUND_SRC="$REPO_ROOT/scripts/dmg-background.png"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Cleaning previous outputs"
rm -rf "$ARCHIVE" "$DMG_RW" "$DMG_PATH"
mkdir -p "$DIST"

echo "==> Archiving Release build (preBuildScript embeds autorecord-mcp)"
xcodebuild \
  -project AutoRecord.xcodeproj \
  -scheme AutoRecord \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive >/dev/null

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/AutoRecord.app"
[ -d "$APP_IN_ARCHIVE" ] || { echo "ERROR: missing $APP_IN_ARCHIVE" >&2; exit 1; }
[ -x "$APP_IN_ARCHIVE/Contents/Resources/autorecord-mcp" ] || {
  echo "ERROR: autorecord-mcp not embedded" >&2
  exit 1
}

echo "==> Creating writable DMG"
# Already unmounted from a prior run?
if [ -d "$VOL_MOUNT" ]; then
  hdiutil detach "$VOL_MOUNT" -force >/dev/null 2>&1 || true
fi
hdiutil create \
  -size 40m \
  -fs HFS+ \
  -volname "$VOL_NAME" \
  -ov \
  "$DMG_RW" >/dev/null

echo "==> Mounting writable DMG"
hdiutil attach "$DMG_RW" -nobrowse -noverify -noautoopen >/dev/null

echo "==> Populating DMG contents"
cp -R "$APP_IN_ARCHIVE" "$VOL_MOUNT/AutoRecord.app"
ln -s /Applications "$VOL_MOUNT/Applications"
mkdir -p "$VOL_MOUNT/.background"
cp "$BACKGROUND_SRC" "$VOL_MOUNT/.background/background.png"

echo "==> Setting Finder window properties (AppleScript)"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        delay 2
        set theWindow to container window
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set the bounds of theWindow to {400, 200, 1146, 800}

        set theViewOptions to the icon view options of theWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 165
        set background picture of theViewOptions to file ".background:background.png"

        set position of item "AutoRecord.app" of theWindow to {190, 320}
        set position of item "Applications" of theWindow to {550, 320}

        update without registering applications
        delay 2
        close
        delay 1
        open
        delay 2
        update without registering applications
        delay 3
        close
    end tell
end tell
APPLESCRIPT

# Give .DS_Store time to flush to disk before we detach.
sync
sleep 5

echo "==> Unmounting"
hdiutil detach "$VOL_MOUNT" >/dev/null

echo "==> Converting to compressed UDZO"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null

echo "==> Cleaning up"
rm -f "$DMG_RW"

echo
echo "Done. DMG at: $DMG_PATH"
du -h "$DMG_PATH"
