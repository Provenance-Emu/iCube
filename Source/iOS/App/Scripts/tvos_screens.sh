#!/bin/sh
# Screenshot every tvOS screen on the Apple TV 4K (3rd gen, 1080p) simulator.
# Usage: Scripts/tvos_screens.sh <out-dir> [--no-build] [--light|--dark] [--config appstore] [--only name,name] [--settle secs]
# Run from Source/iOS/App. Library views come from -SCREENSHOT_MODE 1 (16 demo titles).
# --config appstore  build "Debug (AppStore)" (APPSTORE gates + logo-free art, still DEBUG for the -ICube* hooks)
#                    instead of the default "Debug (Non-Jailbroken)"; the App Store Connect set comes from this.
# --settle N        seconds to wait after each launch (default 6; a cold DEBUG start needs ~45 on a loaded Mac).
# --only a,b         capture just those shots (names without the -dark/-light suffix, e.g. library-all,pause-grid).
set -eu
OUT="${1:?out dir}"; shift || true
BUILD=1; STYLE=dark; ONLY=""; SETTLE=6
CONFIG="Debug (Non-Jailbroken)"; BID=com.joemattiello.iCube-debug; SCHEME="iCube (NJB)"; DD=build-Xcode-tvsim
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0;;
    --light) STYLE=light;;
    --dark) STYLE=dark;;
    --config) shift; case "${1:?--config needs a value}" in
      appstore) CONFIG="Debug (AppStore)"; BID=com.joemattiello.iCube; SCHEME="iCube (AppStore)"; DD=build-Xcode-appstore-tvsim;;
      njb) ;;
      *) echo "unknown --config '$1' (appstore|njb)" >&2; exit 2;;
    esac;;
    --settle) shift; SETTLE="${1:?--settle needs seconds}";;
    --only) shift; ONLY=",${1:?--only needs a comma-separated list},";;
  esac
  shift
done
UDID=59214C60-C1D5-460F-91DC-BA425B4868C4
mkdir -p "$OUT"
if [ "$BUILD" = 1 ]; then
  xcodebuild build -workspace iCube.xcworkspace -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "platform=tvOS Simulator,id=$UDID" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    2>&1 | grep -E ": error:|BUILD (SUCCEEDED|FAILED)"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
# The tvOS runtime rejects `simctl ui appearance`; the DEBUG app honours `-ICubeAppearance light|dark` instead.
xcrun simctl install "$UDID" "$DD/Build/Products/$CONFIG-appletvsimulator"/iCube*.app
SHOT_COUNT=0
shot() { # name, then launch args
  name="$1"; shift
  if [ -n "$ONLY" ]; then case "$ONLY" in *",$name,"*) ;; *) return 0;; esac; fi
  SHOT_COUNT=$((SHOT_COUNT + 1))
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BID" -ICubeAppearance "$STYLE" "$@" >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$UDID" screenshot "$OUT/$name-$STYLE.png" >/dev/null
}
# Library state goes in as launch arguments (the NSUserDefaults argument domain): `simctl spawn defaults write`
# writes the simulator's global domain, which loses to whatever the app already saved in its own container.
# Filter raw values are LibraryPlatformCategory's; `all` is the My Library home.
for view in all gameCube wii; do
  shot "library-$view" -SCREENSHOT_MODE 1 -onboarding_seen_v1 YES -library_platform_filter "$view"
done
shot "library-empty" -onboarding_seen_v1 NO -library_platform_filter all
for leaf in general interface advanced graphics-video graphics-enhancements graphics-hacks graphics-advanced \
            shaders audio console-gamecube console-wii controllers performance-tuning debug web-ui icloud nearby privacy about; do
  shot "settings-$leaf" -ICubeSettingsPreview "$leaf"
done
# -SCREENSHOT_MODE 1 makes the pause menu's stand-in game the first demo title (fictional name, ID and cover).
shot "pause-grid" -SCREENSHOT_MODE 1 -ICubePausePreview
for pane in saves cheats controllers reset exit; do
  shot "pause-$pane" -SCREENSHOT_MODE 1 -ICubePausePreview -ICubePausePane "$pane"
done
# A focused save-slot tile: the tile focus ring (ICubeTileButtonStyle) only shows with focus on a tile.
shot "pause-saves-slot-focus" -SCREENSHOT_MODE 1 -ICubePausePreview -ICubePausePane saves -ICubePauseFocus slot-3
if [ -n "$ONLY" ] && [ "$SHOT_COUNT" = 0 ]; then
  echo "warning: --only matched no shot (got ${ONLY#,}); names are e.g. library-all, pause-grid, settings-controllers" >&2
  exit 1
fi
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
