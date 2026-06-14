# Agent workflow guide

This repository is a Dolphin emulator fork with an iOS/tvOS app (**iCube**). Most agent work happens in `Source/iOS/App/` (Swift/ObjC UI) or `Source/Core/` (C++ emulator).

## Quick orientation

| Area | Path |
|------|------|
| iOS/tvOS app (Tuist) | `Source/iOS/App/` |
| App UI (Swift) | `Source/iOS/App/Common/Swift/` |
| Emulation bridge | `Source/iOS/App/Common/Emulation/` |
| Dolphin core (C++) | `Source/Core/` |
| iOS core xcframework build | `BuildiOSXCFramework.py` → `build/xcframework/` |
| iOS build docs | [`Source/iOS/BUILDING.md`](Source/iOS/BUILDING.md) |

## Bootstrap (cold start)

```sh
git submodule update --init --recursive
brew install cmake ninja tuist bartycrouch
cd Source/iOS/App && tuist generate
```

Open `Source/iOS/App/iCube.xcworkspace`. Do **not** rely on the root `Readme.md` iOS section alone — use `Source/iOS/BUILDING.md`.

For **iOS Simulator** builds, rebuild the xcframework with simulator slices first:

```sh
python3 BuildiOSXCFramework.py -a
```

## Validate a small change

Prefer targeted checks over full core rebuilds:

1. **Swift/ObjC UI only** — build the app scheme without touching C++:
   ```sh
   xcodebuild -workspace Source/iOS/App/iCube.xcworkspace \
     -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" \
     -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
   ```
2. **C++ core change** — expect a long rebuild via `BuildiOSXCFramework.py` or the Xcode **Build Dolphin Core** phase.
3. **Unit tests** — `iCubeTests` target via scheme `iCube (NJB)` test action.

## Conventions

- iOS and tvOS share most Swift sources; gate platform-specific APIs with `#if os(iOS)` / `#if os(tvOS)`.
- Tuist project definition: `Source/iOS/App/Project.swift`. Regenerate with `tuist generate` after structural changes.
- ObjC notification name constants use `FOUNDATION_EXPORT` in headers and a single definition in one `.m`/`.mm` file — do not define string constants inline in headers.
- Swift bridging header: `Source/iOS/App/Common/Swift/BridgingHeader.h`.

## What not to do

- Do not commit `Source/iOS/App/iCube.xcodeproj` or `iCube.xcworkspace` (gitignored; Tuist-generated).
- Do not assume simulator builds work out of the box — the committed xcframework may be device-only.
- Do not run a full Dolphin desktop build to validate an iOS UI tweak.

## CI reference

GitHub Actions workflow: `.github/workflows/build.yml` — builds `iCube (NJB)` / `iCube (JB)` schemes from `DolphiniOS.xcodeproj` (committed fallback project).
