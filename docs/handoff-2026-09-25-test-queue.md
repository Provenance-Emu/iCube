# Test queue and remaining work — 2026-09-25 (develop `ab7f68f64c`, Provenance `439db0ea52`)

> Superseded in part by `docs/handoff-2026-09-26-fixes-batch.md` (2026-09-26 batch: shaders, save states, IMU fix, overlay editor, l10n bundling).

Everything below is compile-gated (iOS + tvOS) and NOT device-verified unless marked. The DEV
build of `ab7f68f64c` is installed on the iPhone 16 Pro Max. The debug bench is loopback-only in
DEBUG, so logs/screenshots need USB (`iproxy 8726 8723 -u 00008140-001C1C540A12801C`); a game can
be booted without it via `devicectl ... --payload-url 'dolphinios://play?id=<GameID>'`.

## A. Phone tests owed (in priority order)

0. **Assignment fixes (`311fb54add`)** — with a pad connected: pick Touchscreen for Player 1 in
   Settings → Controllers, then confirm the on-screen pad appears and works and that the Wii
   Remote rows did not change; assign the pad to a GameCube port and confirm the Wii rows stay
   put (and vice versa); relaunch and confirm the pad did not take the touchscreen's slot back.
   Then flip Settings → Controllers → "Programmatic touch overlay (beta)" and boot a GC and a
   Wii title: all buttons/sticks/d-pad work, multi-touch (hold d-pad + press A), slide between
   buttons, long-press empty space enters edit mode (drag groups, corner-drag resize, Reset,
   Done); the IR pad is inert in this phase (Wii pointer still needs the flag off).
1. **Remap UI (C7)** — Controllers → Customize Buttons with a real controller on Player 1:
   arm by touch then press (row updates, nothing else arms); arm with A (that press is not
   captured, the next is); bind Button B; each stick half lands on its control; cancel by re-tap
   and by the 5 s timeout; long-press Clear; Save → Load → Reset to Default follows the live
   Pad/Wiimote config; Wii extension + sideways match the pause-menu Controllers screen; with the
   controller: d-pad/stick moves the highlight, A arms, B backs out, no double activation after a
   capture; same screen on Apple TV (native focus, Menu swallowed while armed). Knobs:
   `RemapCaptureMachine.Config` (0.35 threshold, 0.15 rest, 3 polls, 300-poll timeout),
   `RemapControllerNav.Config` (0.4 s / 0.08 s repeat, 0.6 / 0.3 stick hysteresis);
   `RemapModelTests` (18) pass on macOS via a throwaway SwiftPM package.
2. **Wii touch pointer** — Galaxy title cursor with the phone flat in drag / follow / gyro; the
   cursor-mode menu switching in place; Wii pad buttons; `WiimoteNew.ini` `[Wiimote1] Device =
   iOS/4/Touchscreen`. Then bind the touchscreen to Wii Remote 2 in the controller sheet and
   confirm the overlay drives it (`Device = iOS/5/Touchscreen`). Gyro-mode pointer direction and
   reach (gain was halved by the single-sided fix; may need re-tuning).
3. **Pause menu** — open Controllers / Settings / Shaders from the pause menu: the game must stay
   paused; Controllers shows Wii Remotes first on a Wii title; Fast Forward speed pick resumes at
   once at that speed; Cheats item shows "N active".
4. **Library with a controller** — L1/R1 step the system filter; the source picker no longer moves
   the library behind it; boot-save cards launch on tap; the new search/filter bar: pills and search
   on one row, search pill expands with animation, system selectable inside the field, no wrap.
5. **Boot fresh** — "Start Fresh" must not resume the `.auto` state; normal Play still does.
6. **DualSense on a Wii title** — Share/Create pauses only; R3 sends "-"; Options = "+".
7. **Setup view** — Touchscreen on Player 1 shows only on Player 1; profile pick needs one tap;
   picking a device refreshes extension/sideways.
