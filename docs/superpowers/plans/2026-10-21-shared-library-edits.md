# Shared Library Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Converge custom titles, covers and searchable tags between iCube and Provenance, including consenting nearby peers on different accounts.

**Architecture:** Extract iCube's existing canonical store into an independent PVLibraryMetadata product. Bind Provenance records to verified identities and expose a common effective projection. Add separately authorized nearby metadata transport and a metadata-only same-account adapter, retaining existing ROM and saved-progress behavior.

**Tech Stack:** Swift 5.9+, Foundation, CryptoKit, existing PVCloudSync/PVContinuity/PVLibrarySharing, Realm adapters, CloudKit, SwiftUI/UIKit, Dolphin DiscIO.

**Spec:** [Approved design](../specs/2026-10-21-shared-library-edits-design.md).

## Global Constraints

- Titles 200 characters; at most 32 tags of 40 characters; artwork 256 KiB; shard 1 MiB.
- Retain canonical identities, existing shard bytes and `Profiles/LibraryMetadata/<hash>.json`; explicit null clears and field timestamps survive transport.
- Pure PVLibraryMetadata depends only on Foundation/CryptoKit; no UIKit, Realm or CloudKit dependency.
- Nearby requires both apps open, separate per-peer opt-in and remote authorization. Pairing/ROM access never grants edit access.
- Match verified game/disc/revision or SHA-256 content identities; never guess from filename, MD5, serial or missing disc/revision.
- No network await inside file or permission locks. Revocation must prevent stale commits, not merely cancel requests.
- Preserve unknown fields, local edits while exchange is disabled, catalog fallback, legacy save/ROM protocols and unrelated cloud documents.
- Do not edit cached package checkouts. Use writable package clones and reviewed commits. Preserve concurrent app work.
- Current iCube iOS/tvOS uploads and ASC processing retain delivery priority. Isolated shared-package work may proceed while hosted builds run; integrate consumer changes after that delivery gate. Receiver PR #3753 must pass SDK integration before cross-app acceptance.
- Physical device operations remain deferred until the owner opens another testing window.

## Review Focus

- Replaced/reimported ROM at the same path must invalidate its verified binding (Task 4).
- Revocation while a response is awaiting a file write must prohibit that write and success publication (Tasks 3/6).
- A backwards device clock or equal field timestamps must not erase newer fields or cause transfer loops (Tasks 1/2).
- Background/account switches during import must not bind metadata to another account or publish stale results (Tasks 4/7).
- A library larger than one manifest page must converge without retaining unknown covers or omitting later games (Tasks 3/6).

## Repository and release map

Use writable clones under `/Users/jmattiello/Workspace/Provenance/ReleaseWork/`, branches `codex/shared-library-metadata`. iCube paths below are relative to this repository; Provenance paths are relative to `/Users/jmattiello/Workspace/Provenance/Provenance`.

PVCloudSync starts at 1.0.0 (`82ff294c772c79029312fda12a943760b934c9de`); publish additive product release **1.1.0** after Tasks 1–2. Keep PVSyncRules **1.0.2** (`692ca3a1a84cb713c42bf775d5558c97d0bf05d3`). Publish PVContinuity **1.1.0** after Task 3. Record actual release commit hashes at publication; never invent future pins. Consumers require these minimum releases and record resolved hashes in acceptance evidence. Existing package floors remain iOS/tvOS 17 and macOS 14.

Each task below has its own failing-test cycle, scoped commit and independent review. Task 1 is a mechanical extraction before adding transport API. Tasks 3 and 4 may proceed independently after Task 2; consumer UI/projection work follows verified bindings. A green host test does not close an installed acceptance gate.

### Task 1: Extract the byte-compatible store

**Files:** PVCloudSync `Package.swift`; create `Sources/PVLibraryMetadata/LibraryMetadataStore.swift`, `Tests/PVLibraryMetadataTests/LibraryMetadataStoreTests.swift`, `LibraryMetadataCompatibilityTests.swift`, `Fixtures/`. Source of truth: iCube `Source/iOS/App/Common/Swift/LibraryMetadataStore.swift` and `DolphiniOSTests/LibraryMetadataStoreTests.swift`.

**Interfaces:** Public `LibraryMetadataStore: @unchecked Sendable`, nested `Identity`, `Draft`, `Summary`, `CacheStatistics`, `StoreError`, `FileAccess`, `Writer`. Preserve every current initializer label/default and method signature: `summary(for:)`, `draft(for:)`, `commit(_:baseline:for:at:)`, `reload()`, `cacheStatistics()`, `validateDocument(data:filename:)`, `isValidShardFilename(_:)`. Expose read-only summary/cache properties and explicit public initializers where needed; keep arbitrary identity initialization private.

