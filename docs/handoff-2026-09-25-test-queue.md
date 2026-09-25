# Test queue and remaining work — 2026-09-25 (develop `ab7f68f64c`, Provenance `439db0ea52`)

Everything below is compile-gated (iOS + tvOS) and NOT device-verified unless marked. The DEV
build of `ab7f68f64c` is installed on the iPhone 16 Pro Max. The debug bench is loopback-only in
DEBUG, so logs/screenshots need USB (`iproxy 8726 8723 -u 00008140-001C1C540A12801C`); a game can
be booted without it via `devicectl ... --payload-url 'dolphinios://play?id=<GameID>'`.

## A. Phone tests owed (in priority order)

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

## B. Work remaining (after the next prompt)

- **C8 touch overlay phase 2** — chip pending (click it): rendering, multi-touch input, editing
  mode, styling, behind a feature flag, on top of the landed `TouchOverlay/` phase 1. Phase 1's
  unit tests have not been executed on a simulator. Phase 3 (IR, xib removal) after that.
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
