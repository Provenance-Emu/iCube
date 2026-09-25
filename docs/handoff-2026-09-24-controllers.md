# Handoff 2026-09-24 — controller system: finish P1, then P2

Companion to `docs/audits/2026-09-24-controller-system-audit.md` (defect numbers below refer to its
§3 table). Everything here was true at iCube develop `c0029c9284` / Provenance develop `e1abecbda2`.

## State

Landed on develop (all pushed, gitlink bumped):

| Commit | What |
|---|---|
| `88cb2f447c` | Staged, size-verified game imports (`DOLImportStaging`) — iPad "disc read errors" were truncated copies |
| `0203804a31` | The audit itself |
| `c0029c9284` | P0: touchscreen instances resolved by id (GC 0-3, Wii 4-7) in all three binding sites; core IMU pointer off for touchscreen Wii Remotes; Wii 2-4 zeroing guarded; Wii Remote 1 "already bound" guard; post-`reconcile()` fallback call removed; "IR mode 0 = unset" removed; `reconcile()` re-affirms bound slots |
| `7ed159f6a5` | Cursor-mode menu updates the mounted `TCWiiPad` in place; `EmulationScreen` is the single owner of the core IMU pointer (`.onChange(of: isTouchControlsActive)`) |
| `2691df551c` | Per-game profiles write Dolphin values into the CurrentRun layer after emulation-did-start; motion defaults registered once in `DefaultPreferences.plist` |
| `38da0e318c` / `0dd61c9410` | Eclipse `GMSE04.ini`; adaptive-clock starvation guard |

Device-verified: P0 (Galaxy: `[Wiimote1] Device = iOS/4/Touchscreen`, IMUIR off, user confirmed the pad
works). **Not** device-exercised: `7ed159f6a5` and `2691df551c` (compiled iOS + tvOS; phone locked).
The combined develop head compiled for iOS in a worktree; it was not re-gated on tvOS as a whole.

## P1: done (2026-09-24, later session)

| Commit | What |
|---|---|
| `ac570cd5b3` | Port-aware overlay: `ControllerManager.touchscreenSlot` / `touchscreenControllerId`, overlay + motion feed + layout query follow the bound slot, in-place port patch in `updateUIView` |
| `6361096f03` | One `BindTouchscreen()` in `EmulationCoordinator.mm`; profile reloaded only on rebinding / empty mapping; per-port path no longer loads the Bluetooth MotionPlus profile or vetoes itself |
| `c2f36b3743` | `MotionDebugView` polls `TCDeviceMotion.shared.latestSample`; `triggerShake()`; dead `motion_enable_ir_cursor` / `DOLResetIRCursor` removed |

All three compiled for iOS and tvOS (`iCube (NJB)`, Debug (Non-Jailbroken)); **none exercised on the
phone yet**, nor were `7ed159f6a5` / `2691df551c`. Phone checklist: Galaxy title cursor with the
phone flat (drag/follow/gyro via the cursor menu), a Wii pad button press, `WiimoteNew.ini`
`[Wiimote1] Device = iOS/4/Touchscreen`, then bind the touchscreen to Wii Remote 2 in the controller
sheet and confirm the overlay drives it (`Device = iOS/5/Touchscreen`, log line
`Wii Remote 2 -> iOS/5/Touchscreen`), Motion Debug screen shows live values with no second shake.

## User reports after P1 (same evening) and the plan for them

See `docs/superpowers/plans/2026-09-24-controller-followups.md`: pause-menu Controllers was
GameCube-only (fixed: `ControllerManager.isWiiSystem` was never set), the setup view showed
Touchscreen on all four rows (fixed: inactive slots now show None), profile pick double-tap
(fixed: dismiss before load), "no cursor in any mode" (not reproduced; DEV config healthy, likely
the pre-P0 release build), plus the queue: unpause-while-in-menu (`PauseMenuView.onDisappear`
resumes), library system filter via paddles, DualSense Share/Options vs GameCube Start, remapping
UI rewrite, programmatic on-screen controller ported from iFly's skin stack, style/IR-area menus
and a DSU pass.

## Remap UI rewrite (C7) — landed 2026-09-25, not device-exercised

`RemapPlayerView` (`Common/Swift/Controllers/Remap/`) replaces the storyboard / `TVMappingRootViewController`
drill-down behind "Customize Buttons…". Capture polls `inputStates(forQualifiedDevice:)` at 60 Hz through
`RemapCaptureMachine` (release-to-arm, 0.35 threshold, 3-poll debounce, 5 s timeout); profile save is the new
`saveProfile:forGCPort:/forWiimote:`. Plan + spec corrections: `docs/superpowers/plans/2026-09-25-remap-ui-implementation.md`.
Compiled iOS + tvOS; `RemapModelTests` (11) green on macOS via a throwaway SwiftPM harness. Needs the phone with a
controller: arm by touch and by A, bind `Button B`, stick halves, cancel by re-tap and timeout, long-press Clear,
save → load → Reset to Default, Wii extension/sideways consistency with the pause-menu Controllers screen.
The legacy stack (`ButtonMappingView.swift`, `ButtonMapping.storyboard`, ObjC `Common/UI/Settings/Mapping/`) is deleted.