- [x] Capture fixed-date original-store bytes for title/cover/tags/nulls, game/disc/revision and content-hash identities before moving code. Commit immutable fixtures, not expectations regenerated by the implementation under test.
- [x] Port all 32 current store tests with only module import changes; add `testGoldenBytesRemainIdentical`, `testUnknownPrimitiveTieIsCommutative`, `testBackwardClockAdvancesObservedField`, `testRecoveryFailureKeepsPrimaryAndCache`. Assert existing normalization/order and all five exact limits.
- [x] Run `swift test --package-path <PVCloudSync clone> --filter PVLibraryMetadataTests`; initially fail because the new product is absent.
- [x] Move the entire synchronous store, retain copyright/SPDX, add public access and independent product/test targets. Preserve 16 MiB/64 full-record and 4 MiB/8192 summary caches, no cover decode on summary, recovery-before-commit and injected file gate semantics. Do not replace JSONSerialization with Codable or an actor.
- [x] Repeat the targeted command: all ported and compatibility tests pass; run existing PVCloudSync tests too. Commit `feat: extract compatible library metadata store`; independent review checks fixture provenance and API access.

### Task 2: Shared merge kernel and atomic transport boundary

**Files:** Create PVCloudSync `Sources/PVLibraryMetadata/LibraryMetadataDocument.swift`, `LibraryMetadataCommitGate.swift`, `LibraryMetadataExchange.swift`, `Tests/PVLibraryMetadataTests/LibraryMetadataDocumentTests.swift`, `LibraryMetadataCommitGateTests.swift`; modify extracted store. iCube: `Common/Swift/LibraryMetadataStore.swift`, `Common/Services/CloudSyncCoordinator.swift`, `Source/iOS/App/Project.swift` and existing store tests.

**Interfaces:** `LibraryMetadataDocument.validate(data:filename:)`, `draft(from:for:)`, `summary(from:for:)`, `merge(local:remote:for:)`, `merge(local:remote:filename:)` all throw and return the existing Draft/Summary or Data. Store adds `exportDocument(for: Identity) throws -> Data` and `mergeDocument(_ data: Data, for: Identity) throws -> Data`. `Identity.parseCanonical(_ raw: String) -> Identity?` accepts only exact round-tripping canonical strings. `LibraryMetadataCommitGate.issue() -> Permit`, `invalidate()` and `withPermit<T>(_: Permit, operation: () throws -> T) throws -> T` use a synchronous generation lock.

- [ ] Add tests asserting associative/commutative/idempotent merge, explicit clears, unknown primitive ties, numeric/ISO/finite-string timestamps, invalid identity/filename and oversized documents. Exercise export/merge failed writes preserving cache/primary, no restamping and recovery. Add a barrier test: invalidation returning before a blocked callback resumes means no write occurs.
- [ ] Run package tests and new app metadata dispatch tests before implementation; verify failures identify missing APIs or wrong generic-merger behavior.
- [ ] Factor the existing fragment-safe, finite-timestamp merger into the pure kernel; use it from recovery and export/merge. Permission lock order is grant then file gate; no reverse acquisition. Keep permissive historical decode compatibility; reject invalid incoming known-field stamps at the new wire boundary without rewriting historical files.
- [ ] Publish tested PVCloudSync 1.1.0. Replace iCube implementation with an import/typealias and add product to app/test dependencies. At **both** CloudSyncCoordinator merger-selection seams select the shared kernel only for `SyncClassifier.isLibraryMetadataShard(relativePath:)`; preserve other profile merge behavior. Update the native harness to link the package with macOS 14 floor.
- [ ] Run package suite, all 32 app compatibility tests, targeted cloud scanner merge tests, then iOS/tvOS app SDK builds using existing cached-core dev loop. Record published/resolved hash; commit `feat: share canonical library metadata transactions`.

