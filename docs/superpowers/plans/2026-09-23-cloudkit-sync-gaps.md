# WS-5 CloudKit sync — gap audit, 2026-09-23

Written against this worktree's branch point on `develop`, which already contains
`b566893b38` (engine core), `7c83861c01` (app wiring), `e362c5dbdd` (app-prefs decision) and
`8af5c86218` (review follow-ups: "iOS and tvOS both BUILD SUCCEEDED; 46 PVCloudSync tests pass").

**Correction to the roadmap doc.** `docs/superpowers/plans/2026-09-21-icube-post-jit-roadmap.md`
says iCube's WS-5 starting point is "Zero. No CloudKit, no peer transfer, no iCloud entitlement."
That was true when the roadmap was written (2026-09-21) and is no longer true — WS-5 landed in the
two days since. Treat this file, not that section, as the current state of WS-5.

## What already exists (verified by reading every file, not by trusting commit messages)

| Plan task | Status | Where |
| --- | --- | --- |
| 1. Provision container + entitlements | **Staged, correctly un-applied** | `docs/cloudkit-entitlements.patch` (see below) |
| 2. Classification allow-list, shared with WS-4 | **Done** | `Source/iOS/PVSyncRules/Sources/PVSyncRules/{SyncClassifier,SyncableFileType}.swift`, 17 tests |
| 3. Port CloudKitAvailability / SyncProvider / CloudKitSyncProvider / TimestampConflictResolver / watcher / coordinator | **Done** | `Source/iOS/PVCloudSync/Sources/PVCloudSync/*`, `Source/iOS/App/Common/Services/CloudSync{Coordinator,LifecycleService}.swift` |
| 4. Improve on iFly: `retryAfterSeconds`, rate-limit handling | **Done, exceeds iFly** | `SyncRetryPolicy.swift` + `CloudKitErrorMapping.swift` — reads the *largest* `CKErrorRetryAfterKey` across a `partialFailure`'s inner errors, classifies `requestRateLimited` separately from generic backoff |
| 5. Sync status UI: indicator, settings pane, conflict view | **Done** | `SyncStatusIndicator.swift`, `CloudSyncSettingsView.swift`, `SyncConflictResolutionView.swift`, wired into `SettingsRootView.swift:587` |
| 6. App-prefs (`UserDefaults`/KVS) decision | **Done, decided explicitly not to adopt KVS** | Doc comment on `CloudSyncCoordinator`, reasoned from the actual 44 `@AppStorage` keys (18 debug, 18 peripheral-specific, 8 device-independent but cosmetic) |

Acceptance criteria from the plan:
- "No ROM ever leaves the device. Assert this in a test against the classifier." — **done**:
  `SyncClassifierTests.testNoROMIsEverSyncable`, `UserDataScannerTests.testNoRomArtworkOrFirmwareIsEverScanned`.
- "A genuine conflict surfaces for the user rather than silently discarding a save." — **done**:
  `TimestampConflictResolver` escalates same-window/different-checksum to `.manual`, surfaced in
  `SyncConflictResolutionView`.
- "Two signed-in devices converge" / "airplane mode, reconnect, converges without loss" — **cannot
  be verified in this worktree**: no provisioned container, no second device. The design supports it
  (additive-only merge, retry policy honours `retryAfterSeconds`, foreground trigger re-syncs on
  reconnect) but this is a device-pair test, not a code-review finding.

Correctness items from the task brief (a):
- **Availability check never traps when the entitlement is missing** — done. `CloudKitAvailability`
  hard-gates the simulator, parses `embedded.mobileprovision` rather than reading
  `__TEXT,__entitlements` (which iFly found disagrees with `codesign -d` on an ad-hoc build), and
  gates everything behind `containerIsProvisioned` so an App Store build with no container never
  calls `CKContainer(identifier:)`.
- **Conflict resolution by modification timestamp** — done, `TimestampConflictResolver` +
  `SyncPlanner`, with a same-checksum fast path and a simultaneity window that escalates to manual
  instead of guessing.
- **No sync of ROM/disc files** — done, allow-list (not a blocklist) in `SyncClassifier`, asserted
  in tests.
- **No sync while a game is running, or of the currently-open save** — done at the coarse grain the
  plan asks for: `SyncLifecyclePolicy` gates every trigger off entirely while `isEmulating`, aborts
  an in-flight run when emulation starts, and flushes deferred work on `emulationDidEnd`. There is no
  separate "is this specific file currently open" check, and none is needed — the gate is
  file-agnostic and covers the resume/`.auto` state along with everything else. Verified the
  notification ordering this depends on: `DOLEmulationDidEndNotification`
  (`EmulationCoordinator.mm:1830`) posts only after `Core::IsRunning()` returns false and the run
  loop has exited, i.e. after Dolphin's own core shutdown (which flushes memory cards and NAND saves)
  has already happened — the flush-on-stop sync does not race the core's own final write.

## Two real bugs found and fixed in this session