## Then P2 (audit §5, items 8-11)

- Single-sided IR writes: `TCWiiPad.sendIR` (`TCWiiPad.swift:238-247`) and
  `TCDeviceMotion.handleIRCursorMapping` (`:200-203`) write the same value to both antagonist axes →
  2× gain in drag/follow, 2× **and inverted** vertical in gyro mode (defect #4). Do gyro mode first
  (it is plainly wrong); decide separately whether to halve drag/follow gain, since users have
  adapted. Reference pattern: `imuAccelWrites` / `imuGyroWrites` (`TCDeviceMotion.swift:380-440`).
- `touchUpOutside` / `touchCancel` on `TCButton` (`TCButton.swift:35-36`) and clear the pad's
  `StateManager` entries on teardown (defect #7). `updateUIView` now patches in place for the
  common case (`7ed159f6a5`), so the rebuild path is rarer but still unguarded.
- Store and remove the observers registered in `onAppear` (`EmulationScreen.swift` ~1048,
  ~1083-1088, tvOS ~569/573; dead `obsGCConnect/obsGCDisconnect` ~264-265) (defect #10).
- Sync `overlayVisible` when the bound controller disconnects; give `ControllerDisconnectBanner`
  an action (defect #11).
- `ControllerExtensions.swift` `installTouchpadIRHandlers`: a DS4/DS5 touchpad on Wii Remote 2-4
  is mirrored onto controller id 4 (Wii Remote 1), so player 2's touchpad moves player 1's pointer.
- `StateManager` mutex/atomics (defect #12); `ButtonType` constants from one source (#17); stable
  `MFiController::GetPreferredId` after a two-identical-pads test (#16); legacy mapping editor:
  tvOS "Save Profile" stub and the on-tap profile load (#13).

## How to verify on the phone

- iPhone 16 Pro Max: coredevice `5BD0518D-E8D9-5115-919A-A7C12481E82D`, lockdown UDID
  `00008140-001C1C540A12801C`. Debug server: `iproxy 8726 8723 -u 00008140-001C1C540A12801C`,
  then `http://127.0.0.1:8726/api/...`. Restart iproxy after every relaunch. The release
  `com.joemattiello.iCube` holds port 8723 when running; terminate it (`devicectl device process
  terminate --pid`) before testing `com.joemattiello.iCube-debug`.
- Boot: `POST /api/debug/boot {"gameID":"RMGP01"}` (Super Mario Galaxy is in the DEV container;
  `GALE01` Melee too). Pull configs with `devicectl device copy from ... --domain-identifier
  com.joemattiello.iCube-debug --source Documents/Config/WiimoteNew.ini`. Expected after a Wii
  boot: `[Wiimote1] Device = iOS/4/Touchscreen`, `Source = 1`, `IMUIR/Enabled = False`.
- Touch input cannot be injected over the API; the user tests the pads and the cursor-mode menu.

## Build / git gotchas (cost hours today)

- The shared checkouts may sit on another agent's branch (`feature/extensions-topshelf-quicklook`
  in dolphin-ios, `feature/realm-free-extensions` in Provenance). **Never commit there.** Use the
  worktrees: `$SCRATCH/devwt` (dolphin-ios develop) and `$SCRATCH/provwt` (Provenance develop);
  if they are gone, `git worktree add <dir> develop`, `rsync -a --exclude .git <main>/Externals/
  <wt>/Externals/` (nested submodules!), `cd Source/iOS/App && tuist generate --no-open`, build
  with `-derivedDataPath build-Xcode` inside the worktree. A first core build needs ~5 GB free.
- Bump the Provenance gitlink from the develop worktree with
  `git update-index --cacheinfo 160000,<full sha>,Cores/Dolphin/dolphin-ios`, commit
  `--no-gpg-sign` if 1Password hangs, push develop.
- Those feature branches carry duplicate copies of today's commits and five stale gitlink bumps;
  when they merge, take develop's gitlink.
- `zsh` does not word-split `$VAR` — quote-expand lists with `${=VAR}` or spell the paths out.
- tvOS gate: `xcodebuild build -workspace iCube.xcworkspace -scheme 'iCube (NJB)' -configuration
  'Debug (Non-Jailbroken)' -destination generic/platform=tvOS CODE_SIGNING_ALLOWED=NO
  -derivedDataPath build-Xcode-tvos` (separate derived data so it cannot race the iOS build).

## Prompt for the next session

```
Continue the iCube controller work from docs/handoff-2026-09-24-controllers.md and
docs/audits/2026-09-24-controller-system-audit.md (dolphin-ios develop, P1 done in ac570cd5b3 / 6361096f03 / c2f36b3743).
First get the P1 commits and 7ed159f6a5 / 2691df551c verified on the phone (checklist in the
handoff), fixing whatever that turns up. Then start P2 with the single-sided IR writes in gyro
mode, followed by the DS4 touchpad mirror onto Wii Remote 1. Work from the develop worktrees
described in the handoff, never on the shared checkouts' feature branches; gate iOS and tvOS
before each commit; commit one logical change at a time on dolphin-ios develop, push, and bump
the Provenance gitlink from its develop worktree. Verify on the phone as described (the user
tests touch input by hand). Report what is device-verified versus only compiled.
```
