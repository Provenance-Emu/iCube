# Programmatic touch overlay (port of iFly's control-group stack)

Design doc for plan items **C8** and **C9** in `docs/superpowers/plans/2026-09-24-controller-followups.md`: replace the xib-based GameCube/Wii on-screen pads with a programmatic, user-editable, per-orientation overlay, plus the settings surface for it.

## 0. Source-tree correction — read before the file lists below

The plan item names `iFly/iFly/Sources/UI/Views/Skins/` as the port source. That tree is the Delta-skin *file-format* runtime (JSON `representations`, `mappingSize`, bundled PDF/PNG assets, `DeltaSkinTraits` lookup). iCube has no skin files and gains no skin-import feature here — nothing in that format concept transfers.

The feature we actually want — programmatic (no asset file), draggable, per-orientation, reset-able, normalized persistence — already exists one directory over, backing iFly's Dreamcast/arcade overlay: `iFly/iFly/Sources/UI/Views/Controller/`. That is the real port target:

| iFly file | What it is | Port as-is? |
|---|---|---|
| `ButtonLayoutEngine.swift` | Pure geometry: box, clamp-to-bounds, resolve-drag | Yes, verbatim (rename types) |
| `ButtonLayoutStore.swift` | Per-class × orientation normalized-center store, `ObservableObject` | Port logic; swap backing store (§2.3) |
| `VCOLayoutEditor.swift` (`PositionedControlGroup`) | Draggable wrapper: dashed chrome, drag gesture, commit-on-release | Yes, near-verbatim |
| `ConsoleOverlayLayout.swift` | Single-source-of-truth default geometry (pure function) | Pattern, not the numbers |
| `Skins/Views/MultiTouchView.swift` | Raw `UIViewRepresentable` over `touchesBegan/Moved/Ended/Cancelled`, multi-touch on | Yes, verbatim — the one file worth taking from `Skins/` |
| `Controller/VCOPressGestures.swift` (`MultiTouchCluster`) | Union-of-hit-regions-across-live-touches, fires deltas only | Yes, near-verbatim — the slide-between-buttons primitive |
| `VirtualControllerOverlay.swift` | Concrete Dreamcast/arcade assembly | Pattern only — button set/shapes differ |
| `ControllerArtKit.swift`, `VCOFaceButtons/DPad/Joystick.swift` | Glossy gradient+shadow rendering | Pattern for §5, not literal code |
| `Skins/Models/*`, `DeltaSkinLoader`, `.deltaskin` parsing | Skin-file format | **Skip entirely** |
| `Skins/Views/DeltaSkinView+Touch.swift` | Skin-model touch handling, superseded by `MultiTouchCluster` | **Skip** — reference only for D-pad angle math |
| `EmulationView+Overlays.swift` | flycast Done/Reset chrome placement | Pattern for chrome only (§4) |

Everything below assumes the `Controller/` tree as the port source.

## 1. Goals / non-goals

**Goals**
- Replace the four xib pads (`TCGameCubePad`, `TCWiiPad`, `TCSidewaysWiiPad`, `TCClassicWiiPad`) with a SwiftUI-rendered, UIKit-touch-driven overlay.
- Per-control-group dragging with reset-to-default, persisted per pad kind and orientation — no per-control resizing in v1.
- Preserve the input contract byte-for-byte: same `TCManagerInterface` entry points, same `TCButtonType` ids, same controller-id resolution, same DSU mirroring, same IR mode semantics.
- GameCube purple/indigo styling with real button shapes; Wii white/light-grey with a blue glow. Gradient + shadow, not flat PNG fills.
- Settings for style, opacity (reuse existing), and a new Wii IR touch-pad area rectangle (C9).

**Non-goals**
- No Delta-skin file import/export.
- No per-control resize handles — groups move as a fixed-size unit (per-group *scale* is a plausible v2, not here).
- No per-game layout override in v1 (extension point documented in §2.3).
- No change to `TCDeviceMotion`'s gyro/accel pipeline — gyro-mode IR keeps working exactly as today; the new overlay only replaces the touch-driven follow/drag IR path.
- No tvOS on-screen controls — stays `#if os(iOS)` end to end.
- Button-remap UI (plan item C7) is a separate spec.

## 2. Layout model

### 2.1 Pad kinds and groups

