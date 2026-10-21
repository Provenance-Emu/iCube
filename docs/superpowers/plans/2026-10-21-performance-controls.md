# Performance and pause-state lifecycle implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development task by task. Root serializes SDK/native builds and integration; isolated workers own disjoint source files.

**Goal:** Fix Quick Save/Load dismissal and intentional resume, then implement the approved paused and live Performance controls.

**Architecture:** Retain PauseArbiter ownership across state operations and surface dismissal. Extract one performance snapshot/controller/model used by Pause, iOS and a remote-only live panel. A native per-controller suppression lease prevents remote gameplay leakage while the live panel keeps the gamepad and game running.

**Tech Stack:** Swift/SwiftUI/XCTest, Objective-C++, C++ atomic/shared ownership, GameController, existing Debug simulator and reusable JSON UI harness.

**Spec:** ../specs/2026-10-21-performance-controls-design.md, approved by owner. New owner report: Quick Save/Load must immediately close Pause, leave the game paused until fresh user input, and never reopen from the closing Back release. If a load cannot finish without an advancing frame, defer it until resume input.

**Implementation status:** source review and simulator acceptance complete; see [verification evidence](../../app-store/release-evidence/2026-10-21-performance-controls.md). Physical/gameplay gates below remain deferred. Git history records source delivery.

## Global constraints

- Preserve concurrent locale source/generated-engine changes. No parent checkout/index mutations. No physical device control until owner renews the deferred window.
- Keep production app, games and saves untouched. Tests use DEV/disposable fixtures. Never overwrite a slot without existing destination-specific consent.
- Live Performance takes no pause token; normal Pause stays paused. CPU Engine remains next-launch. Resolution0 reads Fit Window; no dynamic-resolution controller returns.
- TV remote preference: Pause Menu default, Live Performance opt-in; no gameplay pad falls back to Pause. Last-pad disconnect adopts existing disconnect pause before closing Live.
- Single native build lane; focused tests/captures use cached runner. Rebuild engine only for native gate changes; label stale/pinned engine results accurately.

## Review focus

- Closing Menu release cannot reopen Pause through a GC/UIPress duplicate; press origin must survive dismissal.
- State I/O admitted by a menu remains valid after intentional dismissal but cannot affect another game/session.
- Early/held resume input cannot expose running frames before a queued load completes; unrelated pause reasons survive.
- Remote suppression covers axes/buttons/motion and device refresh, does not gate the gameplay pad, and remains until neutral after closing.
- Gamepad input never navigates Live; background/disconnect/Live-to-Pause transfers ownership without releasing another pause.

### Task0: Quick state action handoff and Back release ownership

**Files:** QuickSaveMenuActions.swift; new QuickStateHandoff.swift; PauseArbiter.swift; PauseMenuView.swift; EmulationScreen.swift; Controllers/PauseGestureTracker.swift; Emulation/TVEmulationBridge.h/.mm; EmuEventVC.m as required. Tests: QuickSaveMenuRoutingTests, new QuickStateHandoffTests, PauseArbiterTests, gesture routing regressions.

**Interfaces:** A session-bound handoff owns an operation token and an awaiting-input user hold, dismisses once at admission, survives the menu's disappearance, and releases only its operation token after completion. New native checked-load completion reports queue completion, not just admission. Preserve public existing load APIs for other callers. Fresh resume admission is fenced until completion and all opening controls release.

- [x] Write failing production-seam tests: admitted save/load closes once immediately; closed surface does not cancel its own task; new session cancels; early input cannot resume; completed action stays paused; fresh input resumes only user hold; classic overwrite still asks consent.
- [x] Prove current implementation fails targeted tests; fix handoff and native completion without adding a running frame. Add actual origin-aware Menu press suppression for closing overlays, tested across GC/UIPress ordering.
- [x] Root builds both simulator apps, iOS unit products and the tvOS UI runner, runs focused state/pause tests and fixture navigation. Review source/native queue semantics; record exact runtime limits.

### Task1: Shared performance controls and Pause pane

