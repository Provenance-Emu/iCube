#!/bin/sh
# Screenshot every tvOS screen on the Apple TV 4K (3rd gen, 1080p) simulator.
# Usage: Scripts/tvos_screens.sh <out-dir> [--no-build] [--light|--dark]
# Run from Source/iOS/App. Library views come from -SCREENSHOT_MODE 1 (16 demo titles).
set -eu
OUT="${1:?out dir}"; shift || true
BUILD=1; STYLE=dark
for a in "$@"; do case "$a" in --no-build) BUILD=0;; --light) STYLE=light;; --dark) STYLE=dark;; esac; done
UDID=59214C60-C1D5-460F-91DC-BA425B4868C4
BID=com.joemattiello.iCube-debug
DD=build-Xcode-tvsim
mkdir -p "$OUT"
if [ "$BUILD" = 1 ]; then
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" \
    -destination "platform=tvOS Simulator,id=$UDID" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    2>&1 | grep -E ": error:|BUILD (SUCCEEDED|FAILED)"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
# The tvOS runtime rejects `simctl ui appearance`; the DEBUG app honours `-ICubeAppearance light|dark` instead.
xcrun simctl install "$UDID" "$DD"/Build/Products/*appletvsimulator/iCube*.app
shot() { # name, then launch args
  name="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BID" -ICubeAppearance "$STYLE" "$@" >/dev/null
  sleep 6
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
shot "pause-grid" -ICubePausePreview
for pane in saves cheats controllers reset exit; do
  shot "pause-$pane" -ICubePausePreview -ICubePausePane "$pane"
done
# A focused save-slot tile: the tile focus ring (ICubeTileButtonStyle) only shows with focus on a tile.
shot "pause-saves-slot-focus" -ICubePausePreview -ICubePausePane saves -ICubePauseFocus slot-3
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
