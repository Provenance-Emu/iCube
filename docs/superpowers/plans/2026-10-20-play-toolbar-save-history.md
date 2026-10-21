# Play toolbar and save history implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved labeled play toolbar, clear thumbnail-based save/load browser, and safe rolling quick-save history.

**Architecture:** Keep core save format unchanged. Reuse the serialized, session-validated save facade and existing metadata/thumbnail/sync discovery; unique history files remain separate from classic slots and automatic resume. The iOS toolbar owns presentation while policy and save storage remain shared with tvOS.

**Tech Stack:** SwiftUI, Foundation, existing Objective-C++ bridge and packaged Dolphin core; Tuist/XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-play-toolbar-save-history-design.md`. The owner approved the interactive mockup and added compact iPhone/iPad portrait as a requirement. A fresh builder review found nothing important left to decide.

## Global constraints

- iOS/tvOS minimum 17; no core format change, no dependency updates, no full core rebuild.
- Standard-size toolbar at most 80pt excluding safe area; compact portrait uses one primary row. Minimum 44pt touch targets; accessibility sizes must not clip.
- History retains 10 unkept entries per game; kept, classic, automatic and foreign files are excluded from rotation.
- Quick Load chooses newest manual save, then automatic resume; incompatibility is surfaced, never silently replaced by an older choice.
- Preserve all existing state files. No pruning before a newly committed state and metadata; no game/session identity drift.
- Serialize SDK builds/tests, preserve generated core symlinks and unrelated parent work. Land reviewed commits directly on develop, no PR.

## Review focus

- Incompatible newest manual save: display the incompatibility; do not load older or automatic content silently (Task 1).
- Disk/metadata failure after a state write: never prune a good older state, and report partial failure (Task 2).
- Same-title restart during a queued save: session identifier must reject the stale write/completion (Task 2).
- Narrow portrait, split width and accessibility text: no overlapping controls; browser actions reachable (Task 3).
- Modded boot, synced foreign files and legacy filenames: preserve content and avoid vanilla automatic fallback or destructive cleanup (Tasks 1–2).

---

### Task 1: History classification, selection and retention policy

**Files:** Create `Source/iOS/App/Common/Swift/QuickSaveHistoryPolicy.swift`; modify `SaveStateInfo.swift`, `SaveStateMetadata.swift`, `FilesystemSaveStateProvider.swift` in that directory; create `Source/iOS/App/DolphiniOSTests/QuickSaveHistoryPolicyTests.swift`.

**Interfaces:** Add `QuickSaveMode: String { case history, slots }`. Add defaulted `isQuickSave: Bool` and `isKept: Bool` to SaveStateInfo, and backward-compatible optional equivalents to metadata. Define `QuickLoadTarget` with `.manual(URL)`, `.automatic(URL)`, `.incompatible(URL)`, `.unavailable`. `QuickSaveHistoryPolicy.loadTarget(states: [SaveStateInfo], modded: Bool) -> QuickLoadTarget` selects latest manual by recorded/file date, deterministic path tie-break; modded disables implicit history/auto. `pruningCandidates(states: [SaveStateInfo], limit: Int = 10) -> [URL]` only returns validated, unkept history states beyond the newest 10. File naming is `{gameID}.quick-{UUID}.s01`; valid metadata must agree with game and history classification before pruning.

- [ ] Write tests asserting manual beats newer auto; legacy numbered manual is eligible; no saves is unavailable; newest incompatible is returned as incompatible; modded forbids auto/history; 12 ordinary history entries yield 2 oldest candidates; kept/classic/auto/foreign files yield none; equal dates sort deterministically; old metadata decodes with false flags.
- [ ] Run the pure policy tests before implementation and retain the expected failure output.
- [ ] Implement the types/policy, decode defaults and provider classification. Preserve existing initializers using defaulted new parameters and show foreign saves without marking them rotation-eligible.
- [ ] Run policy and existing FilesystemSaveStateProvider/metadata tests; all assertions pass and legacy parsing remains unchanged.
- [ ] Commit only this task's sources/tests.

### Task 2: Completed history writes and quick actions

**Files:** Modify `Source/iOS/App/Common/Emulation/TVEmulationBridge.h` / `.mm`, `Common/Swift/SaveStateService.swift`, `Common/Swift/TopBar/QuickSlot.swift`; create `Common/Swift/QuickSaveActions.swift`, `DolphiniOSTests/QuickSaveHistoryPersistenceTests.swift`. Existing mute work owns its separate runtime-volume changes in TVEmulationBridge.mm; coordinate edits.

**Interfaces:** Add a checked arbitrary-path snapshot bridge `saveStateSnapshotToPath:expectedGameID:expectedSessionIdentifier:` returning the existing TVSaveStateSnapshot or nil, validating paths under StateSaves and obtaining identity under the same guard as numbered snapshots. Reuse SaveAsWithResult. Add `SaveStateService.saveHistorySnapshotAsync(gameTitle: String?, expectedGameID: String, expectedSessionIdentifier: UInt64) async -> SaveStateCompletedSnapshot?` on the existing save queue. Add `QuickSaveActions.save(mode: QuickSaveMode, slot: Int)` and `load(mode: QuickSaveMode, slot: Int) async` on MainActor; classic delegates to QuickSlot, history uses policy/provider and honest outcomes. Keep writes/retention operations injectable for isolated filesystem failure tests; pinning updates only the selected metadata atomically.

- [ ] Add failure-first tests for successful unique-file+metadata creation; write and metadata failures retaining older entries; only-after-commit pruning; kept exclusions; cleanup error; changed game/session before write and before completion; modded classic fallback; traversal/outside-root rejection; no premature success toast.
- [ ] Run targeted tests against old behavior, retain failing evidence, then implement queue/bridge/store operations without a new C++ core API.
- [ ] Capture thumbnails through the existing session-aware pipeline; missing capture leaves a placeholder, not a failed state. Never reuse numbered slots or Continuity slot 99 as scratch storage.
- [ ] Verify StateSaves sync discovery accepts history `.s01`, JSON and PNG sidecars; add a filename-classification regression without claiming transport convergence.
- [ ] Run new persistence and existing save/session/quit tests. Confirm a failed history save does not rotate anything and a stale operation cannot write a new session.
- [ ] Commit only this task's reviewed changes.

### Task 3: Compact custom toolbar and save picker

**Files:** Modify `Source/iOS/App/Common/Swift/TopBar/EmulationTopBar.swift`, related TopBar style/model files, `EmulationScreen.swift`, `PauseMenuView.swift` as needed; create `Common/Swift/TopBar/QuickSavePickerView.swift`; update existing TopBar and save-picker tests plus `Common/UI/Localization/{en,ja}.lproj/Core.strings`.

**Interfaces:** `QuickSavePickerView(gameID: String, mode: Binding<QuickSaveMode>, selectedSlot: Binding<Int>, onDismiss: () -> Void)` uses existing provider/service and Task 1–2 types. Persist mode with key `quick_save_mode`; first-use default is history, explicit classic selection is retained. Opening it must acquire the existing presentation hold/pause ownership. Use stable path selection rather than provider-generated UUIDs across reloads.

- [ ] Add regressions for direct Pause destination, conditional actions still reachable, controls visibility under Controller, distinct Shaders label, save versus load purposes, empty/incompatible load disabled, selection without mutation, and occupied-slot overwrite confirmation.
- [ ] Replace icon-only chrome with token-based symbol/title buttons. Wide layout follows spec; compact layout uses Pause/Save/Load/Saves plus Options in one row, with an accessible Hide action. Move settings under labeled menus without losing playback, screenshot, performance, overscan, replay or portal controls.
- [ ] Implement the two-mode thumbnail browser with timestamps/occupancy, separate Save/Load actions, Keep, scrollable content and pinned footer. Do not present destructive action merely by selecting a card.
- [ ] Preserve toolbar auto-hide/holds/handoff, pause token transfer, pointer semantics and fresh toggle reads; cover dismissal and background transitions in existing tests.
- [ ] Regenerate via `/opt/homebrew/bin/tuist generate --no-open` once all new files exist, coordinating with the mute regression's C++23 test setting. Use the existing fresh package checkout cache; do not update pins.
- [ ] Run targeted toolbar, browser and save tests; design/localization checks pass without raising the lint ratchet.
- [ ] Commit the UI wave after screenshot review.

### Task 4: Rendered and physical acceptance

**Files:** Extend `Tools/release-audit/PhysicalRealGamePauseExitAuditTests.swift` to the new direct Pause route; add an external UI harness for toolbar/save-picker geometry and screenshots. Record evidence under `docs/app-store/release-evidence/`.

- [ ] Render iPhone portrait, iPad portrait, landscape and narrow split width. Assert standard toolbar height ≤80pt, primary controls ≥44pt, no overlap/offscreen labels, and visible picker Save/Load actions. Inspect screenshots; include large-text overflow and controller focus/Back checks.
- [ ] Run the physical real-game Exit/Cancel test on the owner's DEV iPad. Require independently checked ConfirmStop before tapping Exit, handle no-JIT/hidden toolbar, and never press Quit/Save & Quit/Reset. Record all 3 buttons visible/hittable and two Cancel/reopen cycles.
- [ ] Install the signed fixed DEV build while preserving app data; verify mute/unmute output with the hardware-free real-backend regression and owner audible check. A save/load smoke uses a disposable session/fixture, never overwriting the owner's existing states.
- [ ] Run the complete hosted suite once the integrated candidate is stable, then the required design/localization checks. Record exact totals and any remaining device gaps.
- [ ] Request an independent final review of product changes, resolve blockers and commit/push.

### Task 5: Both TestFlight uploads

**Files:** Existing release workflow/scripts; update `docs/HANDOFF.md` and release evidence. Do not upload the superseded frozen-checkpoint archives `1792538716` as though they contained mute/toolbar/history changes.

- [ ] Allocate one fresh candidate build number for both platforms, record its source commit, and archive iOS then tvOS with packaged validated cores and isolated Interface Builder helper environment.
- [ ] Run optimized SwiftUI metadata and retired adaptive-resolution guards, signature/version/platform checks, and matching app/core dSYM UUID checks. Upload symbols to Sentry.
- [ ] Export/upload both archives serially to App Store Connect app **6752685822**, bundle `com.joemattiello.iCube`; never use the Provenance app ID from the helper's defaults.
- [ ] Wait for both builds to reach VALID, assign the established TestFlight groups, add honest test notes and submit normal Beta App Review. Do not submit an App Store release.
- [ ] Record ASC build IDs/platform/status and source/test/device evidence. Report actual readiness, including any external Beta Review still pending.
