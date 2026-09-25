# Programmatic touch overlay — phase 2 plan (rendering + editing behind a flag)

Follows phase 1 (model/persistence/defaults, already on `develop`). Spec:
`docs/superpowers/specs/2026-09-24-programmatic-touch-overlay-design.md` §3/§4/§5/§6/§8.

## Decisions

- **Input surface**: one `TouchOverlaySurface` (raw `UIViewRepresentable` over
  `touchesBegan/Moved/Ended/Cancelled`, `isMultipleTouchEnabled = true`), ported from iFly's
  `MultiTouchView`, hosted **per control group** (not one for the whole overlay). UIKit already
  routes each touch to the view under it, so per-group hosting gives cross-group multi-touch (hold
  D-pad + press a face button) for free, and keeps each group's hit-test/haptic logic local.
  - `TouchOverlayCluster<ID>` (port of `MultiTouchCluster`) recomputes the union of hit regions
    across every live touch and fires only the press/release delta — used by button clusters and
    the D-pad.
  - `TouchOverlaySingleTouch` is the stick's tracker: first-touch-wins, continuous location,
    `nil` on release (recenter). Not `DragGesture` — advisor call: the raw surface gives
    `touchesCancelled` release for free and won't fight the edit-mode long-press gesture placed on
    the same overlay.