8. **Motion Debug** — live values, no second shake source.
9. **Per-game profiles** (`2691df551c`) — a game with a profile applies it only for that run.
10. **Extensions / ecosystem** — Top Shelf, Quick Look, App Intents, Send to Provenance
    (device gates owed from the other sessions; see icube-extensions-next-steps memory).

## A2. Controls batch landed 2026-09-25 (subagents, NOT yet gated or device-tested)

- Profile persistence: `assign()` keeps a non-empty mapping (`3613078adb`).
- ButtonType drift guard script + stable MFi ids across refresh/reconnect (`26ce575e43`, `a133981932`;
  two identical pads unverified).
- Remap review fixes (`165d401717`..`8e25d3627a`): extension/sideways toggles and both
  profile-load sheets no longer run auto-assign; header rows disabled while a capture is armed;
  ticker on `.common` run loop; one `DEVICE-CHECK` for tvOS focus when the header disables.
- Audit P2 (`7e911c95d6`..`d846e2398c`): touchUpOutside/cancel release, `StateManager::ClearController`
  on pad teardown, StateManager mutex, stored onAppear observers, disconnect banner with
  "Use Touch Controls".
- Overlay phase 3 part 1 (`06842eec02`..`5b81dd853f`): IR drag/follow on the new pad (editable
  `.fillInset` rect), force-sensitive triggers, Style / Edit Layout… / Reset rows.
Phone: rerun items 0-1 above on this build; on Wii with the beta overlay on, drag/follow pointer
and three-finger recenter; trigger pressure on GC; the Edit Layout preview from Settings.

## B. Work remaining (after the next prompt)

- **C8 touch overlay phase 3** — phase 2 landed (`42f9ea462b`..`0eb552233e`, flag
  `touch_overlay_programmatic` default OFF): port Wii IR drag/follow onto the IR pad, analog
  trigger pressure, Style / IR-area / Edit Layout settings rows, then flip the default and remove
  the xibs after the device checklist in the design doc §8. Unit tests for phases 1-2 have NOT
  been executed: simulator builds fail on a pre-existing PVHelp resource-bundle codesign error
  ("bundle format unrecognized") — fix that first (likely a `Bundle` resource in the SPM
  package needing CODE_SIGNING_ALLOWED=NO or an explicit bundle-format fix).
- **Profile survives reconnect** — `ControllerAssignmentService.assign` reloads the device-default
  profile whenever the engine re-places a pad (every reconnect/boot), overwriting a user-picked
  profile; add a "keep mapping if non-empty" rule (needs a writer read for the slot's mapping).
- **D18 data-driven menus + controller-navigable Settings/pause menu** — design at
  `docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`; `RemapControllerNav` is to be
  renamed into its `MenuScreen`, not rewritten. Absorbs the top-bar HUD item (D13; package survey
  in `docs/research/2026-09-24-hud-menu-packages.md` recommends built-in focus first).
- **D10 pause-menu Save States redesign**, **D16 shader UI** (strip debug, port iFly quick
  previews), **C9 overlay style / IR-area menus + DSU pass** — all in
  `docs/superpowers/plans/2026-09-24-controller-followups.md`.
- **Audit P2 remainder** — drag/follow IR gain decision, stuck-button handling on teardown,
  observers registered in onAppear, overlay visibility on disconnect, `StateManager` locking,
  `ButtonType` constants from one source, MFi `GetPreferredId`.
- **Small follow-ups** — `ConfigGeneralView` shows 300% instead of Unlimited for FF speed 0;
  `PendingGameLaunchStoreTests` not wired into any target; new library strings not in a
  localization catalog; the no-arg `setWiiIMUPointEnabled:` wrapper has no callers; two shader
  clones in `Externals/` are kept but only locally excluded.
- **Open investigations** — Melee auto-save "decompressing state" green hang (needs the release
  app's bench enabled), Colosseum loadstate spin, TestFlight external distribution check after
  the next daily build.
