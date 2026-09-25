# Controller follow-ups (2026-09-24, from the user's reports after P1)

Companion to `docs/audits/2026-09-24-controller-system-audit.md` and
`docs/handoff-2026-09-24-controllers.md`. Ordered by what unblocks play first. Each item names the
code, the evidence so far, and who should do it (main session vs. a cheaper subagent / new session).

## A. Already fixed in this pass (compile-gated, not device-exercised)

- **Pause menu "Controllers" was GameCube-only for every game.** `PauseMenuView` chose the setup
  system from `ControllerManager.isWiiSystem`, which nothing ever set (`setSystem(isWii:)` had no
  callers). Now reads the running core (`TVEmulationBridge.isCurrentSystemWii()`), Wii titles get
  Wii Remotes first then the GameCube ports (`ControllerSetupSystem.wiiAndGameCube`), and
  `EmulationScreen` keeps `ControllerManager.isWiiSystem` in sync.
- **"Selecting Touchscreen for Player 1 sets all four."** Display bug: every slot's stock default
  device is `iOS/0/Touchscreen` with the port/source off, and `ControllerSetupView.reloadQualifiers`
  showed the device string regardless of activity. Inactive slots now show None. Picking a device
  refreshes extension/sideways too (`reloadAll`).
- **Profile pick "glitchy / double tap".** The sheet stayed up while `loadProfile` + `SaveConfig`
  ran synchronously; it is dismissed first and the load runs on the next main-queue turn.
- **"Never see the cursor with drag / follow / gyro."** Not reproduced. The DEV container on the
  phone has a healthy Wii Remote 1 (`iOS/4/Touchscreen`, touch mapping, IR axes 112-115,
  Source 1, IMUIR off). Most likely the report is from the release build (TestFlight 13), which
  predates the P0 fix `c0029c9284`; the release per-port path also loaded the Bluetooth
  "MotionPlus Pointing" profile (dead controls) — fixed in `6361096f03`. Needs the user on the
  DEV build, or a USB session (`/api/debug/screenshot`; the DEBUG bench is loopback-only so it is
  unreachable over Wi-Fi).

## Landed by subagents on 2026-09-24 (late; compile-gated iOS + tvOS, NOT device-exercised)

| Item | Commit | Note |
|---|---|---|
| B1 unpause while in menu | `eb758371c1` | resume gated on `isPauseMenuChildPresented` (sheets + tvOS panes made the ZStack "disappear") |
| D14 FF speed picker | `3d730e036b` | `setFastForwardSpeedPercent:`; also fixed Unlimited (0) never engaging because `integerForKey` cannot see "unset" |
| D15 cheats badge | `0c38e19ab9` | `CheatsMenuView.activeCheatCount` |
| B2 L1/R1 step the library system filter | `8b328498eb` | inside the existing `valueChangedHandler`, iOS only |
| D17 sheets own the controller | `a4baa043e2` | `.claimsController()` on every library sheet; `SourcePickerView` has its own d-pad/A/B |
| D11 boot-save picker | `245a18fcd3` | cards were never tappable (only a long-press menu); grid + aspect-fit thumbnails |
| B4 IMU pointer per slot | `653259adc9` | `setWiiIMUPointEnabled:forWiimote:` |
| B5 DS4 touchpad mirror | `1141083a7d` | removed |
| Defect #4 gyro-mode IR | `6adae68fca` | single-sided, sign-corrected; sensitivity may now feel halved (was doubled) |
| B3 DualSense mapping | `90ecbf62c4` | already shipped earlier; doc table only |
| Wii "-" vs pause | `f2dbcbc494` | `Buttons/- = R Stick` in the physical Wiimote profile; Options stays the pause button |
| D12 boot fresh resumes auto-save | `44c4114b49` | one app-lifetime DidStart observer (`SaveStateService.installDidStartObserver`, from AppDelegate) instead of one per EmulationScreen instance; two live instances during a navigation transition let the second consume the cleared `skipResumeOnce`. Correction to item 12 below: iCube never arms Dolphin's own savestate boot (`EmulationBootParameter.mm:23`), so there is no coordinator `.auto` load to suppress. `PendingGameLaunchStoreTests.swift` is not wired into any target (pre-existing) |
| Docs | `e49115b8a4`, `f036c78f9e`, `7e66c0e48e` | package survey, menu-engine + remap designs, overlay design (iFly `Views/Controller/`, not the Delta-skin runtime) |
| Defect #17 ButtonType drift guard | (this pass) | `Source/iOS/App/Project/Scripts/check_button_types.py` checks `ButtonType.h` (source of truth) against `TCButtonType.swift` (mirror) for numeric drift; run once, found zero mismatches, only the pre-existing dead `wiiInfraredRecenter = 800` case (audit item #18, out of scope) with no C++ backing. Not wired into the build yet. |

