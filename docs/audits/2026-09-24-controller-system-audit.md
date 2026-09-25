# iCube controller system audit — 2026-09-24

Scope: every code path between a physical controller, the on-screen touch pads, CoreMotion, and the
emulated GameCube pads / Wii Remotes: `Source/iOS/App/Common/Swift/Controllers/*`,
`DolphiniOS/UI/Emulation/TouchController/*`, `Common/Bridging/{DOLConfigBridge,TVControllerMappingBridge,
InputOverriderBridge}.mm`, `Common/Emulation/EmulationCoordinator.mm` (controller sections),
`Common/UI/Settings/{SwiftUI,Mapping}/*`, `GameProfiles.swift`, and the fork's Dolphin backend
`Source/Core/InputCommon/ControllerInterface/iOS/*`. Five independent read-only reviews (one per layer)
plus the on-device work of 2026-09-23. Every claim below carries a `file:line`; items the reviewers
could not confirm are marked *unverified*.

Upstream Dolphin input code (`SI.cpp`, `Wiimote.cpp`, `WiimoteEmu.cpp`, `ControllerInterface.cpp`,
`InputConfig.cpp`) carries **no iCube-authored changes**. Everything below is in the iOS backend or the
app.

## 1. Verdict

The system has no single owner. The same four pieces of state — which device drives which port, whether
a Wii slot is Emulated or None, which touchscreen instance a pad is bound to, and the IR pointer axes —
each have two to seven writers that run in an order that depends on which screen appeared last. The
2026-09-21 "controller ownership refactor" (`69aa5843f8`) created the intended owner
(`AssignmentEngine` / `ControllerAssignmentService`) but left the older Objective-C++ policy code
(`EnsurePad1DefaultsToTouchscreen` and friends) running *after* it, so the old code still wins. Most of
this week's breakage is that ordering, plus one latent bug (the core's IMU pointer) that the
2026-09-23 motion fix exposed.

## 2. What broke this week, with the mechanism

| Symptom | Mechanism | Evidence |
|---|---|---|
| Wii touch pointer stopped working after the motion fix; gyro toggle does nothing | `6ad1748b9e` made real gyro/gravity reach the core for the first time. The emulated Wii Remote's own IMU pointer (`IMUIR`, enabled by default, never disabled by the Touchscreen profile) folds the phone's real pitch/roll into the IR camera transform (`WiimoteEmu.cpp:964-968`, `Dynamics.cpp:306-350`), so the virtual sensor bar leaves the camera's view. The in-app gyro toggle only stops the feed; `IMUGyroscope::GetState` still returns a bound zero vector, so the core keeps its last rotation. | Fix in working tree: `DisableCoreIMUPointerOnTouchscreenWiimotes()` (`EmulationCoordinator.mm:1482`) called from both touchscreen-binding paths, plus `IMUIR/Enabled = False` in `Data/Sys/Profiles/Wiimote/Touchscreen.ini`. Built and installed as iCube DEV; on-device check (Galaxy title cursor) still pending. |
| Physical pad on Wii Remote 2–4 does nothing | `EnsurePad1DefaultsToTouchscreen` zeroes `WiimoteSource` 1–3 unconditionally (`EmulationCoordinator.mm:1600-1602`), and runs on every `EmulationScreen.onAppear` *after* `reconcile()` activated the slot (`EmulationScreen.swift:1064-1067`). `updateWiimoteEmulationForExternalControllers` only re-activates touchpad-equipped controllers (`ControllerManager.swift:411-451`). | reviewer 1, A1 |
| A pad bound to Wii Remote 1 in Settings reverts to touch every launch | Same function, Wii Remote 1 branch (`:1592-1653`) has no "connected device already bound" guard, unlike the Pad 1 branch (`:1540-1547`). | reviewer 4, A1 |
| Choosing the Gyro IR mode does not stick | `EmulationScreen.swift:1031,1133-1139` treats IR mode `0` (= `.gyro`, `ControllersRootView.swift:560`) as "unset" and writes mode `1` on every appearance. | reviewer 4, A2 |

## 3. Confirmed defects, ranked

Severity: **H** breaks input for a user-visible case, **M** wrong but recoverable, **L** hygiene.

