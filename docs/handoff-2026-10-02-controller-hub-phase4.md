# Controller Hub Phase 4 (removal): handoff

## Landed

Branch `feature/controller-hub-phase4`, on top of `develop`:

- 1c596056b1 docs: controller hub phase 4 (removal) plan
- 468d5dd568 refactor(controllers): one Overlay Style row; art follows the pad
- b1c271c8df refactor(controllers): set the pointer mode in one place
- eba5d37a82 refactor(controllers): delete ControllerSetupView and RemapPlayerView
- 7f17d90c4a refactor(motion): Motion Debug only in DEBUG builds
- 0d13405382 fix(controllers): the hub names a DSU-bound port; drop stale references
- docs: controller hub phase 4 handoff; drop dead strings (this commit: 25 dead keys removed from en and ja `Core.strings`, plus this file)

## Device checklist (iPhone, then Apple TV where noted)
1. Pause menu → Controllers, in a game: the On-Screen Controls section shows "Overlay Style" (Auto / GameCube / Wii). Picking GameCube in a Wii game shows the GameCube pad with GameCube art; Wii shows the Wii pad with Wii art.
2. Settings → Controllers → More Controller Settings: no colour "Overlay Style" picker, no "Touch IR Pointer" row, no "Pointer Sensitivity" slider. Edit IR Area, Reset All Overlay Layouts, Advanced Motion Settings and Analog Stick Settings are still there.
3. A player who had the old colour override set to Wii sees GameCube art on the GameCube pad.
4. Advanced Motion Settings: only Horizontal Movement, Full Motion Mapping (6DOF, Wiimote, Nunchuck) and Quick Setup. Horizontal Movement changes take effect in a running game. Test it with the pointer in Gyro mode, which is the only mode it affects.
5. Recommended Motion Settings (renamed in phase 5): Invert X/Y off and Shake to Wiggle on; the player screen's Pointer row keeps whatever mode it had. (Phase 5 stopped this button switching the pointer to Gyro.)
6. The pointer mode has no settings-screen picker left. It changes from the player screen's Pointer row, the top bar's pointer menu, and the DSU controller screen's Gyro/Follow/Drag menu (`DSUControllerView`). (Phase 5 removed Apply Recommended's write and the tvOS per-game "IR Mode" picker.) After a change from any of them, the player screen's Pointer row and the top bar show the same mode.
7. A Wii Remote bound to a DSU device: the hub's player row names the device, never "(Disconnected)". An MFi pad that is switched off still says "(Disconnected)".
8. Release/TestFlight build: Settings → Debug has no Motion Debug row. Apple TV pause screen: no gyroscope button; the speedometer button still opens the performance overlay.
9. Player screens still open from the hub on iOS and tvOS; capture, Load/Save Profile and Advanced still work (Phase 3 checklist items 1-10 spot check).

## Known gaps carried over
- No pad Back on screens pushed from inside More or DSU (Add DSU Server, Analog Stick Settings,
  Advanced Motion Settings, Edit IR Area); use touch there. Phase 3 checklist item 17
  confirms that B does nothing on them rather than popping two levels. (The Phase 3 list also named
  Touch IR Pointer; Phase 4 removed that screen.)
- A pad disconnect hands GameCube port 1 back to the Touchscreen, which loads the Touchscreen
  profile over a custom pad mapping. With `5bbeee6c33` the pad comes back working, but on its
  default profile. Keeping the custom mapping needs a per-port stash, which is not designed.
- Saving a profile named "Touchscreen" and then loading it on a GameCube port (Device → Touchscreen,
  or any path through `assignTouchscreenToGCPort`) can flip the port back to the pad the profile was
  saved from: the saved `Device =` line loads and `assignTouchscreenToGCPort` does not re-set the
  device afterwards (`TVControllerMappingBridge.mm` ~:228-246, which this phase does not edit).
  Phase 3 checklist item 9's built-in test is where it shows up.
- One alert serves every prompt. If a follow-up prompt ever fails to appear after the previous one
  closes (Phase 3 checklist items 9 and 24), the cause is SwiftUI re-presenting the same `.alert` too soon:
  - The plan keeps the one-main-actor-hop gap. The simulator smoke test saw the Replace follow-up
    re-present correctly on iOS.
  - The next step would be a longer gap, or presenting the follow-up from the alert's dismissal.
- Carried over from Phase 3 (its SDD ledger is local-only and not in git):
  `.superpowers/sdd/2026-09-30-controller-hub-phase3-player-screen/progress.md`, on the lines that
  start "minor (deferred)". Two deserve a reader's attention:
  - The capture timer and the notification observers are torn down only through `stop()` and
    `endCapture()`. A view model released while a capture is armed leaves a timer firing that does
    nothing.
  - `ProfileNaming.suggestion` can return an empty or a built-in name at its source. The view model
    guards it.
- `TVSoftwarePropertiesView` (tvOS per-game properties) has two mislabelled pickers:
  - The global "IR Mode" picker (~line 100) writes through `PointerModeController`.
  - The "Per-Game IR Mode" picker (~lines 132-142) writes `current_profile_ir_override` directly, not through `PointerModeController`.
  - Both label raw 0 "None" and 1 "Absolute"; raw 0 is Gyro and 1 is Follow (`PointerMode`). Both also use non-localized strings.