Phone checklist for this batch: open Controllers/Settings/Shaders from the pause menu and confirm
the game stays paused; pick a FF speed and confirm immediate resume at that speed; cheats count on
the item; L1/R1 in the library steps the system filter; source picker no longer moves the library
behind it; boot-save cards launch on tap; on a Wii title with a DualSense, Share pauses only and
R3 sends "-"; gyro-mode pointer direction and reach; Motion Debug shows live values.

## B. Bugs to fix next (main session, small)

1. **Game unpauses while the pause menu is still up.** Lead: `PauseMenuView` `.onDisappear`
   resumes emulation unconditionally (`PauseMenuView.swift:171-173`). Any presentation that
   makes the menu's body disappear (full-screen covers, the Controllers / Settings sheets on some
   paths, tvOS focus panes) resumes the game underneath. Fix: resume only on an explicit
   Continue / dismiss, or track "menu chain still presented" and resume in the chain's last
   `onDisappear`. Verify: open Controllers from the pause menu, watch the frame counter.
2. **Library system filter is unreachable from a controller on iOS.** The filter is a
   touch-only control in `TVLibraryView`; map the paddles / shoulders (L1/R1 or L2/R2) to step the
   active system filter, with the current name announced in the HUD. Find the filter state in
   `TVLibraryView.swift` (search for the system picker; no `systemFilter` symbol exists yet).
3. **DualSense: Share and Options both open the pause menu; GameCube Start unreachable.** Route:
   `PauseGestureTracker` treats `buttonOptions` as the dedicated pause button and `buttonMenu`
   (OPTIONS on DualSense) as Start/+ via the profile; the physical-controller profile
   (`Data/Sys/Profiles/GCPad/Physical Controller.ini`) and the MFi backend's element naming decide
   which GameController element each glyph lands on. Check what `MFiController` publishes for
   DualSense `buttonOptions` / `buttonMenu` / `buttonShare` and make: Options (≡) = Start,
   Share/Create = pause menu, PS = pause menu (already). Add a per-controller override in the
   setup view. Sonnet subagent can trace the element names; main session lands the mapping.
4. **`TVEmulationBridge.setWiiIMUPointEnabled` only touches Wii Remote 1** (`Wiimote::GetWiimoteGroup(0, IMUPoint)`).
   With port-aware overlays it must target `ControllerManager.touchscreenSlot(system: .wii)`.
5. **DS4/DS5 touchpad mirror onto Wii Remote 1** (`ControllerExtensions.swift`
   `installTouchpadIRHandlers`): player 2's touchpad moves player 1's pointer. Remove the mirror.
6. Audit P2 (unchanged): single-sided IR writes in gyro mode, stuck-button handling, leaked
   observers, overlay visibility on disconnect, `StateManager` locking, `ButtonType` constants,
   MFi `GetPreferredId`.

## C. Rewrites (separate sessions; spec first)

