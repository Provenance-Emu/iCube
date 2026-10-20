# Release blocker fixes — 2026-10-19/20

Status: implementation and integration in progress. No release candidate, device acceptance or submission is claimed. Canonical scope is [RELEASE-PLAN.md](../RELEASE-PLAN.md); live ownership/progress is the [fix ledger](../../superpowers/plans/2026-10-19-release-blocker-fix-ledger.md).

## Implemented locally

- Default ISO is a device-local disc selection, not a preferred launch title. Library context actions set it; General settings shows the full selection and clears it. Sandbox-relative storage survives container rebasing; the core receives an absolute path on CurrentRun only. Missing discs remain visibly selected and block dependent launcher/NAND boots with remediation; ordinary disc boots remain available.
- Manual Change Disc uses local compatible disc images, revalidates before queuing the guarded core operation, and preserves pause ownership. The UI explains that the user must resume for insertion. Both user stop entrypoints honor Confirm on Stop.
- Inert GPU EFB Peek Resolve is removed. Reset covers Bounding Box, optimized Texture Cache Accuracy, microphone-only Slot B overrides and four General boot preferences. Non-microphone Slot B assignments and SD write protection are preserved. The wiring checker now inspects actual setters and global reset behavior rather than treating per-page deletions as global reset coverage.
- Save safety repairs preserve good slot bytes through failed writes/closes/replacements, return actual worker completion, bind metadata to the serialized game/session, filter worker/recording files from the state browser, and move UI waits off MainActor. User Quit recovery and exact session checks are implemented and source-reviewed; final platform execution remains open.
- Sync file-access leases drain before core boot and prevent new local sync I/O during emulation. Failed/deferred conflicts remain unresolved; explicit remote resolution uses remote metadata. Account changes clear old-account choices. Transfers retain their original account/boot epoch; physical core teardown, superseded workers and offline trash recovery have dedicated regression coverage.

## Evidence boundaries

| Check | Observed result | Limits |
|---|---|---|
| Initial integrated iOS app + unit target | `build-for-testing` succeeded | Predates later save/sync/deeper reset changes; not their final build. |
| Default ISO, pause/disc and GPU-row production model harnesses | Expected baseline red, then green | Native macOS; storage/framework adapters as documented in scratch harnesses; not installed UI/core behavior. |
| Settings wiring | 200 writable keys covered or explicitly preserved; 13 checker tests pass | Static wiring + policy tests; bridge runtime reset tests still need execution. |
| Sync safety | 21 final native XCTest cases passed | Real coordinator/gate and scanner/index packages; provider is a controlled test fixture. Covers stale-account snapshots, rapid disable/re-enable, delayed start/drain delivery, stale worker admission and disabled/offline durable restore. UIKit notification/ObjC worker wiring still needs platform runtime checks. |
| Save file transaction | Nine actual repository gtests pass | Fault-injected transaction operations; full core writer/device save/load remains separate. |
| Nonblocking quick-save UI | Host asynchronous callback harness passes | Controlled service completion fixture; not gameplay/device evidence. |
| Localization/design | No missing static keys or interpolated lookup keys; design ratchet passes | Refresh after final UI strings. Japanese new keys use existing English-fallback policy. |
| Simulator execution | Launch failures/stalls before product assertions | Not counted as product red/green. Dedicated instances only; unrelated builds/devices preserved. |

Durable raw results are in [2026-10-20-native](2026-10-20-native/). The earlier full iOS result (1,970 passed, six opt-in snapshot tests skipped) belongs to the preceding settings-context change; it is not a current-candidate result.

## Required next gates

1. Finish independent review and final source integration; rebuild and inspect all four primary/packaged core slices for the new save completion APIs and retired adaptive-resolution content.
2. Regenerate Tuist, build/test final iOS and tvOS Debug plus Release (AppStore), record exact source/artifact identities and rerun affected/full tests.
3. Exercise Default ISO launcher boot, disc 1→2 continuation, pause preservation, write/load failure recovery, same-title restart races, and sync interruption/conflict/account transitions on real devices. No matched A14 device is available in the current inventory.
4. Complete R1–R8 release acceptance, including library editing/sharing, Production CloudKit convergence, signed artifact audit and owner acceptance. Source fixes do not close these gates.

## TestFlight preparation — October 20

Owner requested iOS and tvOS test builds/TestFlight. App Store Connect app identity verified as iCube Emu (`6752685822`, `com.joemattiello.iCube`). Both platforms currently have valid older builds; the new candidate has not been uploaded.

An additional privacy regression was reproduced and repaired: `Config/RetroAchievements.ini` and `Config/DSUClient.ini` are excluded from local/remote sync scans, transfers, remote tombstones and manual conflict resolution. The 26 native sync tests pass with no failures; [log](2026-10-20-native/sync-private-config-green.log). Historical cloud records are not purged by this change. Final integrated app/archive validation remains pending.

Final four-slice core rebuild succeeded. All primary and packaged frameworks export the three save-completion APIs, and packaged cores pass the retired adaptive-resolution content check. The privacy filter passed independent source review. Candidate build `1792472425` is being archived serially for iOS and tvOS; upload is still pending. Device steps are recorded in the [beta checklist](2026-10-20-testflight-checklist.md).
