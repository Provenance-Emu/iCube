#!/usr/bin/env bash
#
# Generates per-scheme iOS app-icon variants from the canonical AppIcon art.
#
# Each variant recolors the (blue) background by rotating its hue and stamps a
# bold corner badge so the build channel is identifiable at a glance on the home
# screen. The white "dolphin-in-cube" logo is hue-invariant (saturation 0), so it
# stays white across every variant.
#
# Idempotent: rerunning overwrites the generated *.appiconset folders. The base
# AppIcon (blue, App Store) and AppIconBeta (yellow) sets are never touched.
#
# Requires ImageMagick (`magick`). Run from anywhere:
#   Source/iOS/App/Project/Scripts/GenerateAppIcons.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/../../DolphiniOS/Assets.xcassets"
SRC="$ASSETS/AppIcon.appiconset/iCube icon2.png"
FONT="/System/Library/Fonts/Supplemental/Arial Bold.ttf"

[ -f "$SRC" ] || { echo "error: base icon not found: $SRC" >&2; exit 1; }
command -v magick >/dev/null || { echo "error: ImageMagick (magick) not installed" >&2; exit 1; }

# name | hue (100 = no shift; (hue-100)/100*180 degrees) | saturation | badge | badge fill
#   blue source ~210 deg:  58 -> green, 133 -> indigo, 178 -> crimson
VARIANTS=(
  "AppIconSideload|133|110|SL|#3B1E8C"
  "AppIconTrollStore|178|115|TS|#8C1330"
  "AppIconJB|58|110|JB|#0B5D1E"
  "AppIconDebug|100|18|DEV|#1C1C1E"
)

make_contents() {
  cat > "$1/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
}

for v in "${VARIANTS[@]}"; do
  IFS='|' read -r name hue sat label fill <<< "$v"
  set_dir="$ASSETS/$name.appiconset"
  mkdir -p "$set_dir"

  # 1) Recolor background by hue rotation (white logo unaffected).
  magick "$SRC" -modulate 100,"$sat","$hue" "$set_dir/icon.png"

  # 2) Stamp a rounded badge in the top-right corner.
  badge="$set_dir/.badge.png"
  magick -size 420x230 xc:none \
    -fill "$fill" -draw "roundrectangle 0,0,419,229,46,46" \
    -fill white -font "$FONT" -gravity center -pointsize 150 -annotate +0+0 "$label" \
    "$badge"
  magick "$set_dir/icon.png" "$badge" -gravity NorthEast -geometry +44+44 -composite \
    "$set_dir/icon.png"
  rm -f "$badge"

  make_contents "$set_dir"
  echo "generated $name.appiconset ($label)"
done

echo "done."
