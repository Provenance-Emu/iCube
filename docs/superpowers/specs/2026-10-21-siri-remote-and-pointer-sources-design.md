# Siri Remote as a menu device, and controller-adaptive Wii pointer sources

Status: DRAFT for owner review, 2026-10-21. Nothing here is built yet.
Companion fixes landed the same day on `fix/tvos-testing-batch-2026-10-21`
(library shelf focus, cheats pane, handoff sheet, Audio pane) and are not covered here.

## Intent

From the 2026-10-21 tvOS test notes:

- "the siri remote is pretty useless for gamecube and wii … we should not allow it for gameplay,
  warn users if no controllers connected and use the siri remote only for menu navigation … then
  we can use the extra buttons for quick actions … for wii, if the p1 controller doesn't have a gyro
  function or touch pad like a ps4/ps5 controller, then we can allow the remote gyro to be the
  pointer cursor."
- "check that our default profiles and wii ir cursor settings are easy to use and allow using the gyro
  or touchpad for the cursor on controllers that have those … auto adapt the settings based on
  controller functions … make the quick settings clear which one we're setting too for
  gyro/drag/follow depending on device support and a label showing what the input is (maybe even a
  small widget showing the 6d graph of live data)."

Two features, one design, because they share a core idea: **the app decides where the Wii pointer
comes from, from what is connected, and says so in plain words.**

## Current state (what the code does today)

Findings from a read of the controller stack on 2026-10-21; file references are to
`Source/iOS/App/Common/Swift` unless noted.

1. **The Siri Remote is a gameplay controller.** `MFiController.mm:206-216` enumerates it as an
   `MFi/<n>/<name>` device with A, X, Menu and a D-Pad. `AssignmentEngine.decide`
   (`AssignmentEngine.swift:79-134`) treats every non-`iOS/` qualifier as a physical pad, so a remote
   that enumerates first takes GC port 1 or Wii Remote 1. The only remote classifier is
   `LivePerformanceSession.isRemote` (`micro != nil && extended == nil`), tvOS-only, in a Performance
   file. `ControllerInfo.hasMicroGamepad`/`hasExtendedGamepad` exist in the snapshot and nothing reads
   them.
2. **tvOS has no CoreMotion**, so `TCDeviceMotion` (the phone-gyro pointer) compiles out. Remote or pad
   motion reaches the core only through `GCMotion`, as the MFi device's `Accel */Gyro *` inputs.
   Whether the Siri Remote reports `GCController.motion` with `hasRotationRate` is **unverified**;
   nothing logs it.
3. **Default profiles are capability-blind.** `BridgeControllerConfigWriter.defaultProfileName`
   (`Controllers/BridgeControllerConfigWriter.swift:69-77`) picks by qualifier prefix only. The Wiimote
   `Physical Controller.ini` binds `IMUAccelerometer/*` and `IMUGyroscope/*` to the pad's `Accel/Gyro`
   inputs and sets `IMUIR/Enabled = True` for **every** pad, and has no `IR/Up..Right` binding. So a pad
   without a gyro (Xbox, bare MFi, Switch Pro if `motion == nil`) gets a pointer that never moves.
4. **The DualSense/DS4 touchpad is not a real pointer source.** `installTouchpadIRHandlers`
   (`Controllers/ControllerExtensions.swift:318-413`) writes `wiiInfrared*` into a *Touchscreen*
   instance that the pad's own MFi-bound slot does not read; drag mode is commented out; `irMode` is
   read once. `touchpad_ir_follow_without_click` has a writer in Settings and no reader.
5. **Two vocabularies for one thing.** The iOS top bar's "Wii Pointer" shows Gyro / Touch – Follow /
   Touch – Drag for every setup (`TopBar/EmulationTopBar.swift:257-271`); "Gyro" there means the
   *phone's* gyro. The hub and player screen use a separate per-slot toggle, "Aim with Controller
   Motion" (`IMUIR/Enabled`). Nothing names the physical source. tvOS has no pointer UI in the pause
   or quick menus; the hub's gyro-pad toggle has no platform guard so it appears on tvOS.
6. **Warnings:** only the mid-game `ControllerDisconnectBanner` exists. Nothing warns when a game boots
   with no gameplay controller, and nothing in the library.

## Goals

