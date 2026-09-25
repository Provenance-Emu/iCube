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

## Session / agent split

- Main session (phone attached over USB): B1, B3 landing, B4, B5, verification of everything.
- Sonnet subagent: B3 element-name trace, B2 implementation (touch-free change), the mechanical
  parts of C8 (port of iFly's layout model + persistence) once the design doc exists.
- New session each: C7 (after a design doc), C8 phases, C9.