iCube needs more variants than iFly's two (`arcade`/`dreamcast`): `EmulationScreen+TouchAndMotion.swift`'s `makeWiiPadView()` already switches between three Wii view classes from live device state (`DOLWiimoteBridge.isClassicActive`/`isSideways`). Model as `TouchOverlayPadKind: gameCube, wiiRemote, wiiRemoteSideways, wiiClassic` (the last covers Wiimote + Classic Controller together, matching `TCClassicWiiPad`).

One flat `TouchOverlayGroup` enum (mirrors `ControlGroup`), a superset across pad kinds; each pad kind instantiates only the subset it needs: GC — `gcDpad, gcMainStick, gcCStick, gcFaceButtons, gcTriggers, gcStartZ`; Wii — `wiiDpad, wiiAB, wiiOneTwo, wiiMinusPlusHome, wiiIRPad`; Nunchuk (when the extension is active) — `nunchukStick, nunchukCZ`; Classic (when active) — `classicDpad, classicLeftStick, classicRightStick, classicFaceButtons, classicTriggers, classicMinusPlusHome`.

`wiiIRPad` is a group like any other for *editing-mode drag* (movable and resizable as a rectangle, §7), but at runtime it isn't a button — it's the drag/follow touch surface ported from `TCWiiPad.handleLongPress`.

### 2.2 Geometry (`TouchOverlayLayoutEngine`, port of `ButtonLayoutEngine`)