- G1. On tvOS, the Siri Remote never occupies a GameCube or Wii slot. It navigates menus and drives
  quick actions. Games see no input from it.
- G2. A tvOS user who starts a game with no gameplay controller is told so once, with a way to fix it.
- G3. On a Wii title, Player 1 always has a pointer that works with what they hold: the pad's gyro,
  the pad's touchpad, the Siri Remote's gyro (tvOS) or the device's gyro / touch (iOS), in that order
  of preference.
- G4. Every pointer control says which physical input it is talking about ("Pointer: DualSense gyro"),
  and only shows the modes that apply to that input.
- G5. One pure resolver decides the pointer source; it is unit-tested; the UI and the profile writer
  both read it.

## Non-goals

- Changing how the touchscreen Wiimote (iOS, slots 4–7) is driven. Follow / Drag / phone-gyro stay as
  they are; this design only changes *when* they are the source and how they are labelled.
- Rumble, lights, battery, or anything on the GameCube side of controllers.
- Netplay or DSU pointer behaviour.
- Mapping the Siri Remote's touch surface as an analog stick for gameplay. The owner's call is that
  the remote is not a gameplay device; this design honours that fully.

## Anti-goals (what would make this a failure)

- A pad that could aim yesterday (DualSense gyro) stops aiming after the change.
- The remote still fires A/Start/+ into a game while the pointer code thinks it is "menu only".
- A warning that nags every boot, or blocks a user who deliberately plays with the remote on a game
  that is fine without one (there are a few; Wii Channels, menus). The warning is informative and
  dismissable, never a gate.
- A sixth playerIndex writer. `ControllerManager.syncPlayerIndices` stays the only one.

## Constraints

- tvOS 17+, iOS 17+. No CoreMotion on tvOS; `GCMotion` is the only motion API there.
- Dolphin expressions can reference another device by qualifier (``` `MFi/1/Siri Remote:Gyro Pitch Up` ```),
  so a slot can take motion or IR from a device it is not bound to **without new ControllerInterface
  code**. This is the mechanism for both the remote-gyro pointer and the device-gyro fallback.
- Profiles are per-system INIs in `Data/Sys/Profiles/Wiimote/`. Variants must keep the existing
  "Physical Controller" name working (users have stashes referencing it).
- The hub, player screen and top bar are all built from pure model builders with tests; the resolver
  must be a value type they can all consume.

## Design

### Part A — the Siri Remote is a menu device (tvOS)

**A1. One classifier.** `enum ControllerClass { case gameplayPad, menuRemote, virtual }` with
`ControllerClass.of(_ c: GCController)` = `.menuRemote` when `microGamepad != nil && extendedGamepad == nil`
(the `LivePerformanceSession.isRemote` rule, moved to `Controllers/ControllerClass.swift` and used
from there). `ControllerInfo` gains `class` computed from its existing micro/extended flags, so
`ControllerStateStore.snapshot()` carries it with no new GameController calls.

**A2. The engine never seats a remote.** `AssignmentEngine.decide/decideBoot/player1Takeover` filter
`connectedQualifiers` through the snapshot's class and drop `.menuRemote` exactly as they drop
`iOS/` virtual devices today (`isVirtual`). The remote's MFi device stays enumerated in the core (it
is harmless unbound) so the pointer path in A5 can reference it. `choosePlayer1`,
`takePlayer1FromTouchscreen`, `updateWiimoteEmulationForExternalControllers`, the hub's
`connectedPads()`, and `ControllerGlyphs.detectGlyphSet` all read the same class and skip remotes.
The hub lists the remote under its own caption: "Siri Remote — menus and quick actions only".

**A3. Remote inputs stay out of games by construction**, because nothing is bound to the device.
The existing `ControllerInputLease` is no longer needed for that purpose (it remains for the
Performance overlay). The ungated Menu route (`installPauseMenuHandlers` micro branch) is kept: it is
the pause button.