| # | Sev | Area | Defect | Where |
|---|---|---|---|---|
| 1 | H | assignment | Wii Remote 2–4 sources zeroed after `reconcile()` on every screen appearance | `EmulationCoordinator.mm:1600-1602`, `EmulationScreen.swift:1064-1067`, `ControllerManager.swift:411-451`, `AssignmentEngine.swift:74-80` |
| 2 | H | assignment | Wii Remote 1 forced to Touchscreen+Emulated even when a connected pad is bound | `EmulationCoordinator.mm:1592-1653` vs guard at `:1540-1547`; second call from `EmulationScreen.swift:1065` |
| 3 | H | touch | On-screen pads hard-wired to port 1: three device lookups take the *first* `iOS/*/Touchscreen` regardless of port; overlay hardcodes `port = 4` for Wii and never sets a GC port | `TVControllerMappingBridge.mm:175-183`, `EmulationCoordinator.mm:1516-1524, 1679-1691`, `EmulationScreen+TouchAndMotion.swift:251, 165-195`, `TCButton.swift:19` |
| 4 | H | touch IR | Both IR writers put the same value on both members of each antagonist pair; with the backend's negation (`Touchscreen.mm:74-77`) and `Cursor.cpp:67-68` that is 2× horizontal gain and **2× inverted** vertical in gyro mode. The identical bug was fixed for accel/gyro in `6ad1748b9e` but not here. *Static analysis; users have adapted to the doubled drag gain, so change gyro mode first.* | `TCWiiPad.swift:238-247`, `TCDeviceMotion.swift:200-203`, reference pattern `TCDeviceMotion.swift:380-390` |
| 5 | H | config | Per-game profiles write through `SetBaseOrCurrent` before boot, which lands in **Base** (persisted global). Nothing restores the previous values. | `GameProfiles.swift:184-236`, `DOLConfigBridge.mm:198,205,243-245`, `TVLibraryView.swift:2542/2591/2620`, `Config.h:131-136` |
| 6 | H | settings | Gyro IR mode (`0`) clobbered to Follow on every appearance | `EmulationScreen.swift:1031,1133-1139` |
| 7 | M-H | touch | Stuck buttons: `TCButton` handles only `touchDown`/`touchUpInside`; the container tears down and rebuilds all subviews on every SwiftUI update and on every `touchPadsRefreshToken` change; a held button leaves `StateManager` pressed forever | `TCButton.swift:35-36`, `EmulationScreen+TouchAndMotion.swift:180`, `EmulationScreen.swift:1084-1213,1326-1468`, `StateManager.cpp:189-192` |
| 8 | M-H | motion | Three contradictory defaults for `motion_enable_full_6dof` / `motion_wiimote_imu_enabled` / `motion_enhanced_shake_detection`; none registered; readers use raw `bool(forKey:)` so the factory value is `false`, opposite to what the motion fix assumed | `EnhancedMotionControlsView.swift:26-28`, `MotionDebugView.swift:25,30-31`, `TCDeviceMotion.swift:69-71,98-100,134,208-209`, `FirstRunInitializationService.mm:36-39` |
| 9 | M | touch | Wii Remote 1 can stay bound to the **GC** touchscreen instance: if any `.ini` exists in the user Wiimote profile folder, both Touchscreen profiles are skipped and `LoadDefaults()` leaves the id-0 device | `EmulationCoordinator.mm:1613, 1622-1630`, `ControllerEmu.cpp:141-152` |
| 10 | M | lifecycle | Leaked observers registered every `onAppear`, never removed: `assignmentsChanged`, `DOLWiiOverlayLayoutChangedNotification`, `DOLMotionSettingsChanged` (each settings change restarts CoreMotion N times), tvOS background/foreground; `obsGCConnect/obsGCDisconnect` torn down but never assigned | `EmulationScreen.swift:1083-1088, 1048, 569, 573, 264-265, 1162-1187` |
| 11 | M | UX | Overlay visibility not synced to binding: after a pad disconnects mid-game Pad 1 rebinds to touch but the buttons stay hidden; the disconnect banner has no action; the resume pill is hidden while `disconnectPause != nil` | `EmulationScreen.swift:1146-1150, 342, 729`, `ControllerDisconnectBanner.swift:8-9,36`, `AssignmentEngine.swift:62-64` |
| 12 | M | backend | `StateManager` button/axis maps are unsynchronized between the UI writer and the CPU-thread reader | `StateManager.cpp`, `Touchscreen.mm:190,203`, `TCManagerInterface.mm:14,54`, `ControllerInterface.cpp:357` |
| 13 | M | settings | Legacy profile picker mutates and saves live config on row tap, no way back; tvOS "Save Profile" is a `TODO` no-op | `MappingLoadProfileViewController.mm:100-123`, `MappingRootViewController.mm:81-85`, `ButtonMappingView.swift:354-376` |
| 14 | M | motion | `MotionDebugView` runs a second `CMMotionManager` and shake detector that can fire the same shake buttons as `TCDeviceMotion.shared` | `MotionDebugView.swift:399-454, 588-645` |
| 15 | L-M | boot | GC port 1 forced to `SIDEVICE_GC_CONTROLLER` every boot, no user guard | `EmulationCoordinator.mm:1868` |
| 16 | M | backend | Qualifier ids for two identical MFi pads can swap across `RefreshDevices` / relaunch; `GetPreferredId` is commented out. *Unverified on device.* | `ControllerInterface.cpp:125-166, 241-276`, `iOS.mm:51-52`, `MFiController.h:104` |
| 17 | L | coupling | `TCManagerInterface.mm` hard-codes ~30 `ButtonType` integers (already renumbered once in `b32af2a26e`) | `TCManagerInterface.mm:14-49, 95-221`, `ButtonType.h` |
| 18 | L | dead | `motion_enable_ir_cursor` (no effect), `DOLResetIRCursor` (no observer), `IMUIR/Recenter` = button 800 never set, `ControllerGlyphs/StyleManager/Presets` (no callers), unused `@State` in `ControllersRootView` | `EmulationScreen+TouchAndMotion.swift:92`, `MotionDebugView.swift:26,563-566`, `TCButtonType.swift:120`, `ControllersRootView.swift:104-106,131,405-407,444,457-471` |

