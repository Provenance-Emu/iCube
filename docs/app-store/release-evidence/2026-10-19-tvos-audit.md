# tvOS UI and settings release audit — 2026-10-19

Status: in progress. Release workstreams: [R1 #52](https://github.com/Provenance-Emu/iCube/issues/52), [R2 #53](https://github.com/Provenance-Emu/iCube/issues/53).

Baseline source: `8bad720220`. Runtime target: Apple TV 4K (3rd generation, 1080p), tvOS 26.5 simulator `59214C60-C1D5-460F-91DC-BA425B4868C4`. Xcode 27.1 toolchain, tvOS 27 SDK. NJB Debug evidence does not establish APPSTORE visibility, physical-remote behavior or production sync.

## Environment

- Generated workspace initially referenced the removed local `Source/iOS/PVPatchEngine`; first baseline build could not resolve it. `tuist generate --no-open` regenerated it from current Project.swift successfully. No product source fix was needed.
- Fresh tvOS simulator app build uses `DOL_SKIP_CORE_BUILD=1` and the existing simulator xcframework slice. The older October 16 app is not being counted as current baseline evidence.
- Build/runtime logs and full-resolution captures are under `/tmp/icube-tvos-audit-2026-10-19/`; selected evidence should be copied into durable artifacts when findings are verified.

## Settings coverage

Every row below starts unverified. Preview launch checks cannot establish exiting Settings because the preview makes it the root screen; that case needs the real library → Settings route.

| Leaf | Reach/render | Focus and Back | Change and persistence | Notes |
|---|---|---|---|---|
| `console-gamecube` | pending | pending | pending |  |
| `console-wii` | pending | pending | pending |  |
| `achievements` | pending | pending | pending | build/service availability applies |
| `performance-tuning` | pending | pending | pending |  |
| `debug` | pending | pending | pending | build/service availability applies |
| `web-ui` | pending | pending | pending |  |
| `icloud` | pending | pending | pending | build/service availability applies |
| `nearby` | pending | pending | pending |  |
| `connected-apps` | pending | pending | pending | iOS only; excluded from tvOS |
| `general` | pending | pending | pending |  |
| `interface` | pending | pending | pending |  |
| `advanced` | pending | pending | pending |  |
| `graphics-video` | pending | pending | pending |  |
| `graphics-enhancements` | pending | pending | pending |  |
| `graphics-hacks` | pending | pending | pending |  |
| `graphics-advanced` | pending | pending | pending |  |
| `shaders` | pending | pending | pending |  |
| `audio` | pending | pending | pending |  |
| `controllers` | pending | pending | pending |  |
| `privacy` | pending | pending | pending |  |
| `about` | pending | pending | pending |  |

## Library and pause coverage

Pending: empty/demo library; rail All/GameCube/Wii; search; scroll/index; context actions; settings entry/exit; pause grid; quick menu; saves; cheats; shaders; reset/exit confirmations. Demo/preview screenshots are UI evidence only and cannot prove real game/save behavior.

## Findings

No product defect is marked reproduced or fixed yet. Static investigation: shader thread settings can produce `1...1` on a reported processor count ≤2; iOS ValueStepper passes that directly to Slider. This matches a lead in #50 but is not yet runtime-confirmed and is not a tvOS Slider path.