Shared wire models must be included **before** the Task 2 PVCloudSync 1.1.0 publication: immutable Sendable/Codable `LibraryEditsManifestEntry(identity: String, digest: String, evidence: LibraryEditsContentEvidence)`, `LibraryEditsManifestPage(entries: [LibraryEditsManifestEntry], nextCursor: String?)`, `LibraryEditsDocument(identity: String, document: Data)`. `LibraryEditsContentEvidence` contains `sha256: String?`, `byteCount: UInt64` and `kind: .disc | .content`; disc identity itself carries verified game/disc/revision. Require lowercase 64-hex digests when present and nonzero byte count. Content-hash identities require matching SHA evidence; disc identities may use a stat-bound verified DiscIO header without hashing the whole image merely to exchange metadata. Capture SHA evidence from the existing verified-file receipt/hash pipeline when available; never use filenames/serials. Imports still require full authenticated SHA verification. Wire round-trip/invalid-evidence tests belong to Task 2 and run before release. A remote declaration is not local proof: match an independently verified local identity, or verify received bytes against the advertised digest before accepting an import binding.

### Task 3: Separately authorized nearby protocol

**Files:** PVLibraryMetadata: consume the wire models published by Task 2. PVContinuity: create `Model/ContinuityLibraryEdits.swift`, `Trust/ContinuityLibraryEditsGrantStore.swift`, `Server/ContinuityLibraryEditsServer.swift`, `Client/ContinuityLibraryEditsClient.swift`, matching tests; modify Package.swift, ContinuityRoutes.swift, ContinuityLibraryServer.swift and discovery capability model.

**Interfaces:** Consume Task 2’s published `LibraryEditsManifestEntry`, `LibraryEditsManifestPage`, `LibraryEditsDocument` and `LibraryEditsContentEvidence`. Inject a provider with `manifest(after: String?, limit: Int) async throws -> LibraryEditsManifestPage`, `read(identity: String) async throws -> Data`, `merge(identity: String, document: Data, permit: LibraryMetadataCommitGate.Permit) async throws -> Data`. Peer identity remains the existing authenticated paired-peer type, never a caller-supplied free string.

- [ ] Add tests `testROMGrantCannotAuthorizeEdits`, `testEditsGrantDoesNotAuthorizeROM`, `testOldPeerRemainsUsable`, `testRevokedResponseCannotCommit`, `testManifestPaginationBeyond128`, `testWrongIdentityAndOversizedEnvelopeRejected`. Assert tokens cannot be replayed by another peer and cancellation never publishes success.
- [ ] Run PVContinuity targeted tests before implementation; confirm new capability/routes fail.
- [ ] Advertise additive `libraryEditsV1`. Add `/api/continuity/library/edits/auth/start`, `/auth/complete`, `/manifest`, `/document`, `/merge` using existing pairing challenge/signature primitives with distinct metadata-scoped tokens and grants. Do not require ROM read consent. Bounds: 128 entries/page, manifest 256 KiB, document envelope 2 MiB, decoded shard 1 MiB; reject invalid cursors/identities before provider invocation.
- [ ] Make final store merge execute under the current permit; invalidate on revoke/disconnect/background. Return committed digest/document, use SHA-256 of canonical bytes for no-op detection. Never expose paths or automatically import ROMs.
- [ ] Run all protocol/auth tests and legacy ROM wire fixtures, then publish PVContinuity 1.1.0 and record commit. Commit `feat: authorize nearby custom library edits separately`.

### Task 4: Verified Provenance identity binding

**Files:** Provenance: create `Cores/Dolphin/PVDolphinCore/Core/PVDolphinCore+LibraryIdentity.h/.mm`, modify `Cores/Dolphin/Package.swift` explicit bridge sources and `Sources/PVDolphinBridge/include/module.modulemap`; create `PVLibrary/Sources/PVLibrary/Services/LibraryMetadata/LibraryMetadataIdentityBinding.swift` and tests under `PVLibrary/Tests/PVLibraryTests/`. Integrate successful hash-verified receipts in nearby import completion adapters from PR #3753.

**Interfaces:** Dolphin class method `+ (nullable NSDictionary<NSString *, id> *)libraryDiscIdentityAtPath:(NSString *)path error:(NSError **)error` returns `gameID: String`, `discNumber: NSNumber`, `revision: NSNumber` from a newly opened DiscIO volume without starting emulation. PVLibrary `LibraryMetadataIdentityBinding` accepts an injected async reader closure `(URL) async throws -> VerifiedDiscIdentity?` (`VerifiedDiscIdentity` is an immutable Sendable struct with `gameID: String`, `discNumber: Int`, `revision: Int`), persists local game identifier + canonical identity + file stat/content evidence, and `identity(forLocalGameID: String) async throws -> LibraryMetadataStore.Identity?`. Reader registration belongs in the app's core-loading integration, avoiding PVLibrary → Dolphin dependency.