- **Pure logic split out for tests**: `TouchOverlayHitTester` — region union/delta, and the D-pad's
  8-way angle + dead-zone + hysteresis bucketing, ported from iFly's `VCODPad.directions(at:in:
  previous:)` (the design names this file explicitly as the source, not `TCDirectionalPad`'s 3x3
  thirds-grid — the two are NOT equivalent; a test asserting they match would be testing the wrong
  thing, so the tests check the angle function's own behavior only).
- **Writes**: only through `TCManagerInterface.setButtonStateFor`/`setAxisValueFor` with
  `deviceId` (never `port`, never the player slot — the exact naming the design's §6.3 audit flags
  as a historical bug source). D-pad always resends all four states together (matches
  `TCDirectionalPad`, not a per-direction delta). Stick writes the four half-axes via
  `TouchOverlayInput.stickWrites` (already phase 1, ported bit-for-bit from `TCJoystick`). Buttons
  and axis-buttons haptic once on the press transition only (`UIImpactFeedbackGenerator(.medium)`,
  matching `TCButton`/`TCDirectionalPad`); the stick has **no** haptics (`TCJoystick` has none, and
  firing one per move sample would be the exact perf trap §3 warns about).
- **Axis-button phase-2 simplification (flagged, not hidden)**: `TCButton` with `isAxis` on a
  force-touch-capable device skips button-down entirely and drives the axis from touch force in
  `touchesMoved`. Phase 2 always writes 1.0 on press / 0.0 on release (binary), matching the
  non-3D-Touch path of `TCButton`. Force-sensitive triggers are an explicit **phase 3 gap**, listed
  below — a reviewer diffing this against `TCButton` should read it as scoped-out, not regressed.
- **`wiiIRPad` stays inert in phase 2** (design §2.1: "at runtime it isn't a button"). It renders a
  translucent region with `.allowsHitTesting(false)` and is drawn FIRST (bottom) in the ZStack.
  Two reasons found while implementing: (1) its placement is `.fill` — the whole overlay bounds —
  so if it accepted touches it would swallow every other group's input; (2)
  `TouchOverlayPlacement.resolvedSize(in:)` already ignores stored size for `.fill`, so neither
  its position nor a stored scale has any rendering effect today. It is therefore **excluded from
  the phase 2 drag/resize editor** — a full-bounds group has nowhere to move, and §7 puts its real
  (rect) editing in a dedicated phase 3 mode anyway. Phase 3 ports `TCWiiPad.handleLongPress`/
  `sendIR` onto it and gives it real position/size storage.
- **Per-group resize (task item 4)**: phase 1's store only ever wrote `[x, y]`. Extended
  backward-compatibly to an optional third element, `[x, y, scale]` — a 2-element entry (every
  phase-1 file, and any group the user has only moved) still reads scale `1.0`.
  `TouchOverlayLayoutStore.sizeScale(for:padKind:orientation:)` / `setSizeScale(...)` added;
  `resolvedBox` multiplies the default size by the stored scale BEFORE clamping (so an enlarged
  group clamps against its own new footprint). Clamped to `0.5...2.0`
  (`TouchOverlayLayoutStore.scaleRange`). The editor exposes this as a small corner grip on every
  non-`.fill` group's edit chrome (`PositionedTouchGroup.resize`); button-cluster controls scale
  their local frames by the same factor so a resized group's buttons and hit regions grow together.
  Covered by new store tests (2-element entry reads scale 1.0; set/reload/read persists; a
  hand-written 3-element entry round-trips).
- **Editing mode**: long-press anywhere on the overlay (no settings-row entry point in phase 2 —
  that's phase 3 per the design's own phasing, §7 "Edit Layout entry point ... (phase 3)"). While
  editing: `PositionedTouchGroup` (port of iFly's `PositionedControlGroup`) shows dashed chrome +
  a move handle, `.allowsHitTesting(!isEditing)` on the live content, and — the one place the
  design doc doesn't spell out but the advisor call caught — **every group's own `pressed`/stick
  state is force-reset to empty/centered on the `isEditing` transition**, not just on
  `onDisappear`. Gating hit-testing alone doesn't release a control that was already down when
  edit mode opened; each `TouchOverlayButtonClusterView`/`TouchOverlayDPadView`/
  `TouchOverlayStickView` has its own `.onChange(of: isEditing)` that clears `pressed`/recenters
  and lets the existing `.onChange(of: pressed)` write path send the release for free. Reset (per
  pad kind, both orientations) and Done are a small top-trailing capsule pair.
- **Styling**: `TouchOverlayArt` — GC purple/indigo bodies with per-button shapes (`Circle` for
  A/B/1/2, a custom `KidneyShape` for X/Y, `TrapezoidShape` for Z/L/R/ZL/ZR, `Capsule` for Start/
  −/+/Home), Wii white/light-grey with a blue rim glow instead of a body tint. Gradients +
  `.shadow` only, no image assets, matching iFly's `ControllerArtKit` pattern. The stick's
  octagonal gate (`OctagonShape`) is cosmetic only — hit-test/travel math stays the existing
  circular `TouchOverlayInput.stickAxes` (design §5 explicit warning). Every control keeps its
  label (`TouchOverlayArt.label(for:)`, derived from the control id's suffix). Final visual
  polish (does it *feel* right on a real screen) is explicitly a person's call per the design
  doc — flagged as a phase 3 device-verification item, not claimed as finished here.
- **Feature flag**: `touch_overlay_programmatic` (task wins over the design doc's
  `touch_overlay_programmatic_enabled` naming), registered `false` in `DefaultPreferences.plist`,
  read via plain `UserDefaults.standard.bool(forKey:)` (matches every other ad-hoc flag in
  `ControllersRootView.swift`, e.g. `auto_touchpad_by_system` — no `Defaults[...]` wrapper exists
  in this repo). Toggle added to `ControllersRootView`'s existing `#if os(iOS)` "Alternate Input
  Sources" section, next to Opacity/Touch IR Pointer.
