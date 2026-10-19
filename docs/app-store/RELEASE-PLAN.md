# iCube 1.0 release plan

Updated: 2026-10-19. **Status: owner quality requirements recorded; detailed transport/scope decisions remain open. No candidate is accepted for submission.**
Baseline inspected: `8bad720220` on `develop`. No app builds or device tests were run for this planning pass.

## Start here

This is the release's scope and acceptance contract. GitHub's release tracker and child issues hold live status, assignments, blockers and evidence. Tracker: [#51](https://github.com/Provenance-Emu/iCube/issues/51). Milestone: [iCube 1.0 release readiness](https://github.com/Provenance-Emu/iCube/milestone/1). Workstreams: [R1 #52](https://github.com/Provenance-Emu/iCube/issues/52), [R2 #53](https://github.com/Provenance-Emu/iCube/issues/53), [R3 #54](https://github.com/Provenance-Emu/iCube/issues/54), [R4 #55](https://github.com/Provenance-Emu/iCube/issues/55), [R5 #56](https://github.com/Provenance-Emu/iCube/issues/56), [R6 #57](https://github.com/Provenance-Emu/iCube/issues/57). [R7 #58](https://github.com/Provenance-Emu/iCube/issues/58), [R8 #59](https://github.com/Provenance-Emu/iCube/issues/59). The execution roadmap is [here](../superpowers/plans/2026-10-19-icube-release-readiness.md). LLM memory is a pointer to these records, not another task database.

Owner request: finish the tvOS UI, settings on both platforms, and ROM/library sync across iCube installs and Provenance, then make a real App Store release. The older submission plan alone does not cover that scope.

The minimum release experience proposed here is: import a game, find and launch it, configure it without navigation traps, pause and resume, preserve progress, and bring the library/progress to another supported install with understandable controls and failures. All three form factors—iPhone, iPad, Apple TV—are included. The owner-confirmed quality bar below governs acceptance; detailed mechanisms remain subject to the open decisions.

## Owner release bar — confirmed 2026-10-19

The owner requires: “work fast, well, have no ui or ux bugs, settings work sync works, save states work, library editing works, library sharing works, clean ui”. These are launch requirements, not optional polish.

Acceptance translates that bar into evidence:

- **Fast and reliable:** record cold/warm launch, library navigation/search, settings interaction, import and save/load latency, plus no-JIT gameplay speed/frame pacing and memory on the agreed hardware. Capture baseline and candidate measurements with library size and OS. Agree numeric budgets from that baseline; none have been invented here.
- **Clean UI with no known UI/UX defects:** inventory every reachable shipping screen and action on iPhone/iPad/Apple TV, walk normal/error/empty/loading states with supported inputs, and record defects. No known unresolved UI/UX defects at sign-off; discovered defects must be fixed and rechecked. This is a verifiable release gate, not a claim that testing can prove no undiscovered bugs exist.
- **Functional completeness:** settings, sync, save states, library editing and library sharing each need end-to-end acceptance. Save-state and editing gates are R7 and R8 below; they cannot be closed by a screenshot or unit-test pass alone.
- **Release integrity:** keep the entire tested candidate identity with the evidence, and repeat affected checks after changes. Do not quietly defer a required feature to meet a date.

The owner has specified outcomes, not an automatic-ROM transport or cross-app save-state compatibility promise. Those implementation/scope choices remain explicit in the decision list.

## Evidence and corrections to older plans

| Area | Observed on 2026-10-19 | What is still unknown |
|---|---|---|
| tvOS | Redesign, later settings focus fixes and October 19 navigation fixes exist. October 12 light/dark baselines exist in `docs/superpowers/baselines/2026-10-12-tvos/`. | Which defects remain on the owner's current build; complete remote/controller walkthrough on the release candidate. |
| Settings | Shared MenuKit, settings models, search and deep links exist. October 16 audit reproduced Left both changing a value and escaping the pane; subsequent fixes exist. | Every leaf's persistence, runtime vs saved values, and back navigation on both platforms. |
| iCloud | `PVCloudSync/CloudKitAvailability.swift` sets `containerIsProvisioned = true`; AppStore entitlements request iCube, iFly and Provenance containers. | Production schema, current distribution entitlements and real-device convergence. A source flag is not proof of production readiness. |
| User data | `PVSyncRules` explicitly rejects ROM extensions; data sync and document merging are implemented. | Conflict, account-change and Apple TV purge recovery in shipping builds. |
| ROMs | `PVContinuity` provides iCube library sharing; Provenance has `PVLibrarySharing` and `ICubeContinuitySource`. Same-device iCube export uses a system share sheet. | Full supported direction matrix; discoverability, resume, deduplication and import completion on devices. |
| Shared folder | Provenance has a picked-folder UI. iCube's inspected scanner uses its own Software folder; no corresponding bookmark integration was found. | Whether zero-copy folder access is required for 1.0. Do not describe this as already working. |
| Distribution | Recent TestFlight workflow succeeded on `c198d6cb81`, run `39289059895`; local HEAD is newer. | Release candidate identity and device acceptance on that exact build. |
| Stability | Open issues #45 and #47, plus October 19 Sentry report #50. | Current-build reproduction and disposition. Triage hypotheses are not established root causes. |

Use the October 12 [submission design](../superpowers/specs/2026-10-12-app-store-submission-design.md) and [implementation plan](../superpowers/plans/2026-10-12-app-store-submission.md) as historical detail. Their provisioning instructions and unchecked task status are stale in places. The [submission checklist](submission-checklist.md) is the final audit checklist; reconcile it with current evidence before using it. This plan does not silently reverse earlier owner decisions, including runtime JIT detection for re-signed installs.

## Release workstreams and acceptance

Priorities: P0 = blocks data safety or submission; P1 = required proposed launch behavior; P2 = follow-up unless explicitly promoted. Status starts **unverified**, even where code exists. Roles below are responsibilities, not assignments to particular people or chats.

### R1 — tvOS library, focus and pause UX (P1)

Owner: iCube UI implementer; final acceptance by product owner on Apple TV.

- [ ] Capture defects from the owner's current build, recording build number, screen, starting focus, exact remote presses, expected/actual behavior and screenshot/video. Separate reproducible defects from preferences.
- [ ] Walk empty, small and large/mixed libraries; All/GameCube/Wii, favorites/recent/search, index/scrolling, details/context menus, import, and return from gameplay. Every actionable control is reachable and visibly focused; no clipped essential text or focus stranded off-screen.
- [ ] Walk pause tiles, quick menu, save/load slots, cheats, shaders, controllers and reset/exit confirmations. Cancelling returns to the invoking control; changing panes neither resumes unexpectedly nor leaves the core permanently paused.
- [ ] Verify Siri Remote and a physical gamepad, light/dark, Reduce Motion and readable long labels. Verify on physical Apple TV; simulator screenshots supplement that result.
- [ ] Add regression coverage for reproduced focus/navigation bugs and refresh representative baselines after fixes. Screenshots alone do not close this issue.

Entry points: `Source/iOS/App/Common/Swift/TVLibraryView.swift`, `PauseMenuView.swift`, `QuickMenuView.swift`, `MenuKit/`, `Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift`, `Source/iOS/App/Scripts/tvos_screens.sh`. Consult `docs/audits/2026-10-16-tvos-settings-audit.md` before changing remote behavior.

### R2 — settings correctness on iOS/iPadOS/tvOS (P1; data-loss defects P0)

Owner: iCube settings implementer; product owner accepts the user-facing organization.

- [ ] Inventory every settings leaf and search/deep-link entry. Track platform, availability in APPSTORE, input modes, default, valid range, persistence layer, whether changes are live or require restart, and reset behavior. Audit engine and app preferences, not just styling.
- [ ] Check library → settings and pause → settings on iPhone, iPad and Apple TV. Open/search/deep-link to a row, adjust it, go back, reopen, end game, relaunch; values and navigation remain correct. Sidebar Menu/Back and adjustable Left/Right have distinct predictable behavior.
- [ ] Cover zero-width slider ranges, unsupported graphics/audio choices, nonstandard values, in-game Base/CurrentRun overrides and per-game/global precedence. No silent switch to a slower engine while leaving a row.
- [ ] Decide and display the scope of each setting: device-local, synced preference or per-game profile. Exclude credentials, pairing grants, tokens and device-specific paths from generic preference sync; audit existing INI uploads for these fields.
- [ ] Check destructive reset/clear actions, unavailable permissions/services, readable footers, localization and accessibility. Preserve working iPhone/iPad touch behavior while repairing tvOS.

Entry points: `Common/UI/Settings/SwiftUI/{SettingsRootView,SettingsRootModelBuilder,SettingsSidebarShell,SettingsSearchIndex}.swift`, `Leaves/`, `Common/Swift/MenuKit/ValueStepper.swift`, `Common/Bridging/DOLConfigBridge.mm`. Existing tests include `SettingsWriteBackTests` and `MenuModelTests`.

### R3 — production user-data sync between iCube installs (P0 safety / P1 functionality)

Owner: sync implementer; account administrator verifies production deployment.

- [ ] Record actual distribution-signed entitlements, container identifiers and Production schema evidence. Do not re-provision just because an old document says the container is missing. Do not treat simulator CloudKit unavailability as a device failure.
- [ ] Inventory and test the categories actually shipped: memory cards/Wii saves, save states, library metadata, profiles/configuration and optional large categories. Record exact toggles/defaults and exclusions. ROM images stay outside this provider.
- [ ] On store-configured TestFlight builds, demonstrate iPhone ↔ iPad, iPhone ↔ Apple TV and iPad ↔ Apple TV convergence after game end/relaunch. Test offline edits on both devices, conflict resolution/Keep Both, interrupted transfer, deletion/restore, signed-out/restricted/quota errors and iCloud account changes.
- [ ] Prove sync does not overwrite active emulation files. Check shared card/NAND changes across different games, not only per-game files. Credentials and device-local settings must remain private to their intended scope.
- [ ] Simulate Apple TV cache loss and missing sync index. Rebuild additively; never interpret a purge as a user's delete or propagate it to healthy devices. Explain what can be restored, and from where.
- [ ] UI reports pending, syncing, conflict, unavailable and failed distinctly, with a recovery action. Sign-off includes version/hash compatibility limits for save states.

Entry points: `Source/iOS/{PVCloudSync,PVSyncRules}/`, `Common/Services/{CloudSyncCoordinator,CloudSyncLifecycleService}.swift`, `Common/Swift/LibraryStateStore.swift`, `Common/UI/Settings/SwiftUI/{CloudSyncSettingsView,SyncConflictResolutionView,SyncRecentlyDeletedView}.swift`. The October 11 [sync design](../superpowers/specs/2026-10-11-icube-user-data-sync-design.md) remains the reference for merge/deletion rules.

### R4 — ROM/library access across installs and Provenance (P1; contract decision first)

Owner: iCube integration implementer plus Provenance counterpart. Changes in Provenance require their own issue, review and build evidence; an iCube fix cannot close both sides.

Treat the following as distinct user journeys:

| Journey | Existing mechanism | Proposed 1.0 target |
|---|---|---|
| iCube → iCube on another device | Paired nearby continuity library | Discover, pair, browse, copy, verify, register and launch. |
| iCube ↔ Provenance on different devices | Provenance's iCube dialect via `PVLibrarySharing` | Verify each supported direction with both apps in the foreground during serving; show suspension/reconnect guidance. |
| iCube ↔ Provenance on one iPhone/iPad | URL browse/play/request + system share sheet | Browse/play and user-confirmed import with visible completion/error; do not depend on a backgrounded sender's HTTP server. |
| Shared folder without ROM copies on iOS/iPadOS | Provenance picker; missing iCube scan-root integration | Decision required: launch requirement or explicit later milestone. |
| Automatic/off-LAN ROM mirroring | No verified complete path in this audit | Decision required; do not call manual nearby copy automatic sync. |
| Cross-app saves/settings | Separate from ROM transfer; shared entitlements are insufficient | Compatibility and ownership contract required before claiming cross-app progress sync. |

- [ ] Ratify minimum behavior for each row. Publish a supported/unsupported direction matrix including Apple TV; never promise a Files picker or iCloud Drive solution there.
- [ ] Reuse the existing continuity contract. Preserve `_icube-continuity._tcp`, catalog/manifest v1 and current pairing semantics unless a separately reviewed migration explicitly changes them. Read Provenance's `docs/superpowers/specs/2026-10-14-cross-app-library-sharing-design.md`, including its later as-built sections, before planning protocol work.
- [ ] Test discovery denied/offline, pair/approve/revoke, unknown peer, large ROM, Range resume after disconnection, checksum failure, low disk space, duplicate import, same game with another revision/disc/format and source deletion. Failed/partial files never appear as playable games.
- [ ] Distinguish local, available remotely, downloading and missing games. Show source, progress, cancel/retry and final destination; no apparently dead Send/Import actions. Catalog entries do not establish that a local ROM exists.
- [ ] If cross-app saves are in launch scope, specify compatible native save paths, identity mapping, emulation ownership and conflict rules for both apps. Never assume emulator save states are interchangeable. If not, say explicitly which progress remains app-specific.
- [ ] If shared-folder access is selected, specify read-only scan roots, security-scoped bookmark recovery, iCloud eviction/download and duplicate handling before implementation. Keep saves/config in the intended writable app container.

Entry points: `Source/iOS/PVContinuity/`, `Source/iOS/App/Common/{Continuity,Ecosystem}/`, `Common/UI/SoftwareList/GameFileCacheManager.mm`, `Common/Services/LibrarySnapshotService.swift`. Provenance counterparts: `PVLibrarySharing/`, `PVLibrary/.../EcosystemIntegration/`, `PVUI/.../Settings/Views/{EcosystemIntegrationView,LibraryStorageView}.swift`. External sibling paths are contextual; verify the target checkout before making changes.

### R5 — stability and interpreter performance (P0 disposition)

Owner: stability implementer; product owner accepts any documented residual risk.

- [ ] Triage #45 main-thread hangs and #47 OS-availability crash against candidate builds. Link current reproduction or evidence supporting exclusion; issue age is not a reason to waive a crash.
- [ ] Split actionable findings from #50: watchdog/RAM (ICUBE-3), SwiftUI layout abort (ICUBE-CB), Slider stride crash (ICUBE-G1). Verify hypotheses before assigning fixes. Track stale pre-fix reports separately from regressions; keep expected MetricKit diagnostics visible for performance analysis.
- [ ] Exercise boot, pause/resume, save/load, controller attach/detach, background/foreground, app termination and rapid large-library scrolling without corruption/crash/hang on candidate hardware. Demonstrate recovery from low-memory/storage failures.
- [ ] Record no-JIT frame pacing, speed, memory and thermals with representative legally usable test content on the minimum supported iPhone/iPad/Apple TV hardware selected for the release. Publish limitations; set an agreed acceptable performance target before claiming broad playability.
- [ ] #46 legacy sideload JIT remains separate unless it reproduces in the store configuration. Preserve prior runtime-detection decisions; reconcile outdated public #11 wording with actual binary behavior and honest review notes.

Evidence origin: [#45](https://github.com/Provenance-Emu/iCube/issues/45), [#47](https://github.com/Provenance-Emu/iCube/issues/47), [#50](https://github.com/Provenance-Emu/iCube/issues/50). The Sentry report is not a substitute for a candidate-level stability result.

### R6 — submission, privacy and store presence (P0)

Owner: release implementer; account owner controls final submission/release.

- [ ] Re-audit the final APPSTORE artifacts for developer HTTP APIs, firmware download paths, JIT capability behavior, allowed entitlements, extension signing and bundled resources. Assess current code rather than replaying old tasks. Explain non-obvious behavior honestly in review notes.
- [ ] Complete app/SDK privacy manifests, required-reason API audit, Sentry opt-out and payload verification, credential exclusion from sync, privacy-label answers and policy/support links. Settle Web UI/WebDAV exposure and authentication; test the chosen user controls.
- [ ] Final store screenshots match the finished APPSTORE UI on all form factors and use owned or appropriately licensed imagery. Keep the website's real-game artwork set separate. Freeze metadata, age rating, export-compliance answers and reviewer test instructions with suitable homebrew content.
- [ ] Build/test the candidate from a recorded SHA. Verify Release (AppStore) for iOS and tvOS plus applicable package/app tests; compile relevant sideload configurations after conditional-code changes. Inspect the exported signed artifacts, not just a Debug run.
- [ ] Log platform version/build numbers, TestFlight run, device matrix and final owner acceptance. Select launch timing and rollout approach from the options actually available for this first release. Submit only after the account owner accepts the candidate.

Use [submission-checklist.md](submission-checklist.md), [review-notes.md](review-notes.md), [privacy-label.md](privacy-label.md) and [metadata.md](metadata.md); reconcile their owner questions rather than replacing them with a second unchecked checklist.

### R7 — reliable save states on every platform (P0 safety / P1 functionality)

Owner: save-state implementer; final acceptance on physical iPhone, iPad and Apple TV.

- [ ] Inventory every shipped save/load entry point, including pause slots, quick actions and automatic/resume behavior where supported. Record slot identity, active-game association and overwrite/delete confirmation.
- [ ] Create a state at a recognizable point, advance, load, and verify game state and expected paused/running state. Repeat across slots, stop/relaunch and background/foreground. Check thumbnails, timestamps and selection correspond to the actual state.
- [ ] Test cancellation, corrupt/truncated/missing states, insufficient space, interrupted writes and an incompatible core/build/game revision. Fail visibly and preserve the previous good state; never load a different game's slot or report a failed write as saved.
- [ ] Demonstrate save-state sync between compatible iCube builds on every supported device pair, with R3 conflict/offline handling and Apple TV purge recovery. Document incompatibility before offering a load; do not promise cross-core state portability to Provenance.
- [ ] Measure save/load responsiveness on the hardware matrix and fix regressions. Cover confirmed defects with targeted tests plus device evidence of restored progress.

Locate owning save-state bridge, pause-slot and automatic-state code during baseline discovery; existing pause/save UI alone is not evidence of persistence correctness. Dependencies: R1/R2 entry points, R3 sync and R5 lifecycle safety. R6 waits for acceptance.

### R8 — complete library editing on iOS/iPadOS/tvOS (P1; destructive-data defects P0)

Owner: library implementer; final acceptance by product owner on all form factors.

- [ ] Enumerate every edit action actually offered by each platform, including metadata/title/artwork, favorites, multi-selection/batch actions and removal where present. Record intended persistence and sync scope per field; list unsupported actions explicitly instead of assuming parity.
- [ ] Exercise edit, commit, cancel, reopen, rescan and relaunch. The library card, details, search, sort/filter and favorite/recent views show consistent results without duplicates or lost edits.
- [ ] Verify batch selection targets the intended games after filtering/sorting, and focus/selection returns predictably when the action ends. Empty and large libraries remain responsive.
- [ ] Verify local removal versus shared-library removal versus synced metadata changes have distinct, accurate copy. Cancellation preserves data; deleting a ROM does not silently delete saves, other apps' copies or remote peers' libraries. Confirm the approved deletion policy rather than inventing one in the handler.
- [ ] Test missing/remote-only ROMs, duplicate/revision/disc identities, unavailable artwork, failed file operations, interrupted edits and concurrent metadata sync. Fail visibly and preserve the prior valid record.
- [ ] Recheck edits on another install for fields documented as synced, and on Provenance for fields explicitly covered by the interoperability contract. Measure edit/rescan latency and keep supported input behavior consistent with R1/R2.

Entry points: `Source/iOS/App/Common/Swift/TVLibraryView.swift`, library detail/context-menu models, `Common/UI/SoftwareList/GameFileCacheManager.mm`, `Common/Swift/LibraryStateStore.swift`, snapshot writers and metadata/artwork stores identified during inventory. Dependencies: R1/R2 UI, R3 metadata convergence and R4 local/remote ownership. R6 waits for acceptance.

## Sequence and release gates

| Stage | Deliverable | Exit condition |
|---|---|---|
| 0: scope and baseline | Current-build defect inventory, settings/sync matrix, cross-app contract, baseline test results | Owner agrees launch scope and deferred behavior; unknowns have owners. |
| 1: usability and safety | R1/R2/R8 usability repairs, R7 persistence safety, R5 reproducible crash fixes; R3 production validation starts early | Primary journeys pass; destructive/credential bugs closed. |
| 2: sync and ecosystem | R3/R4/R7/R8 end-to-end tests and fixes against ratified contracts | Cross-device/app matrix passes; conflicts and purge recovery demonstrated. |
| 3: release candidate | R6 artifacts, full regression, device checks, final screenshots | No unresolved P0 or known UI/UX defects; all owner-required functionality passes. Scope changes require an explicit owner decision. |
| 4: review and launch | Owner-approved submission and release record | Accepted store build and documented support/rollback response. |

R1 and R2 share focus/navigation code: coordinate changes. R3/R4 share identity/file rules: settle ownership before cross-app writes. Production schema and sibling-app builds have external lead time: start verification in stage 0. Screenshots wait for UI freeze. Any candidate code change invalidates affected results; re-run those results and record the new SHA. Set dates after baseline/reproduction, not from an invented estimate.

## Decisions for the owner

1. What is the minimum ROM/library experience at launch: explicit nearby copies, a shared local folder, automatic mirroring, or a defined combination? Proposed default: validate existing nearby and same-device copy first; retain folder/mirroring as explicit scope decisions.
2. Must progress move between Provenance and iCube at launch, or only between iCube installs? If yes, native saves need a separate cross-app ownership/compatibility contract.
3. Must iOS and tvOS launch together? Proposed default: one coordinated release, without delaying critical stability fixes for existing testers.
4. Which oldest hardware and representative games define acceptable no-JIT performance? Define measurements and expectations before final acceptance.

No deadline, pricing/Plus model or automatic-ROM backend is assumed. The earlier request for a polished launch remains context, not a waiver for remaining usability defects. Planning and issue creation are authorized; product implementation starts after scope review.

## Evidence and maintenance rules

Each issue closure needs: commit SHA, tested build/configuration, device/OS, test command or exact manual steps, outcome and artifact/run link. A merge or checked task alone is not acceptance. Use `proposed → ready → in progress → implemented/unverified → verified` in issue bodies; flag external blockers with the responsible role and next action.

Change scope here first, then update linked issues and the execution roadmap. Keep tests and acceptance evidence on GitHub; memory stores only the canonical links and key decisions. Do not copy historical test counts into new candidate results.

References checked 2026-10-19: [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (especially 2.1, 2.3, 2.5, 4.7 and 5.1); [Apple TV iCloud/storage guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/iCloudStorage.html) (archived guidance: verify current SDK behavior during implementation). These establish review/storage constraints, not a guarantee of approval.
