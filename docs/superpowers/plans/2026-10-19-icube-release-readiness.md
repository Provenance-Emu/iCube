# iCube release readiness implementation roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans after owner scope review, or superpowers:subagent-driven-development when delegation is explicitly selected. Track steps with checkboxes. This is a release-program roadmap; produce bounded implementation plans after the discovery tasks settle the remaining contracts. Do not invent APIs or treat proposed requirements as approved.

**Goal:** Deliver an accepted iPhone/iPad/Apple TV candidate with usable UI/settings, demonstrated sync and Provenance interoperability, and complete App Store submission material.

**Architecture:** Keep existing MenuKit/settings models, PVCloudSync/PVSyncRules user-data sync and PVContinuity library transfer. Validate Provenance's existing dialect support before extending it. Keep ROM transfer, preference sync and native-save ownership explicit; backend names and shared entitlements alone do not implement these behaviors.

**Tech Stack:** Swift/SwiftUI, ObjC++, C++, Tuist, XCTest, Swift packages, CloudKit, continuity library protocol, GitHub issues and App Store Connect.

**Spec:** [Canonical release scope and acceptance](../../app-store/RELEASE-PLAN.md).

## Global constraints

- All launch requirements and scope changes come from the canonical release document; unresolved choices remain proposed.
- Build/generated workspace belongs under `Source/iOS/App/`; do not commit generated Xcode projects or unrelated working files.
- Use APPSTORE artifacts for acceptance. Debug/simulator evidence cannot establish production CloudKit or distribution behavior.
- Preserve previously agreed runtime JIT detection; do not interpret issue #11's shorthand as authority to reverse the October 12 owner decision.
- Keep ROM bytes excluded from the existing user-data CloudKit classifier. Design a separate transport explicitly if automatic ROM mirroring is selected.
- Cross-app native-save writes need a ratified identity, compatibility and ownership contract; save states are not presumed portable.
- Do not expose credentials, trust grants or device-specific file paths through generic config sync.
- Subsystem changes require targeted tests, applicable iOS/tvOS builds and recorded manual device results. Coordinate expensive builds; no builds were run by the planning pass.

## Review focus

1. Apple TV purge/missing index must not become propagated deletes (R3 device/package tests).
2. Settings opened from pause must persist at the correct layer and return safely (R2 writeback/navigation tests).
3. Backgrounding the source during same-device import must not leave a silent failed HTTP fetch (R4 device tests).
4. Partial/corrupt/duplicate ROMs must never register as successfully imported (R4 transfer/import tests).
5. Data from another account/core/revision must not overwrite incompatible progress or credentials (R3/R4 compatibility tests).

## Task 1 — freeze scope and produce a baseline (R1–R6)

**Files:** create `docs/app-store/release-evidence/README.md`, `settings-matrix.md` and `interop-matrix.md` in that directory when execution begins. Read the canonical spec, October 16 settings audit, current submission checklist and Provenance's October 14 cross-app design including as-built sections.

**Produces:** approved scope, reproducible issue inventory, settings field/sync scope matrix, direction/transport matrix, candidate hardware/performance target and baseline failures. No new wire APIs are defined here.

- [ ] Resolve the canonical document's owner decisions; record choices and explicit deferrals in the tracker.
- [ ] Record checkout SHA, last distributed build and each defect's reproducible steps. Audit actual sources against old unchecked tasks.
- [ ] Inventory every settings leaf and data category. In the interop matrix enumerate same-device/cross-device, iOS/tvOS, sender/receiver and ROM/native-save/state/config separately; mark unknown cells unverified.
- [ ] Preflight simulator slices, generated workspace and host build load. From `Source/iOS/App`, run `make test` and record command, result and log; build failures are baseline blockers rather than reasons to mark old test counts current.
- [ ] Inspect actual CloudKit Production schema and signed candidate entitlements with account access. Record evidence without storing secrets. Do not mutate production schema as a discovery shortcut.
- [ ] Convert each confirmed gap into a bounded issue or implementation plan with exact owning files and regression tests. Link dependencies to the release tracker.

## Task 2 — repair tvOS and settings (R1/R2)

**Consumes:** approved UX requirements, reproductions and settings matrix from Task 1.
**Files:** MenuKit/library/pause and settings entry points listed in the canonical spec; tests under `Source/iOS/App/DolphiniOSTests/`. Do not redesign unaffected surfaces as a side effect.
**Produces:** independently verifiable fixes and updated UI evidence.

- [ ] Group confirmed defects by shared cause (focus/navigation, layout, persistence), so simultaneous work does not edit the same infrastructure blindly.
- [ ] For each defect, write a failing targeted regression where feasible; capture exact manual remote steps for behaviors unit tests cannot prove. Fix only the reproduction and test its boundary cases from R1/R2.
- [ ] Run the relevant app test suites using `make test TEST_ARGS="-only-testing:iCubeTests/<suite>"`; substitute real suite names from the change. Check touch, pad and remote behavior and in-game/end-game/relaunch persistence.
- [ ] Build both platforms and capture fresh light/dark screenshots. Run `Scripts/tvos_screens.sh --help` before choosing output/configuration flags; capture APPSTORE visibility separately from Debug previews.
- [ ] Obtain owner Apple TV and iPhone/iPad acceptance for the repaired journeys; attach evidence to the issue before closure.

## Task 3 — prove user-data safety and production sync (R3)

**Consumes:** category/preference matrix, available Production container and two or more distribution-signed devices.
**Files:** `Source/iOS/PVCloudSync/`, `Source/iOS/PVSyncRules/`, app coordinator/lifecycle and sync settings views. Tests live in the packages' existing `Tests/` trees and app tests.
**Produces:** category convergence results, conflict/purge recovery evidence and safe data exclusions.