- **Mount point**: `TouchPadsContainer` (`EmulationScreen+TouchAndMotion.swift`) is a
  `UIViewRepresentable` that currently `addSubview`s either the Wii nib subtree or the loaded
  `TCGameCubePad` nib into its `host`/`uiView`. When the flag is on, it instead adds a
  `UIHostingController(rootView: TouchOverlayView(...))`'s `.view` as that subview — same
  container, same `alpha`/`autoresizingMask` handling, so `EmulationScreen.swift`'s call site
  (`TouchPadsContainer(forceVisible:isWii:irMode:)`) and its `.onAppear` motion wiring are
  untouched. Pad-kind selection reuses `makeWiiPadView()`'s exact inputs: `slot =
  ControllerManager.shared.touchscreenSlot(system: .wii) ?? 0`,
  `DOLWiimoteBridge.isClassicActive(forWiimote: slot)`, `.isSideways(forWiimote: slot)` — GameCube
  when `shouldShowGameCubePad()`. `deviceId` = `ControllerManager.shared
  .touchscreenControllerId(isWii:)`. Opacity: `max(0.2, CGFloat(DOLConfigBridge
  .mainTouchPadOpacity()))`, read live via `TouchOverlayView`'s own `.onReceive`/timer is
  overkill for phase 2 — reused directly as a `let` computed each `body` evaluation, consistent
  with how `TouchPadsContainer.updateUIView` already re-reads it every call. A `Coordinator`
  holds the `UIHostingController` so `updateUIView` can update its `rootView` in place (pad-kind
  can change live, e.g. Classic Controller connect/disconnect) rather than tearing down the whole
  hosting controller.
- **tvOS**: every new `TouchOverlay*.swift` file is `#if os(iOS)` end-to-end (no new tvOS surface
  at all). The only files touched that compile for tvOS are `EmulationScreen+TouchAndMotion.swift`
  (already `#if os(iOS)` wrapped whole-file), `ControllersRootView.swift` (new Toggle placed inside
  its existing `#if os(iOS)` block, no new guard needed), and `DefaultPreferences.plist` (not
  compiled). tvOS gate is therefore mostly a "did I break the shared files" check, not a check on
  new code.

## Files

New (`Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/`, all `#if os(iOS)`):
- `TouchOverlayHitTester.swift` — pure region union/delta + D-pad angle bucketing.
- `TouchOverlayTouchSurface.swift` — raw UIKit surface, `TouchOverlayCluster`, `TouchOverlaySingleTouch`.
- `TouchOverlayArt.swift` — GC/Wii palettes, button/D-pad/stick/IR-pad art, shared shapes.
- `TouchOverlayGroupViews.swift` — button cluster / D-pad / stick / IR pad content views.
- `PositionedTouchGroup.swift` — drag + resize editor chrome (port of `PositionedControlGroup`).
- `TouchOverlayView.swift` — `GeometryReader` root, per-pad-kind group assembly, edit toolbar.

Changed:
- `TouchOverlayLayoutStore.swift` — `[x,y,scale]` schema, `sizeScale`/`setSizeScale`.
- `DolphiniOSTests/TouchOverlayLayoutTests.swift` — hit-tester union/delta + D-pad bucketing tests,
  store scale round-trip tests.
- `Source/iOS/App/Project/Assets/DefaultPreferences.plist` — `touch_overlay_programmatic` = false.
- `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift` — beta Toggle.
- `Source/iOS/App/Common/Swift/EmulationScreen+TouchAndMotion.swift` — flag branch in
  `TouchPadsContainer`.

## What's explicitly NOT in phase 2 (left for phase 3, per §8)

- Wii IR drag/follow — the pad is inert; no `TCWiiPad` port yet.
- Force-sensitive analog triggers (axis-button is binary 1.0/0.0 in phase 2).
- Settings rows for Style picker / IR-area rect editor / "Edit Layout" nav entry (§7) — only the
  beta on/off Toggle ships now; editing is reached by long-press.
- Flipping the flag's default on, or deleting any xib/TC* file.
- DSU verification on a running core (needs a device + a booted game).

## Commit plan

1. `feat(touch-overlay): add per-group size scale to the layout store` — store change + tests
   (buildable/testable independent of the rest).
2. `feat(touch-overlay): add pure hit-test and multi-touch surface primitives` —
   `TouchOverlayHitTester` + `TouchOverlayTouchSurface` + tests.
3. `feat(touch-overlay): add GC/Wii procedural art` — `TouchOverlayArt.swift`.
4. `feat(touch-overlay): add group content views and the layout editor chrome` —
   `TouchOverlayGroupViews.swift` + `PositionedTouchGroup.swift`.
5. `feat(touch-overlay): add the SwiftUI overlay root` — `TouchOverlayView.swift`.
6. `feat(touch-overlay): wire the programmatic overlay behind a feature flag` — plist + settings
   Toggle + `TouchPadsContainer` branch.

Each commit gated with the iOS build; a combined iOS + tvOS gate after commit 6 (the only commit
touching shared/tvOS-compiled files).
