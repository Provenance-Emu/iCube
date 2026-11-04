# Settings inventory and sync-scope audit (2026-11-03)

Scope: iCube#53 (R2, settings audit for the 1.0 release), first and fourth checklist bullets.
- Inventory every settings leaf and search/deep-link entry.
- Decide the scope of each setting and audit what reaches sync.

Base commit: `49b114f18c` (origin/develop at the time). Code reading only: nothing was built or run, no device or simulator was used. "Proven" below means proven from source text; "needs device" means the source leaves the outcome open.

## Sources

- `Source/iOS/App/Common/UI/Settings/SwiftUI/` (root, sidebar, search index, deep link) and `.../Leaves/` (builders, states, views).
- `Source/iOS/App/Common/Bridging/DOLConfigBridge.{h,mm}`, `DOLSettingsKeyBridge.mm`.
- `Source/Core/Core/Config/*.cpp` for the Dolphin Config key table (section, key, compiled default).
- `Source/iOS/App/Common/Services/{CloudSyncCoordinator,DolphinCoreService}`, `Swift/{GameProfiles,LibraryStateStore}.swift`.
- External packages, read from a local DerivedData checkout: PVSyncRules 1.0.2 (`692ca3a`) and PVCloudSync 1.1.0. `Project.swift` asks for `upToNextMajor(from: 1.0.2)` and `from: 1.1.0`; the checkout is this Mac's resolution, not proof of what CI resolved.
- `Source/iOS/App/Project/Assets/DefaultPreferences.plist`.
- Prior audit: `docs/audits/2026-10-16-tvos-settings-audit.md`.

## Column legend

- **Kind**: toggle, cycle (tap steps through choices), picker (menu / tvOS option rows), stepper, action, destructive, destination (pushes a sub-screen), custom, caption.
- **Persistence**: `Cfg KEY [System:Section.Key]` is a Dolphin Config key, written through `DOLConfigBridge`. `UD key` is `UserDefaults.standard`. The effective default is the compiled default unless a launch seed (`DolphinCoreService.seedLaunchDefaults...`) overrides it on first run.
- **Layer**: `B` = `SetBase`, `BoC` = `SetBaseOrCurrent` (see "Write layers").
- **Live / restart**: whether a running game picks the value up.
- **Reset**: whether "Reset All Settings" (About, and the toolbar on iOS/iPad) restores it.
- **Scope**: device-local, synced preference (rides `Config/*.ini` through iCloud sync), per-game (`GameSettings/*.ini` or `game_profiles.json`).

## Not determined from code

(filled in at the end)