**Files:** new Common/Swift/Performance/PerformanceControlsState.swift, PerformanceControlsController.swift, PerformanceControlsModelBuilder.swift; PauseMenuView.swift; EmulationScreen.swift; new PerformanceControlsTests.swift; existing PauseMenuModelBuilderTests.

**Interfaces:** Snapshot of Base values + Game/Auto provenance and live HUD/AdaptiveClock/VI Skip; typed PerformanceControlChange actions invoke existing writers. MenuModel builder uses explicit choice panels for multi-values. One controller refresh method is used on every open.

- [x] Failing tests assert full control coverage, Base/effective separation, disabled reason, fresh adaptive/VI values, scaling0 Fit Window and existing CPU1–400% range.
- [x] Implement shared state/actions and reuse in iOS popover, full TV Pause pane; change primaryIDs to resume/perf-hud/reset/exit. Place save-states directly after quick-save/quick-load. Keep CPU Engine separate and next-launch.
- [x] Root focused model/arbiter tests and simulator full-pane capture; independent review. No physical acceptance claim.

### Task2: Per-controller native suppression lease

**Files:** new InputCommon/ControllerInterface/iOS/ControllerInputGate.h; MFiController.h/.mm; scanner disconnect cleanup if needed; new app Bridging/DOLControllerInputLease.h/.mm plus BridgingHeader.h; new standalone pure C++ gate tests and Objective-C++ backend seam tests.

**Interfaces:** Opaque per-GCController acquisition/release with shared atomic gate state attached to every input object; bridge NSObject lease holds the exact controller identity and releases on lifecycle teardown. Multiple leases cannot release one another; backend polling reads neutral while suppressed. Pending-neutral release requires an explicit remote physical snapshot before final release.

- [x] Failing pure gate tests: two controllers isolated, nested leases, thread-safe reads, wrapper refresh retains gate, release until neutral, disconnect cleanup, motion neutral while owned.
- [x] Implement actual GetState gating for buttons, pressure, axes, accelerometer and gyro, without changing stored assignments. Add bridge and native API compile checks.
- [x] Root rebuilds the required simulator engine slices, verifies embedded binary UUIDs/hashes, then focused native tests. Review before Live integration; do not count a helper-only test as proof all input types use it.

### Task3: Live TV panel and preference/routing

**Files:** new Performance/TVLivePerformanceOverlay.swift, LivePerformanceSession.swift, RemotePerformanceNavigation.swift; Controller settings model/view; ControllerExtensions/PauseGestureTracker/EmuEventVC; EmulationScreen.swift. New tests for navigation, preference, gesture and ownership.

**Interfaces:** LivePerformanceSession consumes Task1 controller and Task2 exact remote lease. Remote navigation is pure, highlighted manually; normal gameplay focus trap stays active. Siri Remote polling never replaces gamepad handlers. Preference is installation-local, default Pause; explicit Live only with available gameplay pad.

- [x] Failing tests: preference default/restore/fallback; remote-only move/choices; opening-release fence; duplicated menu routes; Live open/close no pause/resume; Live-to-Pause pending claim; last-pad disconnect ownership and background cleanup.
- [x] Implement translucent bounded TV panel, choice list and clock adjustment, plus Pause action. Share backend actions with paused pane; preserve native Start/options semantics and exit hold.
- [x] Root simulator navigation/captures and both platform SDK checks. Actual simultaneous remote/gamepad/frame progression remains a hardware gate until authorized.

### Task4: Integrated verification and delivery

- [x] Full app unit suite and targeted ownership/menu/native-input regressions on final source, iOS/tvOS simulator builds with the actual required engine slices; artifacts inspected for correct engine identity.
- [x] Final independent whole-change review, fix important findings, and prepare owned source delivery. Update HANDOFF and evidence with hardware limitations and remaining release gates.
- [x] Retain library editing/sharing/iCube-Provenance convergence and settings non-default/reset/recovery work as the next release blockers. Do not silently mark those complete from host tests.