Both are in `CloudSyncCoordinator` (app-target glue, not covered by `swift test` — the package tests
all passed before these fixes because the bug isn't in the tested packages).

1. **`refreshStatistics()` hardcoded `lastSyncDate: Date()`**, and `runSync` calls it right after the
   local-only scan — before the availability/remote checks. Net effect: enabling sync on today's
   build (no container) showed "Last Synced: just now" in the status row while the footer said
   "iCloud sync is not available in this build yet." Fixed by introducing
   `lastSyncCompletionDate: Date?`, stamped only at the point a sync run actually finishes
   (success or per-file errors already logged), and read (not `Date()`) by `refreshStatistics()`.
   Reset to `nil` on `shutDown()` so disabling and re-enabling doesn't show a stale time before the
   first real run completes.
2. **`lastError` was never cleared.** `record(_:during:)` sets it on a failed remote fetch or a
   failed `clearCloudData()`; nothing ever reset it, so one transient failure left red error text in
   the settings footer for the rest of the session even after a later sync succeeded cleanly. Fixed
   by clearing `lastError` at the top of every `runSync`, so a fresh trigger gets a fresh chance to
   report cleanly, and on `shutDown()`.

Both are one-line-per-fix, `swift test`-invisible, and were only findable by tracing what actually
calls `refreshStatistics()`/`record()` and in what order — see
`Source/iOS/App/Common/Services/CloudSyncCoordinator.swift`.

## Test gap found and filled

The task brief asks for unit tests on "classification, conflict resolution, and path mapping."
Classification and conflict resolution were already covered; **path mapping had no dedicated test
file**, despite `CanonicalRelativePath`'s own doc comment describing three real bugs the naive
version shipped (mixed `/private/var` vs `/var` forms, `replacingOccurrences`' replace-all instead
of replace-prefix, and the record-name identity implications of getting either wrong). Added
`Source/iOS/PVCloudSync/Tests/PVCloudSyncTests/CanonicalRelativePathTests.swift`, 7 tests, covering:
direct child, the private/var-vs-var convergence (using real files under `/tmp`, since
`resolvingSymlinksInPath()` only collapses components that exist on disk), a root path recurring
inside the relative portion, file-outside-root, file-is-the-root, sibling-with-prefixed-name, and a
deeply nested path. All pass.

## Item (d): entitlements/capability declarations — deliberately NOT applied

The task brief asks to add "entitlements/capability declarations in Project.swift for iOS and tvOS."
Two corrections to that premise, both load-bearing:

1. **Entitlements do not live in `Project.swift`.** `Project.swift:283` sets `entitlements: nil` on
   the app target and configures `CODE_SIGN_ENTITLEMENTS` per build configuration instead
   (`Project.swift:50`), pointing at four separate `.entitlements` plists that already cover every
   shipping configuration for the app's multi-platform destinations
   (`[.iPhone, .iPad, .appleTv, .macWithiPadDesign, .macCatalyst, .appleVisionWithiPadDesign]`,
   `Project.swift:217`) — iOS and tvOS both included, one universal target.
2. **The patch that adds the CloudKit entries to those four files already exists**, staged and
   verified applicable (`git apply --check docs/cloudkit-entitlements.patch` exits 0 in this
   worktree), at `docs/cloudkit-entitlements.patch`. It is deliberately **not applied**, and should
   stay that way until the container is provisioned. Applying it now would request
   `iCloud.com.joemattiello.iCube` in every entitlements file while
   `CloudKitAvailability.containerIsProvisioned = false` and the container does not exist in the
   Apple Developer account — that breaks code signing for every real (non-`CODE_SIGNING_ALLOWED=NO`)
   build anyone makes, for zero functional gain (the code-level switch would still be off).

The container id the code already names, and that the patch and the settings copy consistently use,
is `iCloud.com.joemattiello.iCube`, matching the task brief's suggested identifier. No change needed.

**What the maintainer must do**, restating the checklist at the top of
`docs/cloudkit-entitlements.patch`:

1. Create iCloud container `iCloud.com.joemattiello.iCube` in the Apple Developer account, and
   enable it on all eight bundle IDs listed in that file's header comment.
2. Apply `docs/cloudkit-entitlements.patch` and flip
   `CloudKitAvailability.containerIsProvisioned = true` — both are required together.
3. Build to a device, create the CloudKit schema by letting one record upload, then deploy the
   schema to Production before any App Store build.
4. Verify: Settings → iCloud Sync should read "Up to date" rather than "not available in this build
   yet."

## Remaining low-priority items, not fixed (out of scope for this pass)

- `CloudSyncLifecycleService` reconstructs the emulation-start/end notification names as
  `Notification.Name("DOLEmulationWillStartNotification")` string literals rather than importing the
  `NSNotificationName` consts declared in `EmulationCoordinator.h`
  (`DOLEmulationWillStartNotification` / `DOLEmulationDidEndNotification`), which is a literal
  reading of the "no magic strings" convention in the root `CLAUDE.md`. This is **not a regression
  introduced by WS-5** — `WebServerLifecycleService.swift` does the exact same thing for the same two
  notifications, so it is an established (if non-compliant) pattern in this codebase, not something
  WS-5 invented. Fixing it means either exposing the ObjC consts through the Swift bridging header
  (would touch a shared header other features depend on) or duplicating a `Notification.Name`
  extension — either is a small, separate, cross-cutting cleanup better done once for both call sites
  than piecemeal inside a CloudKit sync pass.
- No dedicated unit test exists for `CloudSyncCoordinator` itself (the `@MainActor` app-target glue
  class). It is intentionally kept thin — every rule lives in the tested `PVCloudSync` package — but
  the two bugs fixed above show glue is not risk-free. Out of scope for this pass because
  `CloudSyncCoordinator` lives in the app target (Tier 6), which has no standalone `swift test` path
  per this repo's module tiers; exercising it would need either an XCTest target wired into the Xcode
  project or extracting more of its sequencing into a testable, non-`@MainActor`, non-UIKit type.

## Design note: iCloud Drive (ubiquity container) as an alternative or complement

The task asks for a design note — not code — on whether iCube should also offer an iCloud Drive
(ubiquity container / Files-app-visible folder) path for save data, for iOS today and a future native
macOS build.

**Recommendation: complement, never replace, and only build it when a native macOS target exists.**

### Why it can't replace CloudKit here

iCube ships on **tvOS** (`Project.swift:217` includes `.appleTv`), and tvOS has no Files app and no
user-visible ubiquity container — there is nowhere for "drag your save into iCloud Drive" to appear.
Any iCloud Drive path is iOS/iPadOS/macOS-only by construction, so it can only ever be one option
among several, with CloudKit (or nothing) covering tvOS. That alone rules out "replace."

### Why it's not obviously worth building yet

- **Two sync engines over the same files is two writers.** `TimestampConflictResolver` reasons about
  exactly two sides (local vs. one `SyncProvider`). A `NSFileCoordinator`/`NSMetadataQuery`-backed
  ubiquity folder writing the same `User/StateSaves/` tree at the same time is a third writer the
  conflict model has no concept of — it would need either a second provider merged into the same
  planner (nontrivial: `SyncPlanner.plan` takes exactly one `local` and one `remote` snapshot) or a
  strictly separate directory tree (e.g. `User/iCloudDriveExport/`) that the user copies into
  manually, which is closer to an export feature than a sync feature.
- **Download-on-demand changes the file-presence contract.** Files in an `NSFileProvider`/ubiquity
  container can be present-as-placeholder (`.icloud` stub) until downloaded. `UserDataScanner` and
  `SyncClassifier` currently assume a file that exists is fully readable; a ubiquity-backed directory
  would need `NSFileCoordinator` reads and eviction-awareness added throughout the scan path.
- **Cost of entry**, concretely: `com.apple.developer.ubiquity-container-identifiers` (the patch at
  `docs/cloudkit-entitlements.patch:98` deliberately excludes this key today, on the grounds that
  iCube uses CloudKit records, not a document container), `NSUbiquitousContainers` in `Info.plist`,
  and replacing or supplementing `DirectoryWatcher`'s `DISPATCH_SOURCE_TYPE_VNODE` watching with
  `NSMetadataQuery` for the ubiquity side.

### Where it's genuinely worth having

- **A future native macOS build** (tracked separately, not part of this repo's roadmap docs today) is
  the strongest case: a Mac user reasonably expects "my saves are just a folder I can see, back up
  with Time Machine, or grep," which CloudKit's opaque per-record model cannot offer. An
  iCloud-Drive-visible folder is closer to what desktop Dolphin users already do by hand.
- **Manual export/import, not automatic sync**, is the safer shape even then: a "Reveal in iCloud
  Drive" / "Export saves…" action that copies the same allow-listed tree
  (`SyncClassifier`-filtered, so the "no ROM ever leaves the device" guarantee is inherited for free)
  into a ubiquity container on demand, leaving CloudKit as the only thing that runs unattended. This
  sidesteps the two-writer conflict problem entirely — there is only ever one writer per direction,
  triggered by the user, not two background engines racing each other.
- **The seam to build it on already exists.** `SyncProvider` is a protocol with one real
  implementation (`CloudKitSyncProvider`) and one inert stand-in
  (`InertSyncProvider`) — iFly is on record (per the WS-5 planning doc) as having exactly this shape,
  with a second provider it swaps to when CloudKit is unusable. An iCloud-Drive-backed `SyncProvider`
  is the natural extension point if this is ever pursued as real sync rather than export, but nothing
  in the current code should be restructured pre-emptively for a feature with no target platform yet.

**Bottom line:** don't build it now. When a native macOS target lands, revisit as a manual
export/import surface first (cheap, no conflict model needed, inherits the classifier), and only
consider a second live `SyncProvider` if manual export turns out to be insufficient in practice.