Verbatim port of `box`, `clampCenter`, `resolve` (free placement, clamped on-screen only — iFly deliberately dropped grid-snap/overlap-rejection because it fought the user's finger; keep that call). Pure `CoreGraphics`, no UIKit/SwiftUI — unit-testable the same way `TCDeviceMotion`'s mapping statics already are (`internal`, not `private`, so `DolphiniOSTests` reaches them via `@testable import`).

### 2.3 Persistence and "migration from nothing"

iFly uses raw `UserDefaults` blobs keyed `"iFly.buttonLayout.<skin>.<orientation>"`. iCube already has a JSON file for this class of setting — `GameProfiles.swift`'s `<UserFolder>/Profiles/game_profiles.json`, which already carries `touchOpacity`/`wiimoteTouchIRMode`. Follow that convention:

- New file `touch_overlay_layout.json` in the same `Profiles/` directory, global (not per-game) in v1: top-level key `"<TouchOverlayPadKind>.<portrait|landscape>"` → `{group: [x, y]}`, normalized 0-1 of the overlay's own bounds (survives device/orientation changes — re-read through the *current* geometry each time).
- `TouchOverlayLayoutStore` (new `@MainActor final class ... ObservableObject`, `.shared`): `normalizedCenter(for:padKind:orientation:)`, `setNormalizedCenter(...)`, `reset(padKind:)`, published `revision: Int` — same shape as `ButtonLayoutStore`, backed by the JSON file instead of `UserDefaults`.
- **Migration from nothing**: no existing state to migrate — xibs hardcode frames, never user-editable. The migration story is that `TouchOverlayDefaults`'s computed defaults must reproduce today's xib layout closely enough that upgraders see no jump: phase 1 extracts the frame rects out of the four `.xib` files (plain XML `<rect>` elements) into a pure function keyed by pad kind × orientation, the same relationship `ConsoleOverlayLayout` has to `VirtualControllerOverlay.consoleLayout`. A missing store key falls back to this default, so `reset(padKind:)` and a fresh install both render identically to the pre-overlay build.
- Per-game override: **not built in v1**. If added later, the natural home is an optional field on `GameProfile` (`touchOverlayLayoutOverride: [String: [Double]]?`, nil-means-absent, same pattern as `excludedFromNearbySharing`), consulted before the global file.

### 2.4 Size classes

Not modeled separately in v1. `clampCenter` already re-clamps a stored normalized center against whatever `bounds` the current geometry produces, so iPad vs iPhone degrades to "same relative position, re-clamped on-screen," matching iFly. Extend the key with a size-class suffix later if iPad-specific defaults prove necessary; not needed to ship v1.

## 3. Rendering approach

**SwiftUI for drawing, raw UIKit touch for input** — iFly's shipped architecture, already proven at this frame budget.

- Overlay root: `GeometryReader` + `ZStack` of `PositionedTouchGroup` (port of `PositionedControlGroup`), as in `VirtualControllerOverlay.consoleLayout`/`arcadeLayout`. SwiftUI does layout math and drag-chrome visuals only, not live touch dispatch.
- Button/D-pad/stick dispatch goes through `MultiTouchView` (raw `touchesBegan/Moved/Ended/Cancelled`, multi-touch on) wrapped by `MultiTouchCluster<ID>`, which recomputes the **union** of hit-tested regions across all live touches every event and fires only the delta (newly pressed/released). That's what gives free multi-touch (hold D-pad + press a face button) and slide-between-buttons without SwiftUI `DragGesture`'s single-view binding problem — the same reason today's `TCJoystick`/`TCDirectionalPad` use `UIPanGestureRecognizer`/`UILongPressGestureRecognizer` and `TCWiiPad` needs `shouldRecognizeSimultaneouslyWith` overrides to avoid starving siblings. `MultiTouchCluster` replaces all of that with one mechanism per group.
- 60 fps: synchronous `touchesBegan/Moved/Ended` (no gesture state-machine latency); `TCManagerInterface` writes are a cheap `std::map` write, read once per emulated frame. The perf trap already paid for once, in `DeltaSkinView+Touch.handleDPadInput`'s history: firing haptics/highlight/sound on *every* touch-move inside a held direction tanked FPS (each one re-ran a CoreImage blur/bloom pass). Port the fix, not the bug: feedback fires only on a state transition, never on every move sample inside an already-pressed region. `MultiTouchCluster`'s delta-only `onChange` enforces this at the API level.
- D-pad diagonals/dead zones: port the angle/dead-zone bucketing from `DeltaSkinView+Touch.handleDPadInput` into the new D-pad's `hitTest` closure (check `VCODPad.swift` first for an already-`MultiTouchCluster`-native version to copy directly instead).
- Haptics: `UIImpactFeedbackGenerator`, same as today's `TCButton.hapticGenerator`. iFly's `HapticsPrefs.scaled(...)` (global intensity setting) is a nice-to-have, not required for parity — check whether iCube already has an equivalent key before adding a second one.

## 4. Editing mode UX

Port `PositionedControlGroup`'s behavior directly:

- Entered from a pause-menu / Controllers-settings "Edit Layout" row, gated by an eligibility check analogous to `VirtualControllerOverlayEligibility.canEditButtonLayout` — reuse `ControllerManager.shared.shouldShowGCPad`/`shouldShowWiiOverlay` rather than inventing a parallel check.
- While editing: each group's own input is suppressed (`allowsHitTesting(!isEditing)`), a dashed accent outline + move-icon badge overlays it, and `DragGesture(minimumDistance: 0)` drives a live offset, committing via `TouchOverlayLayoutEngine.resolve` (clamp-only, no grid snap/overlap rejection) on release.
- Chrome: top-trailing "Reset"/"Done" capsule pair, as `buttonLayoutEditOverlay` does today. Reset clears the current pad kind's stored layout (both orientations); Done exits edit mode only (positions already persisted live per-drag). The game stays paused for the whole session, and edit-mode touches must not reach the emulator (mirrors `isEditingLayout`'s `inputSuppressed` gate, which also blocks a stray touch from tripping auto-resume).
- Per-game vs global: global only in v1 (§2.3).
- `wiiIRPad` is edited like any other group for *position*; its *size* is a separate Settings control (§7), not the drag-to-move editor — moving the IR pad's hit region and dragging inside it to aim are different gestures over the same area and must be mutually exclusive modes.

## 5. Styling direction