## 4. Who writes what (the ownership map)

| State | Writers (trigger) |
|---|---|
| `GCPadNew.ini` | `EmulationCoordinator.mm:1587` (boot + every `EmulationScreen.onAppear`); `MappingRootViewController.mm:397/401/405/339` (legacy editor); `TVControllerMappingBridge.mm:165/219/249/404/477` (SwiftUI device picker, profile load, expression edit) |
| `WiimoteNew.ini` | `EmulationCoordinator.mm:1649` (boot + every `onAppear`, unconditional); `MappingRootViewController.mm:397/401/405`; `TVControllerMappingBridge.mm:272/430/523`; `DisableCoreIMUPointerOnTouchscreenWiimotes` (working tree) |
| `SIDevice*` / `WiimoteSource*` | `DOLConfigBridge.mm:198,208` via `BridgeControllerConfigWriter` and Settings; `EmulationCoordinator.mm:1868,1599,1602` (boot policy); `ControllerManager.swift:429,446` (bypasses the service) |
| `MAIN_TOUCH_PAD_IR_MODE` | `DOLConfigBridge.mm:245` from `ControllersRootView.swift:350/570`, `ControllersTouchscreenIRModeViewController.mm:27` (legacy dup), `EmulationScreen.swift:1031,1134,1136,1447,1456,1465`, `GameProfiles.swift:201/207` |
| Wii IR axes | `TCWiiPad.sendIR`, `TCDeviceMotion.handleIRCursorMapping` (mutually exclusive by mode), plus the core's IMU pointer until the working-tree fix |
| Touch pad port | `TCButton/TCJoystick/TCDirectionalPad.port` (view-local), `TCView.SetPort`, C++ `default_device` — no single source |
| `GCController.playerIndex` | single writer `ControllerManager.swift:336-344` — clean |
| Pause request | single sink `PauseGestureTracker.swift:153-190` — clean |
| Extension / Sideways | single writer `DOLWiimoteBridge.mm`; overlay reads index 0 only (`EmulationScreen+TouchAndMotion.swift:238-239`) |

## 5. Remediation plan

