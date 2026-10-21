# Fast device and simulator loop implementation plan

> **For agentic workers:** Use superpowers:executing-plans for root integration and scoped subagents for independent CLI implementation/review. Task requirements below come from the owner's explicit request to implement a faster workflow first.

**Goal:** Make ordinary iPhone/iPad/tvOS edit, run, focused test and capture work reuse existing products and runners, with measured timings; then resume library editing/sharing/sync blockers.

**Architecture:** A Python CLI wraps existing Xcode, XcodeGen and RocketSim. Persistent target registries, core provenance, DerivedData and test runner caches live under ignored build/dev-loop. Debug-only switches omit redundant localization regeneration and Sentry uploads; Release behavior stays intact. Reusable XCTest accepts bounded semantic actions/remote commands without rebuilding the runner for each navigation sequence.

**Tech stack:** Python3 stdlib, XCTest/Swift, xcodebuild/xctestrun, existing XcodeGen, RocketSim. No new dependencies.

## Constraints and decisions

- Native app/test build lane stays serialized. Dedicated simulators only during this work; physical iPad window remains deferred while owner tests.
- Never launch/install production com.joemattiello.iCube; development identifier is com.joemattiello.iCube-debug.
- Physical controls require explicit CLI opt-in. Device support can be prepared/command-validated without claiming runtime acceptance.
- Core reuse defaults to an accepted release baseline, matching clean current core trees and packaged hashes. Explicit --pin-core may scope to a selected platform/kind and reuse that exact accepted binary while excluding pending engine changes; evidence must say current-app/pinned-engine. Never replace another task’s engine binaries.
- Localization skip requires unchanged inputs since a successful regeneration. New/missing keys remain checked. Release must ignore fast flags.
- Prefer exact cached xctestrun test-without-building over workspace test commands; no package resolution or runner rebuild for unchanged test inputs.
- Existing installed app is never presented as new source without a recorded matching build/install; explicit existing-dev opt-in is separate.
- Keep real remote focus/assertions for acceptance. Screenshots/AX are checkpoints or failures, rather than every interaction.
- Do not weaken release/archive guards or repeat release packaging for a minor UI loop.

## Tasks

- [x] CLI and meaningful Python tests: target registry, provenance/cache invalidation, Debug build, install/launch, exact focused xctestrun, reusable UI suite, capture/inspect, timing evidence and physical guards.
- [x] Reusable FastInteractionTests: bounded JSON launch/activate/capture/remote/tap/type/assert actions, DEV-only, physical opt-in, failure evidence and timing; compile/run iOS and tvOS.
- [x] Debug-only redundant-phase guards and import-before-pip; test guards against Release bypass and changed localization input cases.
- [x] Measure warm build before/after, capture latency, repeated focused UI tests and harness cache reuse on dedicated iPhone/iPad/TV simulators. Measure an actual Swift edit/revert incremental rebuild. Record cold setup separately.
- [ ] Independent review, commit/push tooling and update HANDOFF with commands/timings/limits.
- [x] Run current library metadata/editing/mirror and continuity host checks:299 passed. Correct stale Swift PATH selection.
- [ ] Rendered editor acceptance through the new loop and multi-install/Provenance convergence remain open. Preserve static gaps rather than labeling file arrival or ROM transfer as complete metadata/save sync.

## Review focus

Core/source freshness; stale installed binaries; localization changes after baseline; physical access during owner testing; Release inadvertently honoring a Debug shortcut. Tests and real local runs must distinguish setup/build/test/capture time.

## Owner steering retained

After the faster loop, verify missing non-default indicators on BOTH platforms, add per-setting and per-group resets, and design undo/redo or named profiles around clear recovery from poor performance. Owner confirms both platforms on older build1792472425. Current iOS has no marker; tvOS only tiny opt-in dots. This augments rather than replaces library editing/sharing/sync release work.

## Baseline evidence

Warm cached tvOS Debug build: 45.687s, scripts17.338s, links3.154s (build/dev-loop-benchmark/warm-baseline.json/log). No Swift compile occurred. Prior full iOS suite2246 total:170.79s; focused TV suites56–71s for2 tests. These establish existing costs, not promised post-change timings.

## Additional Performance request

Owner requests a full paused Performance pane in the old SaveStates primary position, SaveStates beside QuickSave/Load, plus a transparent live Siri Remote panel. They prefer a user setting over unexplained remote/pad differences. Proposed default PauseMenu, opt-inLivePerformance, no-gameplay-controller fallbackPause. [Reviewed design](../specs/2026-10-21-performance-controls-design.md). Native audit requires actual per-device input suppression: playerIndex unset alone does not prevent emulated input. Preserve existing dynamic-resolution removal.