Both palettes render as gradient-fill + inner gloss + drop shadow (`ControllerArtKit`'s `GlossyButtonStyle` pattern), not flat PNG fills like today's `gcpad_a.imageset`. Scale factors carry over unchanged from `TCButtonType.getButtonScale()` (A = 0.33, B/Z/triggers = 0.6, X/Y = 0.5).

**GameCube — purple/indigo, real button shapes:**

| Group | Shape | Fill |
|---|---|---|
| A | large rounded square/circle, dead center | saturated green, gloss highlight |
| B | small circle, lower-left of A | saturated red |
| X, Y | kidney/bean shapes around A | cool grey / light indigo |
| Z | trapezoid, upper-right shoulder | dark grey |
| Start | small circle, top-center | white/light grey |
| Main/C-stick | octagonal gate ring (visual only, see note) | indigo base; purple gloss cap for C-stick |
| L/R triggers | rounded rectangle | dark indigo, analog-force fill (as `TCButton.touchesMoved` does) |
| Pad body | transparent — no backing plate over the game view | — |

Keep the octagonal gate **visual only**: `TCJoystick.handlePan`'s travel math is a plain circle (`maxDistance = frame.width / 3`). Changing the actual travel shape would change stick feel; don't couple cosmetic gate art to hit-test geometry (§9).

**Wii — white/light-grey, blue glow:**

| Group | Shape | Fill |
|---|---|---|
| A | large circle, front-and-center | white/light-grey, blue rim-glow instead of a color fill |
| B | trigger-shaped, underside | white/light-grey, same glow |
| 1, 2 | small circles | white/light-grey |
| −, +, Home | small pills | white/light-grey; Home gets a subtle red ring |
| D-pad | classic 4-way cross | white/light-grey |
| IR pad | translucent rounded-rect + crosshair reticle tracking last touch/gyro pos | low-opacity white fill, blue glow border |
| Nunchuk stick/C/Z | same octagonal-gate stick + two buttons | matches Wiimote palette |
| Classic groups | dual sticks, A/B/X/Y diamond, ZL/ZR | white/light-grey, blue glow |

Both palettes reuse `ControllerArtKit`'s `.shadow(color: c.opacity(0.55), radius: 6, x: 0, y: 0)` glow technique with a swapped color, rather than a new shadow system.

## 6. Input contract — preserve exactly, do not "clean up"

Load-bearing section. Every write from the new overlay must go through the same two entry points the xib pads use, with the same ids, or `Data/Sys/Profiles/{GCPad,Wiimote}/Touchscreen.ini` stops matching and every binding silently breaks.

### 6.1 The only two calls allowed

`TCManagerInterface.setButtonStateFor(_:controller:state:)` and `.setAxisValueFor(_:controller:value:)` (`TCManagerInterface.h`/`.mm`). **Never call `ciface::iOS::StateManager` directly.** `TCManagerInterface.mm` also owns DSU mirroring (button→shape mapping, split-axis aggregation, D-Pad→analog dpad, IR→touch coords, gyro/accel→motion) — as long as the overlay only calls these two methods with the ids below, **DSU support needs zero new code.** C9's "pass over the DSU controller code" line means "verify the new call sites are these two methods and nothing else," not new mirroring logic.

### 6.2 `TCButtonType` ids (unchanged)

GC: A=0 B=1 Start=2 X=3 Y=4 Z=5, D-pad=6-9, main-stick axes 11-14, C-stick axes 16-19, triggers L/R=20/21 (analog). Wii: A=100 B=101 −=102 +=103 Home=104 1=105 2=106, D-pad=107-110, IR axes=112-115 (Fwd/Back=116/117, Hide=118), Shake=132-134, IMU accel=625-630, IMU gyro=631-636. Nunchuk: C=200 Z=201, stick axes=203-206. Classic: buttons 300-308, D-pad 309-312, sticks from 313/318. Full table: `TCButtonType.swift:8-128`. The new group views reference these raw ints exactly as `TCButton`/`TCJoystick`/`TCDirectionalPad` do — import `TCButtonType`, don't invent a parallel enum.

### 6.3 Controller id vs. player slot — do not confuse these

- `ControllerManager.shared.touchscreenControllerId(isWii:)` → the *Touchscreen device id* (`StateManager` index: GC 0-3, Wii 4-7). Goes in `TCManagerInterface`'s `controllerId:` and `TCDeviceMotion.setPort(_:)`.
- `ControllerManager.shared.touchscreenSlot(system:)` → the 0-based *player slot*. Decides which pad *variant* to show — `makeWiiPadView()` reads `isClassicActive`/`isSideways` keyed by this slot, not the device id.

`TouchOverlayView` needs both: slot to pick `TouchOverlayPadKind`, device id as `controllerId` on every `TCManagerInterface` call. Name the parameters unambiguously (`deviceId`/`playerSlot`, never a bare `port` for both) — this exact mix-up produced the dead-touchpad bug the audit already tracks.

### 6.4 Two incompatible half-axis write conventions — a live trap

Three subsystems write "signed value across two half-axis ids" with **opposite** conventions. Normalizing them into one helper silently breaks either the profile mapping or DSU aggregation.

- **Sticks** (`TCJoystick.handlePan`): sends `[min(y,0), min(y,1), min(x,0), min(x,1)]` to four consecutive ids — "up" writes negative to Up and 0 to Down; "down" writes positive to Down and 0 to Up. `TCManagerInterface.mm`'s `combUD`/`combLR` exist specifically to compensate for this asymmetry when re-deriving a signed DSU axis. Port bit-for-bit; it's a pure function and a good unit-test target.
- **Wii IR** (`TCWiiPad.sendIR`): writes the **same** value to both halves — `[y, y, x, x]` across 112-115 — and `TCDeviceMotion.handleIRCursorMapping` (gyro mode) does the same independently. This is IR-specific; do not "fix" it to look like the stick convention.
- **IMU accel/gyro** (`TCDeviceMotion.imuAccelWrites`/`imuGyroWrites`): writes the signed value to the `m_neg == +1` side and literal 0 to the other (`TCDeviceMotion.swift:420-464`; the core computes `x = Left - Right`, so writing both sides the IR way doubles it, writing ±v cancels to 0). Untouched by this port — recognize it as deliberately different, not inconsistent code to unify.

### 6.5 IR: two independent rectangles

- **Game content rect** (`TCWiiPad.recalculatePointerValues`/`gameRectLocal`): the letterboxed video rect used to normalize a touch to [-1,1]. Computational only, never user-visible.
- **IR touch-pad area** (C9, new): the rectangle within the overlay where drag/follow gestures are recognized at all — today implicitly "the whole pad view minus `viewIsInsideControl` regions" (`TCWiiPad.gestureRecognizer(shouldReceive:)`). C9 makes this rectangle explicit and user-resizable, stored like a group position but rendered as a translucent region. Preserve the exclusion rule: a touch starting inside any other group must not start an IR drag (port `viewIsInsideControl`'s superview walk).

### 6.6 Mode semantics to preserve

`TCWiiTouchIRMode` (`none=0`/`follow=1`/`drag=2`) is distinct from the Settings-facing `TouchIRMode` (`gyro=0`/`follow=1`/`drag=2`, `ControllersRootView.swift`) — when the setting is `gyro`, the pad-level mode is `.none` (`EmulationScreen+TouchAndMotion.swift:301`), because gyro-mode IR is driven entirely by `TCDeviceMotion.handleIRCursorMapping`, not touch. `TouchOverlayIRPad` only ever handles `follow`/`drag`; `.none` renders it inert/hidden and lets `TCDeviceMotion` keep working unchanged. Do not route gyro mode through the new IR pad view.

## 7. Settings / menus (C9)

Additions to `ControllersRootView.swift` (opacity/IR-mode already live at `:336-350`, `:560-571`):

- **Style**: picker between the §5 palette and a "classic" (today's flat raster) fallback — a cheap escape hatch, mirrors `Defaults[.useLegacyRetroArchWrapper]`'s opt-out pattern.
- **Opacity**: already exists (`DOLConfigBridge.mainTouchPadOpacity`/`setMainTouchPadOpacity`) — reuse the same bridge key.
- **IR touch-pad area**: new "Edit IR Area" mode (separate from the layout editor, §4), a resizable rect with corner/edge handles; persisted under a reserved `wiiIRPad` key storing `[x, y, w, h]` normalized — the one group needing a size dimension, not just position.
- **Pointer sensitivity**: already exists via enhanced-motion settings (`EnhancedMotionControlsView.swift`/`MotionDebugView.swift`) — no new setting; don't introduce a second, divergent sensitivity constant in the new IR pad's drag math (today's has none either).
- **Edit Layout entry point**: a row in Controllers settings and (phase 3) the pause menu, gated per §4.

## 8. Phased implementation plan

### Phase 1 — model, persistence, defaults extraction, tests (no device; sonnet-suitable)

New directory `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/`, parallel to `TouchController/` so the old pads keep working until phase 3:
- `TouchOverlayGroup.swift` (§2.1), `TouchOverlayLayoutEngine.swift` (§2.2), `TouchOverlayLayoutStore.swift` (§2.3), `TouchOverlayDefaults.swift` (default `[group: (size, center)]` per pad kind × orientation, extracted from the four `.xib` frame rects — mechanical XML + arithmetic, no UI).
- Unit tests: geometry (`clampCenter`, `resolve`), store round-trip (set/read/reset), and the §6.4 split-axis stick function against known input/output pairs.

Sonnet can do all of this mechanically — pure Swift/Foundation, verifiable via `swift test` if the target is Tier-0/2-buildable, or an Xcode test scheme otherwise.

### Phase 2 — rendering + editing behind a feature flag (mechanical port + simulator; final feel needs a person)

- `TouchOverlayView.swift` (`GeometryReader` root, `ZStack` of `PositionedTouchGroup`, switching content by pad kind — port of `VirtualControllerOverlay.body`/`consoleLayout`/`arcadeLayout`).
- `PositionedTouchGroup.swift` (port of `PositionedControlGroup`, §4). `TouchOverlayMultiTouch.swift` (port of `MultiTouchView` + `MultiTouchCluster`, §3).
- Group content views: `TouchOverlayDPad/Joystick/FaceButtonsGC/FaceButtonsWii/Triggers/IRPad/ClassicGroups.swift`. `TouchOverlayArt.swift` (§5 shapes/gradients/glow, patterned on `ControllerArtKit`).
- Feature flag: UserDefaults bool (e.g. `touch_overlay_programmatic_enabled`) in Settings > Advanced, default **off**. `TouchPadsContainer` (`EmulationScreen+TouchAndMotion.swift`) branches on it, everything else in that file (port resolution, alpha, IR mode passthrough) unchanged.
- Verification at this phase is visual/layout only (simulator screenshots, mouse-as-touch drag for the editor) — no requirement that presses reach a running game yet.

Sonnet-suitable: the mechanical view ports and art. Needs a person: judging whether drag feel and art actually look right — simulator screenshots at minimum; the phone for force-touch trigger behavior, which has no simulator equivalent.

### Phase 3 — wiring, IR, settings, xib removal (main session + phone)

- Wire `TouchOverlayView` to `TCManagerInterface` per §6 (device id from `touchscreenControllerId(isWii:)`, slot from `touchscreenSlot(system:)` for pad-kind selection).
- `TouchOverlayIRPad`: port `TCWiiPad.handleLongPress`/`normalizedFromPoint`/`sendIR` (§6.5), respecting the `.none`/gyro bypass (§6.6) and the IR-area rect from Settings.
- Add C9's settings rows (§7) and the "Edit Layout" entry, gated per §4.
- **Device verification checklist** (not simulator-testable): GameCube every button + both sticks + both triggers in-game; Wii vertical/sideways/Classic+Nunchuk variants each register correctly per `makeWiiPadView`'s selection; IR drag/follow/gyro handoff with no stuck pointer across a mode switch (`setTouchIRMode`'s `centerPointer()` is the existing safeguard); multi-touch hold-D-pad-while-pressing-a-face-button and slide-between-two-face-buttons; DSU client still receives GC/Wii state unchanged (should need zero new code — verify it wasn't accidentally bypassed); pause-menu-open and disconnect flows don't leave touches stuck down (`MultiTouchCluster.releaseAll()` on `onDisappear` is the mechanism).
- Only after passing on-device for a build or two: flip the flag's default on, then delete the xib path — `TCGameCubePad.swift/.xib`, `TCWiiPad.xib`, `TCSidewaysWiiPad.xib`, `TCClassicWiiPad.xib`, `TCView`, `TCButton`, `TCJoystick`, `TCDirectionalPad`, the Wii pad subclasses' nib-loading path. **Keep**: `TCButtonType.swift` (canonical id table), `TCManagerInterface.h`/`.mm` (unchanged contract), `TCDeviceMotion.swift` (unchanged pipeline), `TCWiiTouchIRMode.swift` (shared mode enum).

## 9. Risks / open questions

- **DSU controller-id clamp**: `TCManagerInterface.mm`'s DSU arrays are `[4][256]`, clamping `controllerId` to 0-3, so Wii ids 4-7 already collapse onto DSU slot 3 today. Pre-existing, not a regression of this port, not in scope to fix here.
- **Octagonal gate vs. circular travel math**: keep the gate cosmetic-only (§5) unless a follow-up explicitly asks to change stick feel — that needs its own device A/B.
- **IR-area edit vs. layout edit**: two drag UIs over the same region; confirm in phase 3 that entering one visibly disables the other.
- **Per-game layout override**: deferred; storage extension point documented (§2.3) so it isn't a redesign later.
- **"Classic" style fallback**: one more render path to maintain until the programmatic renderer earns a release cycle of device confidence — plan to retire it once established.
- **Standalone testability**: confirm `TouchOverlayLayoutEngine`/`Store`/`Defaults` can build under `swift test` (Tier 0-2 style) rather than only an Xcode test scheme — affects how cheaply phase 1 runs in CI.
- **Haptics intensity setting**: only port `HapticsPrefs`-style scaling if iCube lacks an equivalent key already; don't add a second one.