**A4. No-controller notice.** New `GameplayControllerNotice` (tvOS only): when `EmulationScreen`
reaches its first presented frame and `ControllerStateStore.snapshot()` has no `.gameplayPad`, the
pause menu's confirm-panel style overlay says: *"No controller connected. The Siri Remote only
navigates menus. Connect a controller to play."* with **Continue** and **Controllers** (opens the hub).
It is checked 3 s after the first presented frame (a pad connecting during boot must not trip it),
shows once per boot (a `@State` on the screen), and never when the boot came from the Performance or
screenshot harness arguments. A device that is neither micro nor extended (the Switch Online N64 pad)
classifies as `.gameplayPad`, so it never triggers the notice. The library shows nothing; the game screen is the moment it matters.

**A5. Remote gyro as the pointer** (when A1–A4 are in and the probe in A7 says the remote has motion).
When the resolver (Part B) returns `.remoteGyro` for Wii slot 1, the profile writer sets slot 1's
`IMUGyroscope/*` and `IMUAccelerometer/*` bindings to the remote's qualifier
(``` `MFi/<n>/<name>:Gyro Pitch Up` ``` …) and `IMUIR/Enabled = True`, in the slot's CurrentRun layer,
restored when the remote disconnects. **Recenter** is not an API in the core: `IMUCursor` has a
bindable `Recenter` control (`IMUCursor.cpp:26`, read in `Dynamics.cpp`) that no profile binds today.
The fallback writes `IMUIR/Recenter` to a synthetic button on the slot's `iOS/<id>/Touchscreen` device
(a new `ButtonType` id, set through `TCManagerInterface` for one frame), and the tvOS pause menu's
"Recenter Pointer" tile presses it. The iOS tile keeps calling `TCDeviceMotion.recenterPointer` for the
phone-gyro source and presses the same button for pad or remote sources.

**A6. Quick actions on the remote** — owner decisions, listed with my defaults:
- Play/Pause: toggle pause (today an empty swallow). Default **on**.
- Menu short press: pause menu (today). Menu hold 2 s: exit to library (today).
- Click-pad swipe up/down while in game: nothing by default; option in the hub to map to quick save /
  quick load. Default **off** (accidental swipes while the remote sits on the couch).
- Microphone / Siri: out of scope; the system owns that button.

**A7. Capability probe and log.** On every `GCControllerDidConnect`, log
`class, vendorName, productCategory, motion != nil, hasRotationRate, hasAttitude, sensorsRequireManualActivation, supportsTouchpad`
through `ICubeLog`. This settles the two unverified facts (remote motion, Switch Pro motion) on the
owner's devices before A5 or B3 ship.

### Part B — controller-adaptive pointer sources (iOS and tvOS)

**B1. Capabilities.** `struct PadCapabilities: Equatable { hasGyro, hasAttitude, hasTouchpad, family: DeviceFamily }`
built from one `GCController` in `ControllerStateStore` and carried on `ConnectedPadState`
(today only `hasGyro`/`hasLight`). `hasTouchpad` is `GCController.supportsTouchpad` as it exists.

**B2. The resolver.**
```
enum PointerSource: Equatable {
  case padGyro(padName: String)        // DualSense, DS4, Switch Pro if it reports motion
  case padTouchpad(padName: String)    // DualSense / DS4 touchpad, absolute
  case remoteGyro                      // tvOS, Siri Remote motion, plain pad as P1
  case deviceGyro                      // iOS, phone/iPad motion, plain pad or touch P1
  case touchFollow, touchDrag          // iOS, touchscreen Wiimote
  case none                            // nothing can aim (tvOS, plain pad, no remote motion)
}
enum PointerSourceResolver {
  static func resolve(player1: PadCapabilities?, remoteHasMotion: Bool, platform: Platform,
                      preferredMode: PointerMode, userOverride: PointerSource?) -> PointerSource
}
```
Order: user override → pad gyro → pad touchpad → (tvOS) remote gyro → (iOS, touchscreen P1 only)
`preferredMode` (gyro → `.deviceGyro`, follow/drag → touch) → `.none`. A plain pad as P1 on iOS resolves
to `.none` unless the user picks "iPhone gyro" in the list (Open question 4). `userOverride` is stored
per game (MD5) in `GameProfile`, beside the existing `wiimoteTouchIRMode`, and falls back to a
per-system default in `UserDefaults`; it survives a profile-variant switch because it is read by the
resolver, not written into the profile. Pure, with a table test per platform and pad
class. `PointerMode` (the existing `MAIN_TOUCH_PAD_IR_MODE`) keeps its meaning for the touchscreen
and becomes the *preference* input to the resolver rather than the thing the UI shows directly.