7. **Button remapping UI rewrite** (`ButtonMappingView.swift`, `ControllersMappingView`,
   `ControllerMappingView.swift` which is now unreferenced, `ControllerPickerSheet.swift`).
   Requirements from the user: fast, no accidental double activation, one screen per player that
   shows the bound device, its profile, and a live "press a button" capture per control; Wii
   extension + sideways in the same screen; works with a controller (tvOS focus rules in
   `icube-tvos-swiftui-focus`) and touch. Do a short design doc first (brainstorming skill), then
   an opus/sonnet session with the phone for the capture flow. Delete the dead
   `ControllerMappingView` / `ControllerPickerSheet` GC-only widgets as part of it.
   **Landed 2026-09-25** (compile-gated iOS + tvOS, unit tests green, NOT device-exercised):
   `f66a12295c` dead widgets deleted, `6c3659f8dd` `saveProfile:forGCPort:/forWiimote:`,
   `c77b608f81` pure model + `RemapModelTests`, `03c28b067a` `RemapPlayerView` wired to
   "Customize Buttons…" (`ControllersMappingView.swift` removed). Spec corrections — the real
   `PadGroup`/`WiimoteGroup` ids, the release-to-arm gate, why B/Menu cannot cancel — are in
   `docs/superpowers/plans/2026-09-25-remap-ui-implementation.md`. The legacy stack —
   `ButtonMappingView.swift` (tvOS `TVMappingRootViewController` + iOS storyboard wrapper),
   `ButtonMapping.storyboard` and the whole ObjC `Common/UI/Settings/Mapping/` tree it
   instantiated — is deleted (closes audit item #13). Phone checklist is at the end of that plan file.
8. **Programmatic on-screen controller replacing the xib pads.** Port iFly's skin/overlay stack
   (`iFly/iFly/Sources/UI/Views/Skins/`, `DeltaSkinView.swift` `SkinLayout`,
   `EmulationView+Layout.swift`, `EmulationView+Overlays.swift`): draggable buttons, resizable
   groups (d-pad, face buttons, sticks, triggers), per-orientation layouts, reset-to-default,
   persisted per system. Keep the input contract: `TCManagerInterface.setButtonStateFor /
   setAxisValueFor(controller: <touchscreen id from ControllerManager.touchscreenControllerId>)`
   and the Wii IR modes (`TCWiiTouchIRMode`, `TCWiiPad.sendIR`). Styling: GameCube purple/indigo
   with the real button shapes (A big green, B small red, X/Y kidney, Z, octagonal stick gate),
   Wii white/light-grey with the blue glow; textures instead of flat fills. This is the largest
   item: one dedicated session per phase (model + persistence; rendering + editing mode; wiring +
   removing the xibs), sonnet for the port/mechanical parts, the main session for the input
   wiring and device verification.
9. **Follows 8:** an in-game editor menu (style/theme, opacity, IR touch-pad area rectangle,
   pointer sensitivity), and a pass over the DSU controller code (`DSUServerBridge`, the mirror
   writes in `TCManagerInterface.mm`) so a redesigned overlay does not double-feed DSU clients.

## D. Pause menu, library and HUD (second user list, same evening)

10. **Pause-menu "Save States" screen** (`SaveStateFilmstripView.swift`, opened from
    `PauseMenuView` `showFilmstripSheet`): redesign as a grid of thumbnails with slot number,
    timestamp, game-time, and a clear Save-here / Load / Delete per card; large-title previews on
    tvOS; controller focus rules from `icube-tvos-swiftui-focus`. Sonnet can draft the layout;
    verify on both platforms.
11. **Library "Boot Save" picker**: broken artwork layout and tapping a state does nothing.
    Entry: `TVLibraryView.swift` (the boot-save sheet near the save-state context actions) ->
    `SaveStateService` pending state. Reproduce on the phone first (tap does not launch), then
    fix the layout in the same pass. Small, main session.
12. **"Boot fresh" still resumes the last auto-save.** Trace `GameLaunchRequest.launch` ->
    `SaveStateService.resumeOrBootIntoPendingState()` (called from the DidStart observers in
    `EmulationScreen.swift`): the "fresh" path must clear the pending state AND skip the
    `<gameid>.auto` load (the coordinator loads it on boot; see `SaveStateFilmstripView.swift:77`
    for the existing "boot fresh then land on state" flow). Also note the debug API's
    `/api/debug/stop` rewrites `<gameid>.auto` (icube-phone-debug-recipe). Small, main session.
13. **Top-bar HUD**: janky and not controller-navigable. Options: (a) make the existing bar a
    focusable `HStack` of buttons with an explicit focus order and a controller shortcut to reveal
    it; (b) replace with a data-driven HUD (see 18). Evaluate packages before building: e.g. a
    focus-engine helper / segmented HUD library that supports tvOS focus; list candidates with
    licenses first (haiku subagent), decide in a design doc.
14. **Fast Forward from the pause menu**: choose the speed (1.5x / 2x / 3x / unlimited) inline,
    then dismiss the menu and start immediately. `PauseMenuView` item at line ~92 toggles via
    `TVEmulationBridge.toggleFastForward()`; needs a `setFastForwardSpeed` bridge (the core's
    `MAIN_EMULATION_SPEED` / `MAIN_FAST_FORWARD_*`) and a HUD pill showing the active speed.
15. **Cheats widget in the pause menu**: show "N active" on the menu item and an on/off toggle
    per cheat inline (`CheatsMenuView.swift`, `PauseMenuView` item at line ~97). Needs a count
    from the core's enabled AR/Gecko lists for the running game.
16. **Shader UI**: strip the debug controls, port iFly's quick-preview pause-menu shader picker
    (live thumbnail per shader, tap to apply, long-press for parameters); keep iCube's visual
    style. Compare `iFly/iFly/Sources/UI/Views/EmulationPauseMenuSupport.swift` and its shader
    picker with `Common/Swift/Shaders/`. Sonnet port, main session wiring.
17. **Library source picker steals focus**: with a controller, booting a game that has more than
    one source (`TVLibraryView.swift:1988` `sourcePickerItems` sheet) moves focus in the sheet
    AND in the library behind it. The sheet needs its own focus scope and the library must
    ignore controller input while a sheet is up (same class as the pause-menu nav in
    `PauseMenuView` `setupPauseControllerNav`). Small, main session with a controller.
18. **Data-driven pause menu and settings, fully controller-navigable on iOS.** Both menus are
    hand-built SwiftUI with per-item focus hacks. Proposal: a `MenuModel` (sections -> items with
    id, title, subtitle, icon, role, action, badge, submenu) rendered by one `MenuScreen` that
    owns focus, controller navigation (d-pad/stick, A/B, shoulders for section jumps), search,
    and reordering; the pause menu, Quick Slots, Controllers, Cheats, Shaders and the Settings
    root become models. Design doc first; then one session for the engine, one per migrated
    screen. This also absorbs 13 (HUD) and the tvOS focus traps.

19. **Library filter pills + search (2026-09-25).** The search icon wraps under the system
    pills even with horizontal room; iFly's row (animated search pill that expands into the
    field, system selection inside the field) is the target. `LibraryPlatformFilterBar`
    (`LibraryPlatformCategory.swift`) + the header in `TVLibraryView.swift`
    (`LibrarySearchableModifier`, `searchText`, `platformFilter`); keep the L1/R1 stepping from
    `8b328498eb`. Sonnet subagent dispatched the same day.

## Session / agent split

- Main session (phone attached over USB): B1, B3 landing, B4, B5, verification of everything.
- Sonnet subagent: B3 element-name trace, B2 implementation (touch-free change), the mechanical
  parts of C8 (port of iFly's layout model + persistence) once the design doc exists.
- New session each: C7 (after a design doc), C8 phases, C9, D18 (engine, then per screen).
- Small main-session items to batch on the next phone day: B1, B4, B5, D11, D12, D14, D17.
- Sonnet/haiku prep that needs no device: D13 package survey, D10 layout draft, D16 port draft,
  B2, B3 element trace.
