# tvOS settings audit (2026-10-16)

The trigger was a TestFlight report from an older tvOS build: some CPU settings could not be changed correctly, and games felt slower. Both problems still exist on develop `003b7d9fb7`. Both are fixed on `fix/tvos-settings-audit`.

## What was wrong

**1. Left on an adjustable row moved the value and left the row.**
- Affected rows: steppers, `.cycle` rows and compact pickers in the tvOS settings pane.
- Each has an `.onMoveCommand` handler, but the focus engine still moves focus to the sidebar on the left. One Left press therefore did two things:
  - it stepped the value down, and
  - it moved focus to the sidebar entry beside the row (not the page being shown).
- Reproduced in the simulator on develop:
  - On CPU Emulation Engine, one Left changed Cached Interpreter to **Interpreter (slowest)**. `Dolphin.ini` then held `CPUCore = 0`, and focus sat on the sidebar.
  - On Emulated CPU Clock, one Left changed 100 % to 99 %, and focus jumped to "Nearby Devices".
- Right works only because nothing is to the right. So a remote could lower a value by at most one step per visit, without seeing it happen. That explains both halves of the report: the setting "won't change", and the engine silently became the plain Interpreter.

**2. Engine changes made in game were lost.**
- A jitless boot sets `MAIN_CPU_CORE` to the Cached Interpreter on CurrentRun (`EmulationCoordinator.mm`, "Enforce CPU-core fallback").
- `setMainCpuCore` used `SetBaseOrCurrent`. While a game was loaded, the choice went to CurrentRun and read back as applied. `BootManager::RestoreConfig` then cleared it when the game ended.
- On tvOS this is the normal path: the pause menu's Performance tile opens this leaf.
- `DebugAPIRoutes.swift` already documented the same trap for the debug API's settings restore.

## Behaviour change for the owner to confirm

Left on a stepper, cycle row or compact picker no longer reaches the sidebar. You leave those rows with Menu, or with Up/Down to another row. Left on every other row still goes to the sidebar.

## Fixes

- **Focus.**
  - `MenuScreen` (tvOS list) reports through `settingsPaneHoldsLeft` whether the focused row adjusts with left/right (`MenuItem.adjustsWithLeftRight`).
  - While it does, `SettingsSidebarShell` disables the sidebar, so Left steps the value and keeps focus.
  - Menu still returns to the sidebar; `backToSidebar` re-enables it before moving focus.
  - Left from any other row still goes to the sidebar. It now lands on the selected page (`defaultFocus(..., priority: .userInitiated)`).
  - iOS and the pause tiles are unchanged.
- **Engine.**
  - `setMainCpuCore` writes Base, also while a game is loaded. Outside a game it also deletes a CurrentRun copy.
  - Performance Tuning and the A/B snapshot read the new `mainCpuCoreBase`.
  - The pause badge and `EmulationScreen` still read the running engine.
- **Tests (iOS `iCubeTests`).**
  - `MenuModelTests.test_adjustsWithLeftRight_onlyStepperCycleAndCompactPicker`.
  - `SettingsWriteBackTests.testTheEngineChoiceReachesBasePastAJitlessBootCopy` round-trips through live Config: a CurrentRun engine copy, then a write, then Base.

## Rows checked

Simulator: Apple TV 4K (3rd gen, 1080p), tvOS 26.5, Debug (NJB). Remote presses came from an XCUITest driver; screenshots are in the session notes folder.

| Row / behaviour | develop | fix |
|---|---|---|
| Performance › CPU Emulation Engine: Right steps, focus stays | pass | pass |
| Performance › CPU Emulation Engine: Left steps, focus stays | **fail** (steps and leaves to sidebar) | pass |
| Performance › CPU Emulation Engine: A cycles (CIR → CIR-IR), row re-renders at once | not driven | pass |
| Performance › Emulated CPU Clock stepper: Left/Right | **fail** (Left leaves after one step) | pass (99→100→99→98, focus held) |
| Performance › Enable CPU Clock Override toggle: A flips, row re-renders, stepper enables | pass | pass |
| Toggle row: Left goes to sidebar | lands on the entry level with the row | lands on the selected page |
| Menu from an adjustable row returns to sidebar | n/a | pass |
| Engine value persists to `Dolphin.ini` and survives relaunch | pass outside a game, **fail** in game (the new unit test fails against the old setter) | pass (`CPUCore = 5` after relaunch) |
| Clock override persists (`OverclockEnable`, `Overclock`) | pass | pass |
| Focus chrome (scale, ring, fill) on cycle and stepper rows, and on the sidebar entry | pass | pass |
| Sidebar: Down/Up move between entries (no snap back), Select switches page, Right/Left between pane and sidebar | n/a | pass |
| Menu at the sidebar leaves Settings | not checked | inconclusive: the `-ICubeSettingsPreview` launch makes Settings the root view, so there is nothing to dismiss. `leaveSettings` is unchanged |
| Graphics › Video: Left from a toggle → selected "Video" entry, Right → same row | n/a | pass |