**B3. Profiles follow the source.** `BridgeControllerConfigWriter.defaultProfileName(qualifier:, capabilities:)`
chooses among three Wiimote variants in `Data/Sys/Profiles/Wiimote/`:
- `Physical Controller.ini` (unchanged name; gyro pads): as today, `IMUIR/Enabled = True`.
- `Physical Controller (Touchpad).ini`: `IR/Up..Right = Touchpad Y-/Y+/X-/X+`, `IMUIR/Enabled = False`.
  This makes the DualSense touchpad a real pointer source through the core, and retires the
  `installTouchpadIRHandlers` Touchscreen-instance detour and the dead
  `touchpad_ir_follow_without_click` key.
- `Physical Controller (No Motion).ini`: no IMU bindings, `IMUIR/Enabled = False`; the slot's IR groups
  are then written at runtime by the fallback in B4 or left empty (`.none`).
`Wii Remote with MotionPlus Pointing.ini` (hidden from lists, IMUIR on) follows the gyro rule.
The GCPad side is unchanged. Choice is made only where the writer already applies a default
(`ControllerAssignmentService.assign` when there is no stash and no device-bound mapping). A pad
whose stash already names "Physical Controller" keeps it: capability changes never rewrite a user's
mapping. The pointer list (B5) shows a one-time row, "Use the touchpad as the pointer", when the
resolver would pick a different variant than the stash holds, and that row applies the variant.
Absolute touchpad IR snaps the cursor to centre when the finger lifts (the core's IR group behaviour);
that is the accepted trade-off for a profile-only source (Open question 3).

**B4. Fallbacks write cross-device bindings into CurrentRun**, never into the user's profile:
- `.remoteGyro` (tvOS): slot 1 IMU groups → remote qualifier (A5).
- `.deviceGyro` (iOS, plain pad as P1): slot 1 `IR/Up..Right` → ``` `iOS/4/Touchscreen:Axis 112..115` ```,
  the axes `TCDeviceMotion` already writes for the touchscreen slot; `TCDeviceMotion.setPort` is widened
  to "the slot the resolver chose" instead of "the touchscreen's port". No new axis ids.
Both are torn down on disconnect or when the resolver's answer changes.

Two things the code makes harder than the sentence above suggests:
- **The MFi ordinal is not stable across reconnects** (`iOS.mm` ordinal bookkeeping), so a qualified
  binding like ``` `MFi/1/Siri Remote:Gyro Pitch Up` ``` goes stale, and `TVControllerMappingBridge`'s
  `SaveConfig` (`:310`, `:676`) persists whatever is live, including CurrentRun writes. The fallback
  therefore (1) re-resolves the qualifier on every connect/disconnect through `MFiController::IsSameController`,
  and (2) is written with `Config::LayerType::CurrentRun` *and* removed before any `SaveConfig`, the same
  way `DisableCoreIMUPointerIfTouchscreen` scrubs touchscreen slots. A test asserts a saved profile never
  contains a cross-device qualifier.
- **`TCDeviceMotion` has one `port`** tied to overlay rebuilds (`setPort`, `:610`) and also writes the IMU
  axes 625–636 and `writeRestingIMU` to it. For `.deviceGyro` on a pad slot it needs a second,
  pointer-only port: IR axes to the resolved slot, IMU axes stay on the touchscreen slot. And
  `DisableCoreIMUPointerIfTouchscreen` / `RepairTouchscreenIRPointer` must key on the slot's *bound
  device*, not on "IR is bound to a Touchscreen axis", or they will treat the pad slot as a touchscreen.
- **Scope:** the resolver runs for Player 1 only. Players 2–4 keep today's behaviour (gyro pads aim,
  plain pads have no pointer); the pointer list in B5 names P1 explicitly ("Player 1 pointer").

**B5. One pointer UI vocabulary.** Every pointer control (iOS top bar "Wii Pointer", hub
`pointerRow`, player screen Pointer & Motion, the tvOS pause menu) is built from the same
`PointerSourceModelBuilder`:
- Header line: *"Pointer: DualSense gyro"* / *"Pointer: Touchpad"* / *"Pointer: Siri Remote gyro"* /
  *"Pointer: iPhone gyro"* / *"Pointer: Touch (Follow)"* / *"No pointer — connect a controller with motion"*.
