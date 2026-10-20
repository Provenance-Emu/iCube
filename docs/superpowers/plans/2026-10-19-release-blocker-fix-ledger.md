# Release blocker fix ledger — 2026-10-19

Owner request: continue with subagents and fix all issues. Scope follows the existing release contract in `docs/app-store/RELEASE-PLAN.md`; local code/test fixes do not substitute for shipping/device acceptance.

## Execution and ownership

| Task | Owner | Files/interfaces | State |
|---|---|---|---|
| Default ISO selection, current selection/clear, missing-file behavior | `default_iso` | DOLConfigBridge, General settings, GameGridItem, TVLibraryView, preboot/migration hooks | implemented; host production model red→green; integrated build in progress |
| Manual Change Disc and Confirm on Stop | `disc_and_exit` | PauseMenuView/model, TVEmulationBridge, top-bar stop subsection in EmulationScreen, inline pending-disc getter | baseline-compatible disc-action red test ready; root build running |
| Inert GPU EFB Peek Resolve UI and design/localization lint | `settings_lints` + root catalogs | GraphicsHacks model/tests, PauseCardFace/design metrics; root owns en/ja catalogs | implemented; GPU host red→green, reset linter 6 tests pass; runtime reset tests pending |
| Integration/review, iOS/tvOS unit/remote checks, APPSTORE builds | root | shared build/test infrastructure and release records | queued after reviewed implementations |
| Remaining settings reset/persistence, save/library editing/sharing/sync validation | next independent audit wave | release R2–R8 acceptance matrix | audit/fix after first implementation wave |

All builds and simulator mutations are serialized by root. Agents do not stage/commit/revert shared changes, run builds, edit catalogs or dispatch duplicate reviewers. Source work continues in the existing develop checkout because the accumulated uncommitted release fixes are the shared task state. Generated frameworks/projects stay unstaged.

## Interface/conflict scan

| Pair/task | Produced/consumed interface | Resolution |
|---|---|---|
| Default ISO / manual disc | Config bridge versus emulation bridge; both consume local disc metadata | separate ownership; root reviews common validation semantics |
| Default ISO / root sync audit | local selection versus portable config mirroring | device-local defaults, absolute core path on CurrentRun only; review migration ordering and defaults exclusions |
| Manual disc / Confirm on Stop | same pause view and top-bar lifecycle | one implementer owns both to avoid competing edits |
| Default ISO / prior adaptive removal | EmulationCoordinator + DolphinCoreService hooks | narrowly additive hooks; preserve Native default and removed adaptive code |
| All implementers / localization | new UI keys in shared catalogs | root batches catalog updates after each agent reports keys |
| Tests / parallel edits | root must observe baseline failures first | test-only phase, then explicit implementation go; no concurrent app build source mutations |

## Decisions and evidence

- Default ISO means a disc mounted for homebrew/WAD/NAND boot, not a preferred game to launch. Manual Change Disc is a separate running-session operation.
- Remove the GPU EFB Peek Resolve control until a renderer consumer exists; do not invent a performance promise or rebuild the core for unused plumbing cleanup.
- Preserve direct user choice and existing PauseArbiter behavior. Confirm on Stop governs user stop entrypoints; resetting and replacing a game retain their own semantics.
- Pending-disc inspection may use a const inline accessor under CPUThreadGuard if it changes neither layout nor exports. All four existing framework slices export the swap/DiscIO/guard functions.
- Six opt-in snapshot tests skipped in the preceding full iOS run; 1,970 passed, zero failures. Current work needs fresh evidence after integration.
- Physical iPad Pro is connected; iPhone and Office Apple TV are paired/available. No matched A14 device is listed. Device testing must preserve user progress and record the exact candidate/configuration.

## Progress