- [ ] Run `swift test --package-path Source/iOS/PVSyncRules` and `swift test --package-path Source/iOS/PVCloudSync` from the repository root. Log current results; fix test/build failures before assuming prior package behavior.
- [ ] Add regressions only for confirmed gaps: missing-index recovery, deletes vs changed data, account reset, configuration secrets, active-emulation cancellation and merge convergence.
- [ ] Run the full R3 device matrix on TestFlight, including offline edits and Apple TV cache loss; restore test data from backups where necessary. Record hashes/expected native-save contents without uploading private game files.
- [ ] Verify status/recovery copy describes observed results. Unavailable or failed sync cannot be presented as success.

## Task 4 — validate and complete library interoperability (R4)

**Consumes:** ratified interop matrix and separate cross-app save/folder contracts if selected.
**Files:** `Source/iOS/PVContinuity/`, app Continuity/Ecosystem/scanner; Provenance `PVLibrarySharing/` and its app importer/settings. Assign Provenance work through a linked counterpart issue; this roadmap does not authorize messaging another chat.
**Produces:** demonstrated supported directions and precise product limitations.

- [ ] Run `swift test --package-path Source/iOS/PVContinuity`; record supported-host constraints if package dependencies prevent a macOS test run. Run Provenance's `PVLibrarySharing` tests in its own supported checkout/build workflow.
- [ ] Execute existing browse/pair/copy/import/play paths before proposing a new backend. Test different-device foreground serving separately from same-device system-mediated transfer.
- [ ] Pin confirmed gaps with protocol fixtures/integration tests: revocation, catalog compatibility, path containment, interrupted Range transfer, SHA-256 mismatch, insufficient storage and duplicate game identities. Implement in bounded changes in the owning repo.
- [ ] If approved, write separate implementation plans for shared scan roots, automatic mirroring or cross-app native saves. Each must define concrete interfaces, destination layout, conflict/deletion policy and compatibility tests before code.
- [ ] Complete the R4 device matrix, including Apple TV recovery and visible error/progress states; attach both apps' tested SHAs/builds. Do not close the integration on one side's merge alone.

## Task 5 — resolve candidate stability/performance blockers (R5)

**Consumes:** confirmed hardware matrix and candidate-level reproductions from #45/#47/#50.
**Produces:** crash/hang dispositions, regression fixes and no-JIT performance report.

- [ ] Link existing #45/#47 and create specific reproductions for actionable #50 findings; distinguish old-build events and hypotheses.
- [ ] Profile/reproduce before changing code. Add a suitable regression for each established cause and validate on affected hardware/OS.
- [ ] Run R5 lifecycle, low-memory and interpreter measurements. Record target, measured behavior and explicit owner disposition for remaining limitations.

## Task 5a — prove save-state reliability (R7)

**Consumes:** save/load entry-point inventory, hardware matrix and R3 compatibility/conflict rules.
**Produces:** device evidence of correct restored progress, durable writes and visible safe failure on every supported platform.

- [ ] Locate current state-write/load implementations and all invoking UI; record actual file/slot ownership and core/build compatibility behavior before planning changes.
- [ ] Execute every R7 acceptance case. Add targeted regressions for established write/load defects, including interrupted writes preserving the previous valid state.
- [ ] Run device round trips and compatible-build sync on all three device pairs. Record state identity, restored progress, pause behavior, latency and failure outcomes; close only after acceptance.

## Task 5b — prove library editing (R8)

**Consumes:** all-platform edit-action inventory and per-field sync/deletion contract.
**Produces:** persistent, consistent edits with safe batch/delete behavior and measured responsiveness.

- [ ] Enumerate actual editable fields/actions and locate their owning models/stores; distinguish local data from remote catalog entries.
- [ ] Run every R8 edit/cancel/rescan/relaunch, batch and failure case; write focused regressions for confirmed persistence/selection/ownership defects before fixing them.
- [ ] Validate documented metadata sync and cross-app behavior against R3/R4 contracts. Record iPhone/iPad/Apple TV evidence and recheck known UI/UX defects after fixes.

## Task 6 — freeze, verify and submit (R6)

**Consumes:** R1–R5 plus R7/R8 evidence, measured responsiveness and no known unresolved UI/UX defects or launch-blocking failures.
**Files:** `docs/app-store/{submission-checklist,review-notes,privacy-label,metadata}.md`, final assets and `release-evidence/` index. Code/artifact fixes get their own tested task.
**Produces:** exact candidate identity and owner-reviewable submission package.

- [ ] Reconcile the existing checklist and old submission plan against final sources; finish privacy, server access controls, entitlement and review-note questions.
- [ ] From `Source/iOS/App`, run `make test`, relevant package tests and `make gate-release`; also build scheme `iCube (AppStore)`, configuration `Release (AppStore)`, for generic iOS and tvOS destinations. Record artifact/run links. Sideload release compilation is not a substitute for APPSTORE compilation.
- [ ] Inspect exported distribution-signed app/extension entitlements and privacy resources; run the finished device acceptance matrix on the exact TestFlight candidate SHA/builds.
- [ ] Finish screenshots/metadata and provide owner the complete package for acceptance. Record any narrowly waived nonblocking issue with rationale, owner and follow-up milestone.
- [ ] After explicit candidate acceptance, perform submission and record App Store Connect versions/builds, date, outcome and launch instructions. Do not interpret approval of this roadmap as approval to submit a binary.

## Continuing this plan

Start at Task 1. Live statuses and links belong in the GitHub tracker. An unchecked historical task may already be implemented; verify before doing it again. Never advance an acceptance checkbox solely because code was merged. This roadmap intentionally stops short of speculative function signatures for unapproved transports or unidentified UI defects.
