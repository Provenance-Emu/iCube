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
# Library: platform filter raw values are LibraryPlatformCategory's: all, gameCube, wii.
for view in all gameCube wii; do
  xcrun simctl spawn "$UDID" defaults write "$BID" library_platform_filter -string "$view"
  shot "library-$view" -SCREENSHOT_MODE 1
done
xcrun simctl spawn "$UDID" defaults delete "$BID" library_platform_filter 2>/dev/null || true
shot "library-home" -SCREENSHOT_MODE 1
shot "library-empty"
for leaf in general interface advanced graphics-video graphics-enhancements graphics-hacks graphics-advanced \
            shaders audio console-gamecube console-wii controllers performance-tuning debug web-ui icloud nearby about; do
  shot "settings-$leaf" -ICubeSettingsPreview "$leaf"
done
shot "pause-grid" -ICubePausePreview
for pane in saves cheats controllers reset exit; do
  shot "pause-$pane" -ICubePausePreview -ICubePausePane "$pane"
done
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
