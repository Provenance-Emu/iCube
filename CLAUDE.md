# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Critical Constraints

- **Never build for iOS/tvOS** — builds are done manually via Xcode. Do not invoke `xcodebuild`, `BuildCore.sh`, or `BuildiOSXCFramework.py` unless explicitly asked.
- **Never run git commands** unless explicitly requested by the user.

## Project Overview

This is **DolphiniOS** — a port of the Dolphin GameCube/Wii emulator to iOS and tvOS. It is used as a submodule inside the Provenance emulator project. The core emulator is C++23; the iOS/tvOS app uses Objective-C++ bridge layers and SwiftUI.

## Build System

### Core Library (CMake)
The Dolphin emulator core is built via CMake using the iOS toolchain:
- Toolchain: `Externals/ios-cmake/ios.toolchain.cmake`
- Build script: `Source/iOS/App/Project/Scripts/BuildCore.sh` (invoked as an Xcode build phase)
- Output: per-platform directories `build-$PLATFORM_NAME-$CONFIG/` at repo root

### XCFramework (for Provenance integration)
`BuildiOSXCFramework.py` — builds `PVlibDolphin.xcframework` for:
- iOS device (arm64), iOS simulator (arm64)
- tvOS device (arm64), tvOS simulator (arm64)
- Mac Catalyst (arm64)

Deployment targets: iOS 15.6, tvOS 15.6.

### Xcode Project
- Location: `Source/iOS/App/DolphiniOS.xcodeproj`
- Schemes: `DiOS (NJB)`, `DiOS (JB)`, TrollStore variants
- Configs: `Release (Non-Jailbroken)`, `Release (Jailbroken)`, `Release (TrollStore)`, Debug variants
- xcconfig files live in `Source/iOS/App/Project/Config/`

### Unit Tests (Desktop/CI only)
Tests use Google Test (in `Externals/`) and are under `Source/UnitTests/`. Enable with `-DENABLE_TESTS=ON` in CMake. These are desktop tests — no iOS test target exists.

## Architecture

### Dolphin Core Subsystems (`Source/Core/`)
| Subsystem | Purpose |
|-----------|---------|
| `Core/Core/` | PowerPC CPU emulation, JIT, MMU, timing |
| `Core/Common/` | Utilities — threading, file I/O, logging, IniFile |
| `Core/AudioCommon/` | Audio backend abstraction |
| `Core/VideoCommon/` | GPU abstraction layer (platform-neutral) |
| `Core/VideoBackends/Metal/` | Metal GPU backend (primary on iOS/tvOS) |
| `Core/VideoBackends/Vulkan/` | Vulkan/MoltenVK backend |
| `Core/InputCommon/` | Controller input system |
| `Core/DiscIO/` | Game disc/ROM parsing |

### iOS/tvOS App Layer (`Source/iOS/App/Common/`)
| Directory | Purpose |
|-----------|---------|
| `Emulation/` | Core-to-iOS bridge: `EmulationCoordinator.mm` (boot, render surface setup, controller routing), `TVEmulationBridge.mm`, `TVControllerMappingBridge.mm` |
| `Jit/` | JIT memory management for iOS |
| `Fastmem/` | Fast memory access optimization |
| `Audio/` | `AVAudioEngineSoundStream.mm` — AVAudioEngine-based audio |
| `Services/` | `FirebaseService.mm`, version management |
| `Swift/` | SwiftUI views (save states browser, cheats menu, shader post-processor) |
| `UI/` | UIKit components, localization strings |
| `Bridging/` | ObjC++ bridge headers exposing C++ types to Swift/ObjC |

### Key Bridge Pattern
`EmulationCoordinator.mm` is the central Objective-C++ class that:
1. Accepts a `EmulationBootParameter` (game path + config)
2. Sets up a `CAMetalLayer`-backed `UIView` (`RenderHostView`) as the render surface
3. Calls Dolphin's `BootManager::BootCore()` with a `WindowSystemInfo` pointing at the Metal layer
4. Routes `GCController` / touch input through `InputCommon` to the emulated GameCube/Wii controllers

### Video Backends
- **Metal** — primary, always available on modern Apple hardware
- **Vulkan (MoltenVK)** — enabled via `ENABLE_VULKAN=ON`; active Vulkan 1.4/MoltenVK work tracked in `Source/iOS/App/TODO.md`
- **Software** / **Null** — testing/fallback

### Audio
- `AVAudioEngineSoundStream` (iOS/tvOS native) is the primary backend
- `AudioSessionManager` handles AVAudioSession lifecycle (interruptions, routes)

## Active Development Areas (see `Source/iOS/App/TODO.md`)
- Vulkan/MoltenVK 1.4 feature integration (dynamic rendering, present-wait, float controls)
- tvOS controller button-mapping storyboard crash fix
- Save state boot + new UI validation
- WebDAV improvements

## Linting
- `Tools/lint.sh` — C++ linting
- No SwiftLint config in this repo (parent Provenance project handles Swift linting)
- C++ standard: C++23 (enforced in `CMakeLists.txt`)