**Covered by the same code path, but not driven one by one.** Every engine-backed leaf renders through `MenuScreen.tvRow`, so the Left fix covers all of them:
- 20 steppers: audio volume, EQ, echo, crush and buffer; Wii speaker, Wii Speak and sensor bar; MEM1/MEM2; compiler threads; mipmap threshold; analog stick deadzone, gain and smoothing.
- About 30 cycle rows: Graphics Backend, Shader Compilation Type, Internal Resolution, MSAA, Speed Limit, and others.
- The two compact pickers on the player screen.

## Defaults (the "slower" report)

Nothing in the tvOS UI writes a default. `sync()` only reads, and `apply` writes only on a user action. The compiled defaults match the row captions:
- `CachedInterpreterPrefetch` off
- `RelaxedIdleDetection` and `FastForwardCtrIdle` on
- `CIRPsNeon`, `CIRDynLinking`, `CIRBlockLinking`, `CIRMicroOpFusion`, `CIRPICLoadStore` and `CIRSpecializedOps` on
- Hybrid Ubershaders (`GFX_SHADER_COMPILATION_MODE`)
- vertex loader unset = NEON, both in the UI and in `ICubeJitlessVertexLoaderType`

The engine's Base default is the ARM64 JIT (`DefaultCPUCore`), and every jitless boot runs it as core 5. "Reset Optimizations to Recommended" deletes the CIR keys back to those defaults.

The slowdown a tester can cause is bug 1: a stray Left on the engine row selects the plain Interpreter, and on the clock stepper it enables a sub-100 % clock.

## Not run

- `make gate-release`, the Release builds for iOS and tvOS. TestFlight builds Release. The changes contain no `#if DEBUG` code. Run it with `DOL_SKIP_CORE_BUILD=1`, then check `git status build/xcframework`.
- The pushed sub-leaf path. The two compact pickers on the controller hub's player screen sit on a pushed screen. When that screen pops, `onDisappear` must release the hold. See device check 4.

## Needs a device

1. On an Apple TV with a game running: pause → Performance → change the engine, quit, and boot again. The new engine must be the one that runs (perf HUD / pause badge).
2. Siri Remote touch surface: swipe left/right on the engine row and on a stepper. The value should step and focus should stay. Also check that clicking the touchpad edge does not skip.
3. Menu from a stepper and from a cycle row should land on the selected sidebar page.
4. Controller hub › player screen: on the two compact pickers, Left/Right should step and stay. Then press Menu to pop the screen, and Left must reach the sidebar again (the hold is released). Not driven in the simulator.
5. Check the tester's own device. If `CPUCore = 0` is already in their `Dolphin.ini`, they need to set Cached Interpreter again; nothing resets it.

## Not changed (follow-ups)

- **Other writes made in game.** These settings still use `SetBaseOrCurrent`, and the app also sets them on CurrentRun:
  - Speed Limit (`MAIN_EMULATION_SPEED`), set by fast-forward.
  - Volume (`MAIN_AUDIO_VOLUME`), set by the pause volume tile.
  - The widescreen hack (`GFX_WIDESCREEN_HACK`), set by `setCurrentRunGfxWidescreenHack`.

  `MAIN_AUDIO_MUTED`, set by the pause mute tile and fast-forward, may belong here too. A change made in game after one of those writes is lost at game end. One owner decision covers them all: which in-game writes are meant to be per-game.
- **Stale comment.** The comment above `IsGameOverride` in `DOLConfigBridge.mm` says CurrentRun is only cleared at the next boot. `BootManager::RestoreConfig` clears it at emulation end.
- **Entering the pane.** Right from the sidebar enters the pane at the row level with the sidebar entry (Graphics › Video lands on "Show Auto IR OSD"), not at the first row. Unchanged.
- **Stale linter.** `check_settings_wiring.py` reports every CIR key as a reset gap, because `resetGameplayConfigKeys` deletes them through a helper the parser does not read. This predates the branch.
