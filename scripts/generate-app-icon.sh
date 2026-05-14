#!/usr/bin/env bash
# Regenerate AutoRecord/Resources/Assets.xcassets/AppIcon.appiconset
# from assets/app-icon.png. Run after replacing the master icon.
#
# Uses `sips`, which ships with macOS, so no extra dependencies.

set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/app-icon.png"
OUT="AutoRecord/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
  echo "ERROR: missing source icon at $SRC" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/icon_*.png

# 1x then @2x for each macOS size.
declare -a SIZES=(
  "16  icon_16x16.png"
  "32  icon_16x16@2x.png"
  "32  icon_32x32.png"
  "64  icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
  size="${entry%% *}"
  name="${entry##* }"
  sips -Z "$size" "$SRC" --out "$OUT/$name" >/dev/null
done

cat >"$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",     "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",  "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",     "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",  "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",   "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png","scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",   "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png","scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",   "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png","scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

# Asset catalogs also expect a top-level Contents.json (created once).
CAT_ROOT="AutoRecord/Resources/Assets.xcassets"
if [ ! -f "$CAT_ROOT/Contents.json" ]; then
  cat >"$CAT_ROOT/Contents.json" <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
fi

echo "Generated $(ls "$OUT"/icon_*.png | wc -l | tr -d ' ') icon files in $OUT"