- [ ] Add tests for disc 1/2 and revision differences, same-name different files, replaced file at same path, failed/missing reader, interrupted import and stale completion after deletion. Assert unresolved stays nil, never assumed zero. Reader fixtures include supported ISO/GCM/RVZ and owned/homebrew files.
- [ ] Run identity tests before implementation; prove serial/MD5-only records cannot bind.
- [ ] Implement read-only DiscIO reader and durable stat-bound bindings. Use authenticated SHA-256 verified transfer receipts only after successful registration; revalidate file evidence before reuse. Hash supported homebrew off the main actor with bounded streaming. No Realm object crosses an await.
- [ ] Run bridge SDK builds and native binding tests; verify in both import directions using fixture files. Commit `feat: bind custom metadata to verified library identities`.

### Task 5: Provenance effective metadata and editing

**Files:** Create `PVLibrary/Sources/PVLibrary/Services/LibraryMetadata/LibraryMetadataService.swift`, `LibraryMetadataProjection.swift`, tests; modify `PVUI/Sources/PVSwiftUI/Consoles/GameCellModel.swift`, `ConsoleGamesViewModel.swift`, `ConsoleGamesView+GameContextMenuDelegate.swift`, `PVUI/Sources/PVUIBase/SwiftUI/GameItem/GameItemPresentable.swift`, `PVGame+GameItemPresentable.swift`, legacy `RomDatabase.rename`, `SwiftDataGame_Data` and `CloudKitRomsSyncer` adapters at their existing declarations.

**Interfaces:** Service wraps shared store and Task 4 binding. `effectiveMetadata(forLocalGameID: String, fallback: LibraryMetadataFallback) async throws -> LibraryMetadataProjection`; define immutable Sendable `LibraryMetadataFallback(title: String, coverData: Data?, tags: [String])` and `LibraryMetadataProjection(title: String, coverData: Data?, tags: [String], identityState: LibraryMetadataIdentityState)`, with `.pending` and `.verified(LibraryMetadataStore.Identity)` states. Editing uses shared `Draft` and `commit(_:baseline:for:at:)`; only local user actions create timestamps. Publish changed local IDs through existing library observation, never store managed Realm objects in snapshots.

- [ ] Add tests for title/art fallback, searchable/sortable overrides, clear restoring fallback, cancel/write failure, restart/cache eviction and legacy cloud refresh preserving overrides. Test explicit legacy adoption fills only absent overrides; catalog titles are not adopted automatically.
- [ ] Run targeted projection/editor tests before wiring; expect fallback-only readers to fail override assertions.
- [ ] Wire cards, details, UIKit/tvOS, search/sort, editor entry points and nearby previews to one projection. Keep tags separate from genres/hidden markers. Normalize artwork through bounded image adapters before commit/display. Expose unresolved identity and explicit legacy-adoption action. Inventory actual reader/writer call sites with rg and record each covered adapter in evidence.
- [ ] Run PVLibrary/PVUI tests plus iOS/tvOS SDK checks. Commit `feat: project shared library edits throughout Provenance`.

### Task 6: Foreground bidirectional nearby synchronization

**Files:** iCube create `Common/Continuity/NearbyLibraryEditsService.swift`, tests; modify ContinuityManager.swift, ICubeLibraryProvider.swift and `UI/ContinuityLibrarySharingView.swift`, `ContinuityPeerLibraryView.swift`. Provenance create `PVLibrarySharing/Sources/PVLibrarySharing/Server/Dialects/ICubeLibraryEditsServer.swift`, client adapter, tests; modify Package.swift, ICubeDialectServer.swift, ICubeContinuitySource.swift and NearbyLibraries service/UI.

**Interfaces:** Per-app `NearbyLibraryEditsService` consumes Task 3 client/provider, Task 4 bindings, shared store and permit gate. Public `setEnabled(_ enabled: Bool, for peer: PVContinuity.TrustedPeer) async throws`, `syncNow(for peer: PVContinuity.TrustedPeer) async throws`, `stop()` in iCube; the Provenance adapter uses its existing `PVLibrarySharing.TrustedPeer` with the same method labels; observed peer state reports unavailable/waiting/syncing/error, last successful time and effective local/remote grants.