1. Three agents dispatched with explicit standard-tier models and isolated prompts; file ownership agreed.
2. Regression tests added for Default ISO reachability, manual disc reachability and absent inert GPU control. Rejected source-text grep assertions for confirmation behavior; require actual policy/callback behavior tests.
3. Root baseline `build-for-testing` succeeded. Two initial executions did not reach assertions: one interrupted infrastructure attempt, then CoreSimulator rejected app launch as busy installing/uninstalling. These are not product test failures.
4. Reboot/launch recovery on dedicated iOS simulator `DBA9A669-6C27-454A-8AA3-9106D681941C` stalled. Created fresh dedicated iOS 26.5 simulator `3B53AC9D-084F-4841-920E-BA8A4DD1322D`; baseline test-without-building is pending (`blockers-red-fresh.log`). No unrelated simulator/build was interrupted.
5. Agents are executing the unchanged production model builders in native macOS harnesses to establish the three behavioral red cases while simulator recovery continues. This is host model evidence only; installed app tests remain mandatory after integration. Production edits begin after each actual expected assertion failure.
6. Root added 27 missing/new keys to en/ja catalogs (English fallback in ja); agent-added strings will be reconciled after integration. Settings reset audit confirmed missing Bounding Box and Texture Cache reset keys; two baseline public-API regression tests added, not yet executed.

7. All three unchanged production model builders reproduced their expected missing/inert-control failures on native macOS harnesses, then passed after implementation. Harnesses are under `/tmp/icube-default-iso-audit`, `/tmp/icube-settings-audit`, and `/tmp/icube-release-fixes-2026-10-19/disc-host-model`. This is model evidence, not an installed app result.
8. Implemented Default ISO selection/management/migration/preboot guards; manual disc picker/guarded swap plus Confirm on Stop; removed inert GPU row; repaired Bounding Box/Texture Cache/Microphone reset coverage. Added runtime XCTest regressions; execution pending.
9. Independent review fixed duplicate Default ISO helper definitions and an iOS disc-picker controller-scope shadow. Device/controller/core swap acceptance remains open.
10. Fresh simulator run never reached assertions (stalled launch; own SpringBoard recovery ended the request). Do not count it as product red/green. Initial integration `build-for-testing` is running, log `blockers-integrated-build.log`, with existing validated core slices and `DOL_SKIP_CORE_BUILD=1`.
11. R7 source audit reproduced real writer failures in native transaction harness: short write/failed close can replace a good slot; failed promotion can leave the slot missing. Provider exposes worker `.tmp` and `.dtm` as loadable entries; UI save success precedes actual worker completion. Save-state owner has red evidence and is preparing atomic preservation, completion-result and visible-failure fixes. Production R7 writes held during initial integration build.
12. R3 audit in progress: investigate async download commit after emulation starts and conflict removal after failed operations. No production fix or device sync pass claimed.

13. Initial integrated iOS `build-for-testing` succeeded. Deeper reset repair now passes 13 Python checker tests with 200 UI-writable config keys covered/reset or deliberately preserved. Those native/static checks do not establish full bridge runtime acceptance.
14. Core save completion API is final (`SaveAsWithResult`, `SaveAsAndWait`, `SaveAndWait`); nine repository transaction gtests and seven actual writer fault-injection cases pass. Async UI captures game/session at tap; user Quit recovery and stale-thumbnail/minter/provider cases are implemented and reviewed. No state format/version change.
15. Four-slice core rebuild is running with static dependencies and two jobs; iOS device and simulator stages completed, tvOS stages remain. The initial `-d` invocation selected incompatible shared external dependencies and failed configuration; rerun uses the normal dependency mode. Raw iOS dylib exports all three new APIs; primary/packaged frameworks update only after all stages finish.
16. Cloud native tests reproduced and fixed old-account snapshot generation, account conflict refresh and rapid disable/re-enable interruption. Physical teardown review found UI DidEnd precedes file closure. Final generation-aware worker-scope drain and queued-event tests are in progress; old UI notification timing is retained. Missing-IPL retry now uses the common launch path (source routing verified, installed UI check pending).
17. Save/Sync native logs copied to `docs/app-store/release-evidence/2026-10-20-native/`; [current evidence boundary](../../app-store/release-evidence/2026-10-20-release-blocker-fixes.md) records pending final platform/device gates. No commits, TestFlight publication or submission acceptance.
