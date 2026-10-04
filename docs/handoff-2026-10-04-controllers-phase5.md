# Controllers phase 5 (pointer, layout editor, boot assert, mapping overhaul): handoff

## Landed

PR [#18](https://github.com/Provenance-Emu/iCube/pull/18), squash-merged to `develop` as `3d421a66f7`
(62 commits, 91 files, +4535/−1420). Plan, root causes and file:line cites:
`docs/plan-2026-10-04-controllers-polish.md`. Everything in the plan's workstreams A, B, C, D1–D5
landed, plus PR-scoped lint. CI on the merged head: `build`, `iCubeTests`, swiftformat/swiftlint
and clang-format all green. None of it has been run on a device yet.

### A. Wii touch pointer (the TestFlight blocker)
- The core motion pointer (`IMUIR/Enabled`) is forced off on every Wii slot bound to
  `iOS/*/Touchscreen` after a profile load, a touchscreen bind and at boot
  (`TVControllerMappingBridge enforceTouchscreenPointerForWiimote:`); `TVEmulationBridge
  setWiiIMUPointEnabled:` refuses to enable it there; the overlay show/hide handler no longer
  toggles it.
- Blank or dead `IR/Up..Right` on a touchscreen slot are rebound to `Axis 112..115` with
  `IR/Auto-Hide = False`, nothing else touched.
- The profile list is filtered by the file that would load: bundled `Wii Remote with MotionPlus
  Pointing` / `SDL Gamepad` are never offered; on a touchscreen slot only profiles whose `Device =`
  is an on-screen device. Save Profile As… still checks the unfiltered list.
- `TCDeviceMotion.orientation` is behind a lock and refreshed on every rotation from
  `MainSceneCoordinator`'s scene.
- Tests: `WiiPointerProfileTests` (live bridge on Wii Remote 4, restores the slot; skips without an
  `iOS/7/Touchscreen`), `TCDeviceMotionMappingTests` additions.

### B. Layout editor
- "Edit Layout…" and "Edit IR Area…" edit on the game's own canvas: in a game, a
  `DOLEditTouchLayoutNotification` closes the hub/pause menu and overlays the live screen
  (`EmulationScreen.beginLayoutEdit`); outside a game, a full-screen cover from the hub. The old
  pushed editor (nav bar + picker inset) is gone.
- Edit mode hides the top bar and reveal strip; the Done/Reset capsule is top-centre; a faint
  safe-area outline is drawn; the drag preview is clamped live in a named coordinate space.
- `TouchOverlayCanvas` (in `TouchOverlayView.swift`) is the one place bounds/safe area/orientation
  come from. `TouchOverlayLayoutTests` asserts positions are stable between editor and gameplay.

### C. `BaseConfigLoader.cpp:40` assert
- `BootManager::BootCore` returns false before any side effect if the core is not `Uninitialized`,
  and calls `RestoreConfig()` when `Core::Init` fails.
- `EmulationCoordinator emulationLoopWithBootParameter:` waits (5 s) for `Uninitialized`
  (`DOLWaitForCoreUninitialized`) and shows "The previous game is still shutting down…" on timeout.
- **The core half is not live until the xcframework is refreshed** (see Open items).

### D. Mapping overhaul
- D4: ~900 lines deleted (unreachable ObjC controllers screens, `ControllerPresets` and its toast,
  `VirtualMFiControllerManager`, three dead overlay-style controls, real-Wii-Remote options with no
  backend, dead strings). `Data/Sys/Profiles/Wiimote/Touchscreen.ini` lost its dead `IR/Hide` and
  `IMUIR/Recenter` lines.
- D3: pointer mode is written by the player screen, the top bar and the DSU controller only, all
  through `PointerModeController`; Properties "IR Mode"/"Wii Controller" pickers are gone;
  Recommended Motion Settings no longer switches the pointer to Gyro; one Analog Stick screen
  ("On-Screen Stick Feel"); one programmatic-overlay toggle ("Editable On-Screen Controls");
  Properties is "Game Settings" and fully localized; Edit IR Area… sits next to Edit Layout….
- D2: `AssignmentEngine.firstWiimoteSlotOneBased(for:)` gives the first pad Wii Remote 1 unless the
  on-screen controls are using it (`ControllerStateStore.State.touchscreenHoldsWiimote1`); a pad is
  bound only where the title reads it; `Extension = Nunchuk` is out of the bundled profiles and
  `Common/Emulation/ProfileLoading.h` (`LoadProfileKeepingExtension`) keeps the slot's extension on
  load; `DSU.ini` ships for GCPad and Wiimote; tvOS first run no longer loads Touchscreen.ini.
- D1: a pad's mapping is stashed at `<User>/Config/MappingStash/<GCPad|Wiimote>/<qualifier>.ini`
  when its slot goes to the Touchscreen, another pad or No Device, and restored on reconnect
  (`ControllerAssignmentService`); disconnected pads keep their binding (the C++
  `reconcileAssignments` clearing pass is gone). Boot policy is `AssignmentEngine.decideBoot`,
  applied from `[[ControllerManager shared] prepareForBootWithIsWii:]`
  (`EnsurePad1DefaultsToTouchscreen` deleted). Extension/Sideways save `WiimoteNew.ini`;
  `overlayMode` (`controller_overlay_mode`) and the per-port profile name
  (`player_profile_name.<id>.<qualifier>`) persist in UserDefaults; `saveConfig` writes the input
  inis. Pointer/opacity write Base unless the game has saved Game Settings, then the Pointer row and
  top bar say "This game only". Pinned ports show a pin; "Auto" in the Device list unpins.
- D5: Advanced rows show the core's `GetUIDescription()`; `PlayerScreenHelp` captions per category
  and for Device/Profile/Extension/Sideways/Raw Bindings; `BindingDisplay.touchscreenName` maps
  `ButtonType.h` ids to names; the expression editor lists the device's inputs with live values and
  tap-to-insert; per-control Reset to Default (`DOLControllerSettingsBridge
  expressionInProfile:…`); user-profile delete; Clear All behind a confirmation.

### E. CI
- `lint.yml` on `pull_request` counts only findings on the PR's added/changed lines: swiftformat
  and swiftlint through a filter written into `$RUNNER_TEMP/lint_filter.py` (fails only on
  `error:` findings on changed lines), clang-format through `git clang-format --diff` restricted
  to `Source/iOS` (fails on the patch itself). Pushes to `develop` still lint the whole tree. The
  jobs are still `continue-on-error`.

## Open items (do these first)

1. **xcframework refresh** on a Mac: `python3 BuildiOSXCFramework.py --platforms OS64
   SIMULATORARM64 TVOS SIMULATOR_TVOS`, committed as `build: refresh the prebuilt core …`. Until
   then `BootCore`'s guard is not in the shipped core.
2. **Delete the remote branch** `claude/jolly-planck-43gyz5` (the session's git proxy refuses branch
   deletes); it is fully merged.
3. **Policy changes to confirm on device, revert if unwanted:** a Wii title no longer auto-binds a
   pad to a GC port (Wii games that read the GameCube ports need a manual assignment); Recommended
   Motion Settings no longer sets the pointer to Gyro (phase 4 checklist item 5 is stale).

## Device checklist (iPhone 17 Pro Max unless noted)

Pointer
1. Angry Birds Trilogy, Touchscreen profile, Pointer = Touch – Follow: the hand follows the finger;
   same in Touch – Drag.
2. Load Profile → Physical Controller, then back to Touchscreen: IR rows never show "—"; the
   pointer still works.
3. Hide the overlay (top bar), show it again, tip the phone upright and lay it flat: the hand stays.
4. Pointer = Gyro: rotate the phone to landscape and back; the pointer re-centres on rotation and
   reaches every edge.
5. Load Profile list on a touchscreen Wii slot shows Touchscreen (and touchscreen user profiles)
   only; Save Profile As… over a hidden name still asks.

Layout editor (landscape)
6. Pause menu → Controllers → Edit Layout…: the menus close and the live screen goes into edit
   mode; no top bar or reveal strip; Done at top-centre is tappable.
7. Drag a stick to every edge and corner, resize A/B at the bottom, Done: nothing moves when play
   resumes; portrait unchanged; Reset works.
8. From the top bar's Controller menu, Edit Layout… and the overlay long-press do the same.
9. With no game running, Settings → Controllers → Edit Layout… is full screen; the picker opens on
   the last game's pad.
10. Pause menu with its own Controllers sheet open → Edit Layout…: the whole stack closes in one
    go (watch for a stuck sheet); the game stays paused while editing and resumes on Done.

Boot
11. Exit a game and relaunch immediately, several times: no assert; at worst the "still shutting
    down" message. (Needs the xcframework refresh for the core-side guard.)

Mappings
12. Remap a GameCube pad, switch it off mid-game: Player 1 goes to the Touchscreen; switch it back
    on: the custom mapping returns.
13. Boot with the pad off; switch it on: its mapping returns.
14. Save a profile named "Touchscreen" from a pad slot, then pick Touchscreen: the device stays
    Touchscreen.
15. Extension, Sideways, Overlay Style and the profile name survive a relaunch.
16. Wii title with Player 1 turned off stays off; in a Wii title a lone pad is Wii Remote 1 when the
    on-screen controls are hidden and Wii Remote 2 when shown.
17. Pick Touchscreen for Player 1 with a pad connected: Player 1 shows the pin; the pad lands on
    Player 2 with its mapping; "Auto" unpins.
18. In a game with saved Game Settings, the Pointer row and top bar say "This game only" and the
    change ends with the game; without Game Settings it sticks.
19. Apple TV: a lone pad is Wii Remote 1; disconnect/reconnect still works; first run writes nothing
    for the Touchscreen.

Player screen
20. Advanced rows have subtitles; each Buttons section opens with a caption; Raw Bindings read
    "Pointer Up" / "On-screen A"; the expression editor lists inputs with live values; Reset to
    Default, Delete a Profile… (bundled ones disabled) and Clear All work and ask first.

## Known gaps and deferred work

- `TCWiiTouchIRMode.none` still means Gyro (rename to `.gyro`: `TouchOverlayIRPad.swift` switches
  on it, plus `TouchOverlayLayoutEditorView`). S.
- `TouchOverlayIRPad.sendIR` writes the same value to both halves of each IR pair (2× gain), which
  is why Follow feels oversensitive. S, behaviour change.
- Layout positions are 0–1 fractions of the canvas; points-based edge anchoring would survive a
  device change but needs a JSON format migration. M.
- Apply Recommended's remaining rework; `MotionDebugView` (DEBUG) still says "IR Mode"; DSU's "Map
  IR (Gyro) to DSU Touch" label. S.
- Unused after phase 5: `EmulationTopBar.onSetProgrammaticOverlay`, `DOLConfigBridge`'s speaker and
  continuous-scanning methods. S.
- The committed fallback `DolphiniOS.xcodeproj` (used by `release.yml`) still lists the deleted
  ObjC files and never listed the newer Swift ones. Regenerate or drop it. M.
- Player screen's in-session profile name is keyed by port only; after an automatic reassignment
  it can read stale until the next load. S.
- `WiiPointerProfileTests` and the D1 bridge tests need an `iOS/7/Touchscreen` device on the test
  host; they skip otherwise. Check CI actually runs them (look for `XCTSkip` in the test log).
- D5's "Reset to Default" reads the bundled profile; for a DSU device that is the new `DSU.ini`.
- No overlay-mode persistence test (`ControllerManager` is a singleton with side effects).
- Lint jobs: flip `continue-on-error` to false now that they are PR-scoped and green. S.
- Phase 4 handoff's checklist item 5 (Apply Recommended → Gyro) is stale.

## Conventions this phase settled

- New strings: identity entries in both `en.lproj/Core.strings` and `ja.lproj/Core.strings`,
  appended at the end (`check_localized_keys.py --check` needs `plutil`, so it only runs on a Mac).
- `git checkout -- build/xcframework` before committing an app-only change; a `Source/Core` change
  refreshes it instead.
- Conventional commits, no AI attribution trailers.
- ObjC/C++ under `Source/iOS` must pass `git clang-format --diff` on changed lines against
  `Source/.clang-format` (100 columns, braces on their own lines for C/C++ functions and control
  statements); an existing ObjC method's own K&R brace line is left alone. Swift must pass the repo
  `.swiftformat`/`.swiftlint.yml` rules on changed lines (2-space indent, blank line between
  declarations, no semicolons, sorted imports, no consecutive spaces).
- A cloud session has no Xcode: compile is CI's `iCubeTests` (simulator) and `build` (device
  archive); a `build` failure at `tuist generate` / `xcodebuild -resolvePackageDependencies` is the
  runner's package fetch, not the code — re-run once.