**P0 — stop the bleeding (small, independent, each verifiable on the phone)**
1. Verify and land the IMU-pointer fix (working tree). Check: Galaxy title cursor with the phone flat.
2. Remove the Wii Remote 2–4 zero loop, or guard it like Pad 1; call `EnsurePad1DefaultsToTouchscreen` only before boot, never after `reconcile()` (#1, #2).
3. Drop the "IR mode 0 means unset" heuristic (#6).
4. Give `AssignmentEngine` a re-affirm pass on every `reconcile()` so a bound slot's source/device is re-asserted (closes the whole "someone else deactivated it" class).

**P1 — one owner**
5. Move all port/source/device policy into `ControllerAssignmentService`; delete the duplicated profile-loading code in `EnsurePad1DefaultsToTouchscreen` / `ensureWiimoteDefaultsToTouchscreenForPort` and the three "first Touchscreen" lookups; resolve `iOS/<id>/Touchscreen` by id and thread the real port through to the overlay (#3, #9).
6. Per-game profiles: apply on a `CurrentRun`/game-INI layer or snapshot-and-restore; never write Base from a game launch (#5).
7. One set of motion defaults, registered in `DefaultPreferences.plist`; one `CMMotionManager` (#8, #14).

**P2 — correctness and hygiene**
8. Single-sided IR writes; do gyro mode first (it is inverted), then decide whether to halve drag/follow gain and how to migrate users (#4).
9. `touchUpOutside`/`touchCancel` on `TCButton`; clear `StateManager` for a pad on teardown; diff-and-patch instead of rebuilding the overlay (#7).
10. Store and remove every observer registered in `onAppear` (#10). Sync `overlayVisible` on disconnect and give the banner an action (#11).
11. Mutex or atomics in `StateManager` (#12); generate the `ButtonType` constants once (#17); stable `GetPreferredId` for MFi (#16, after a two-identical-pads test); delete the dead code (#18, #13's tvOS stub).

## 5a. P0 status (2026-09-24)

Landed in one commit, verified on an iPhone 16 Pro Max with Super Mario Galaxy: Wii Remote 1 is
written as `iOS/4/Touchscreen`, `IMUIR/Enabled = False`, on-screen Wii controls work again.
1. IMU-pointer fix (working tree -> landed); the emulation-screen setup no longer enables the core
   IMU pointer for gyro mode or shake detection.
2. Wii Remote 2-4 zeroing now skips slots bound to a connected physical controller; the Wii Remote 1
   branch got the Pad 1 "already bound" guard; the post-`reconcile()` call was removed.
3. "IR mode 0 means unset" heuristic removed.
4. `reconcile()` re-affirms activation for every slot bound to a connected physical controller.
5. Extra, found during verification: all three touchscreen lookups now resolve the instance by id
   (GC 0-3, Wii 4-7) instead of "first device named Touchscreen"; this was defect #9 and was the
   actual cause of the Wii touch pad being dead in the DEV container (`Device = iOS/0/Touchscreen`).

## 5b. P1 status (2026-09-24, later)

All compiled for iOS and tvOS; none of these three were exercised on the phone yet.
5. Port threading (#3 remainder): `ac570cd5b3`. `ControllerManager.touchscreenSlot` /
   `touchscreenControllerId` read the bound `iOS/<id>/Touchscreen` qualifier; the overlay, the
   motion feed and the classic/sideways layout query follow it, and `updateUIView` patches the port
   in place. Profile-loading dedupe (#9): `6361096f03`, one `BindTouchscreen()`; the profile is
   reloaded only when the binding changes or the slot has no mapping. Found while merging: the
   per-port path loaded the Bluetooth "MotionPlus Pointing" profile (dead controls, device rebound to
   `Bluetooth/0/Wii Remote`) and vetoed itself whenever Wii Remote 1 was on the touchscreen.
   Policy still lives partly in Objective-C++ (the two fallback vetoes); moving it into
   `ControllerAssignmentService` remains.
6. Per-game profiles -> CurrentRun layer: `2691df551c`.
7. Motion defaults in `DefaultPreferences.plist`: `2691df551c`. One `CMMotionManager` (#14) and the
   dead `motion_enable_ir_cursor` / `DOLResetIRCursor` paths (#18): `c2f36b3743`.

New P2 item found during 5: `ControllerExtensions.swift` `installTouchpadIRHandlers` mirrors a
DS4/DS5 touchpad bound to Wii Remote 2-4 onto controller id 4 (Wii Remote 1's instance) "to support
profiles bound to P1 only", so a second player's touchpad moves player 1's pointer.

## 6. Verified clean by the reviews

`playerIndex` is single-writer; pause-menu requests funnel through one sink and the Start/Menu
correlation race is fixed (`7bd6a76755`); the DSU port parsing crash is fixed (`d191c1452a`); the earlier
per-input logging and tvOS auto player-index code were fully reverted; SI/Wiimote hotplug uses the
upstream Config-polling design unchanged; `DOLConfigBridge.mm:184-190` documents and fixes the
1-based/0-based SIDevice bug.

## 7. Open / unverified

- On-device confirmation of the IMU-pointer fix and of the 2× IR gain claim.
- MFi qualifier drift with two identical controllers (#16).
- Any Wiimote profile-load path outside the two binding paths that could re-enable `IMUIR/Enabled`.
