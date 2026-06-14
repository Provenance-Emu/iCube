# Building iCube (iOS / tvOS)

iCube is the Dolphin GameCube/Wii emulator app for iOS, iPadOS, and tvOS. The app target is generated with [Tuist](https://tuist.io); the Dolphin core ships as a prebuilt `PVlibDolphin.xcframework`.

## Prerequisites

- macOS with Xcode 15+ (Xcode 16+ recommended)
- [Homebrew](https://brew.sh)

Install build tools:

```sh
brew install cmake ninja tuist bartycrouch
```

Clone with submodules:

```sh
git submodule update --init --recursive
```

## Generate the Xcode project

The Tuist workspace (`iCube.xcworkspace`) is gitignored and must be generated locally:

```sh
cd Source/iOS/App
tuist generate
```

Open `Source/iOS/App/iCube.xcworkspace` in Xcode.

A committed fallback project also exists at `Source/iOS/App/DolphiniOS.xcodeproj` with the same schemes, but **Tuist is the source of truth** for project structure.

## Dolphin core (PVlibDolphin.xcframework)

The app links against `build/xcframework/PVlibDolphin.xcframework`. The checked-in xcframework includes **device slices only** (`ios-arm64`, `tvos-arm64`).

| Goal | What to do |
|------|------------|
| Build for a physical iPhone/iPad | Use the committed xcframework, or rebuild with `python3 BuildiOSXCFramework.py` from the repo root |
| Build for iOS Simulator | Rebuild the xcframework with simulator slices first (see below) |
| Rebuild the core after C++ changes | Run `python3 BuildiOSXCFramework.py` from the repo root; Xcode also triggers a core rebuild via the **Build Dolphin Core** script phase |

Rebuild all platforms (device + simulator, iOS + tvOS):

```sh
python3 BuildiOSXCFramework.py -a
```

Rebuild device slices only (default, faster):

```sh
python3 BuildiOSXCFramework.py
```

The first full core build compiles a large CMake/Ninja tree and can take 30–60+ minutes depending on hardware. Subsequent builds are incremental.

## Build from the command line

From the repo root, after `tuist generate`:

**iOS device (no code signing):**

```sh
xcodebuild \
  -workspace Source/iOS/App/iCube.xcworkspace \
  -scheme "iCube (NJB)" \
  -configuration "Release (Non-Jailbroken)" \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

**iOS Simulator** (requires simulator slices in the xcframework):

```sh
xcodebuild \
  -workspace Source/iOS/App/iCube.xcworkspace \
  -scheme "iCube (NJB)" \
  -configuration "Debug (Non-Jailbroken)" \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Schemes

| Scheme | Use |
|--------|-----|
| `iCube (NJB)` | Non-jailbroken sideload / development |
| `iCube (JB)` | Jailbroken / TrollStore builds |
| `iCube (AppStore)` | App Store configuration |

## Code signing

For local device installs, set your team ID in `Source/iOS/App/Project/Config/DevelopmentTeam.xcconfig` and bundle identifier in `BundleIdentifier.xcconfig`. Command-line builds above disable signing with `CODE_SIGNING_ALLOWED=NO` for CI and smoke tests.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `no such module` / missing workspace | Run `tuist generate` in `Source/iOS/App` |
| `building for iOS Simulator, but linking in … built for iOS` | Rebuild xcframework with `-a` to include simulator slices |
| Missing Externals/watcher sources | Run `git submodule update --init --recursive` |
| Long first build | Expected — the Dolphin core CMake build runs on first link |