- Rows shown only when they apply: Source picker (every source the resolver *could* return for this
  setup, so the user can override), Recenter (any gyro source), Sensitivity / Invert (gyro sources),
  Drag Sensitivity (touch drag), "Aim with Controller Motion" disappears as a separate concept (it is
  the Source picker's pad-gyro entry).
- The tvOS pause menu gains a "Pointer" tile for Wii titles (the existing Recenter tile generalised),
  opening this same list.
The old `PointerMode` cycle on the iOS top bar is replaced by this list; `PointerModeController`
stays as the touchscreen preference store.

**B6. Live motion widget** (owner's "maybe"). A `MotionSampleFeed` protocol with two producers:
`TCDeviceMotion.latestSample` (iOS, exists) and a `GCMotion`-backed feed for the active pad or remote.
`MotionDebugView` already draws a 6-axis trace from the first; the pointer list shows a 120×48 pt
sparkline row of the resolved source's rotation rate and gravity under the header, so the user sees
which physical thing is moving the cursor. Default **on** in the pointer list, hidden on the top bar
popover (space). My call: ship it only after B5, since it is decoration on top of the labelling.

### Phasing

1. A7 probe + B1 capabilities + B2 resolver with tests. Ship behind nothing; it changes no behaviour.
   Owner reports the remote and Switch Pro probe lines from device.
2. A1–A4: remote classification, engine exclusion, hub caption, no-controller notice. Tests:
   `AssignmentEngineTests` with a remote in the snapshot; a notice builder test.
3. B3 + B5: profile variants, capability-driven default, unified pointer list on iOS and tvOS.
   Tests: `defaultProfileName` by capability; `PointerSourceModelBuilder` rows per source;
   `WiiPointerProfileTests` for the two new INIs.
4. A5 + B4: cross-device fallbacks (remote gyro on tvOS, device gyro for a plain pad on iOS), with the
   pause-menu Pointer tile on tvOS. Gated on the probe from phase 1.
5. B6 widget.

Each phase is a PR of its own against `develop`; none depends on a core (C++) change.

### Open questions for the owner

1. **Remote quick actions (A6):** Play/Pause toggles pause by default? Swipe-to-quick-save off by
   default? Anything else you want on the click pad?
2. **The no-controller notice (A4):** once per boot, or once per install with a "don't show again"?
   I propose once per boot; it is cheap to dismiss and the situation is rare.
3. **Touchpad pointer mode (B3):** absolute (finger position = cursor position, as the handlers do
   now) or relative drag? Absolute is what the profile can express directly; drag needs app code.
4. **Should a plain pad as P1 on iOS use the phone gyro by default (B4 `.deviceGyro`)**, or stay
   pointer-less until the user picks it? The phone usually sits in a stand with a pad, so tilting it is
   odd; I propose default **off** (resolver returns `.none`, the list offers "iPhone gyro" as a choice).
5. **Keep "Aim with Controller Motion" as a toggle anywhere**, or fold it fully into the Source picker as
   B5 proposes?

### Reviewer pass

A builder-check (2026-10-21) read this document against the code. Its corrections are folded in above:
recenter is a bindable input not an API (A5); MFi ordinals are unstable and `SaveConfig` would persist a
CurrentRun cross-device binding (B4); `TCDeviceMotion` is single-port and the touchscreen-slot scrub
helpers key on IR bindings (B4); the resolver's scope is P1 (B4); override persistence (B2); stash
precedence and the MotionPlus profile (B3); notice timing and the N64 pad (A4). Its remaining
questions are the owner's and are listed above.

### Calls I made (check these while reading)

- Classification by `micro && !extended` only. The Switch Online N64 pad has neither and is handled by
  `PhysicalProfileController`; it stays a gameplay pad.
- The remote stays enumerated in the core, unbound, rather than being filtered out of
  `allQualifiedDevices`, so its motion can be referenced by expression.
- Cross-device expressions in the CurrentRun layer are the fallback mechanism, not a new
  ControllerInterface device or Touchscreen-axis hacks.
- Profile *variants* with new names, not edits to `Physical Controller.ini`'s contents.
- No library-level warning; the game screen is where the user discovers the problem.