- [ ] Add host cross-dialect tests for two different accounts, independent fields, competing edits/nulls, initial existing edits without restamping, import-then-match, unknown games without artwork fetch, >128 games, intermittent failure/backoff, repeated cursor, revoke during write and stale success after stop. Add `testEmulationStartDefersHashAndTransport`, `testEmulationEndResumesFreshDigest` and `testBackgroundDuringDeferredImportDoesNotPublish`.
- [ ] Run tests before transport wiring and confirm no edits exchange under ROM-only permissions.
- [ ] Add default-off **Sync Custom Library Edits** confirmation explicitly covering existing and future custom edits for matched games. Require both grants. Sync immediately after local commit/import, debounce changes and poll manifests every ten seconds only while foreground/reachable. Serialize each peer's pass; bounded retries back off to 60 seconds. Digest equality stops loops. Mirror existing emulation deferral: iCube observes `EmulationState.shared` transitions and `SyncLocalIOGate.shared.isEmulating`; Provenance observes `AppState.shared.$emulationUIState` and `GameImporter.shared.isPausedForEmulation`. Emulation entry invalidates permits, cancels transfers/hashing and shows waiting; local editor writes remain enabled. Emulation exit resumes with fresh manifests/permits only if still foreground and authorized. Stop invalidates permits before cancellation; restart obtains fresh ones. Keep ROM controls separate.
- [ ] Run legacy and new protocol suites, both SDK builds and host end-to-end fixture exchanges. Record exact package hashes; commit each consumer's adapter independently with its interoperability evidence.

### Task 7: Same-account metadata-only adapter

**Files:** Create Provenance `PVLibrary/Sources/PVLibrary/Services/LibraryMetadata/LibraryMetadataCloudSync.swift`, `LibraryMetadataCloudIndex.swift`, associated tests; wire app account/foreground ownership and settings. Reuse PVCloudSync client interfaces, not iCube's entire scanner.

**Interfaces:** `LibraryMetadataCloudSync.start(accountIdentifier: String) async throws`, `stop()`, `syncNow() async throws`; injected metadata-only scanner can enumerate/read/write exclusively `Profiles/LibraryMetadata/` canonical shards. Account-bound index persists digests and change tokens; account generation gates all local commits and publication.

- [ ] Add tests asserting every requested record/path is a canonical metadata shard; no saves/ROM/settings/firmware access or zone purge. Account switch during download/import invalidates commits and resets only that account's index. Test signed-out/retry states and preserved local edits when disabled.
- [ ] Run fake-provider adapter tests before implementation; fail on any nonmetadata request.
- [ ] Implement explicit preference and metadata-only existing-private-zone access. Use the shared kernel and account permit immediately before commit. Verify actual entitlement/container membership before enabling production acceptance; do not silently change signing entitlements.
- [ ] Run host adapter tests and both app SDK builds. Commit `feat: synchronize shared library edits within the same account`.

### Task 8: Release evidence and installed acceptance

**Files:** Create `docs/app-store/release-evidence/2026-10-21-shared-library-edits.md`; update `docs/app-store/RELEASE-PLAN.md`, `docs/HANDOFF.md` and counterpart PR description.

**Interfaces:** Evidence identifies exact source/package commits, device/app versions, Production CloudKit account/container, peer grants, transfer receipts and per-scenario result. No acceptance box may cite a host-only test as a physical result.

- [ ] Run full shared-package suites, app tests, existing nearby/import suites and iOS/tvOS SDK builds after the final integrated source is frozen. Confirm receiver PR #3753 checks against its current head and review before merge.
- [ ] After the owner resumes physical testing, verify iPhone/iPad/Apple TV editing, both app directions, same-account Production CloudKit and different-account nearby. Exercise offline edits/reconnect, revoke, import, clear, concurrent fields, restart, unsupported peers and unresolved identities. Preserve real saves and use disposable owned fixtures.
- [ ] Build signed release candidates, verify app/core identity and entitlements, upload both platforms, wait for ASC VALID and intended group availability, and record Sentry app/core symbols. Reconcile an existing uploaded build before any archive retry.
- [ ] Review uncovered failures against the approved design; retain all outstanding gates in release tracker. Commit evidence only for observed results. App Store submission remains a separate owner action.

## Self-review

Coverage: owner UX/consent → Tasks 5–6; canonical bytes/merges → 1–2; identity → 4; nearby/old peers → 3/6; same-account isolation → 7; installed matrix → 8. Interfaces keep the synchronous store boundary and use existing paired-peer types. All five Review Focus conditions have named tests. No implementation, package release, device acceptance or new TestFlight completion is claimed by this plan.
