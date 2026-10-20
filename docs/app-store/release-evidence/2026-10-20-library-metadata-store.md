# Custom library metadata store evidence — 2026-10-20

The owner requires custom titles, custom covers and classification tags. This implements their persistence model, separate from resettable emulator game profiles. UI/bridge and actual device acceptance are independent work.

## Current shard contract

- Store root: `<UserFolder>/Profiles/LibraryMetadata/`. Each game's filename is lowercase SHA256 of its opaque identity, followed by `.json`; no path/title/filename aliases are used for unidentified homebrew.
- Identified discs use trimmed, uppercased gameID + discNumber + revision. Unidentified homebrew requires caller-supplied SHA256 content identity; the store does not hash ROMs during scans.
- A shard contains flat opaque records keyed `<identity>:title`, `:cover`, `:tags`. Every changed field has numeric `updatedAt` reference-date seconds and `value`. Title is string/null, cover is base64/null, tags string-array/null. Explicit clears retain null tombstones. Numeric stamps advance beyond the prior field stamp even when the clock moves backward or edits occur within one second.
- Limits: title 200 characters; at most 32 case-insensitively deduplicated tags of 40 characters each; cover bytes 256 KiB; complete shard 1 MiB. Whole-library size has no aggregate cap.
- Unknown records and fields round-trip. Filename-aware validation rejects known records whose identity hash does not match the shard name. Cloud validation rejects malformed types/oversized cover/shard data.

`LibraryMetadataStore.init(directoryURL:withFileAccess:write:)` uses lazy per-identity loading. `draft(for:)` returns a cached typed projection, sharing immutable cover Data across repeated title/tag/sort lookups; `reload()` invalidates cached projections so the next read reloads only the needed shard. If that refresh fails, it throws while retaining the last valid cache. `commit(_:baseline:for:at:)` reloads only the selected shard under the injected shared file-access gate and changes only fields differing from the captured edit baseline; unrelated concurrent edits survive. Atomic write finishes before memory publication. Failed decode, validation or write leaves the previous durable/cache record intact. Missing files are not clear operations: a cached session retains unedited fields after a purge.

Root integration injects `LibraryStateStore.withFileAccess` into the gate. No network I/O belongs inside that gate. `validateDocument(data:filename:)`, `maxDocumentBytes` and `isValidShardFilename` are available for the sync scanner/provider. `Identity.fileName` defines the stable filename.

## Native production regression evidence

```sh
python3 Source/iOS/App/Project/Scripts/test_library_metadata_native.py
```

Optional `--work-directory /tmp/icube-library-metadata-audit` retains SwiftPM cache. The harness links the actual production Swift source and existing repository XCTest file; it uses Foundation + CryptoKit, with no UIKit/core dependency.

- [Initial red](2026-10-20-native/library-metadata-red.log): three actual assertions failed for missing normalization and reopen persistence against API-only stub.
- [Shard-isolation red](2026-10-20-native/library-metadata-shard-red.log): monolithic implementation rewrote the first game's bytes and created one file instead of two.
- [Typed-record red](2026-10-20-native/library-metadata-typed-record-red.log): malformed typed data replaced the prior valid projection during reload.
- [Missing-shard red](2026-10-20-native/library-metadata-missing-shard-red.log): losing a file during the session dropped unedited title/cover on the next save.
- [Serial case-normalization red](2026-10-20-native/library-metadata-case-red.log): case variants initially produced different identities/shards; now normalize to the same disc.
- [Projection allocation red](2026-10-20-native/library-metadata-projection-red.log): repeated draft reads allocated distinct retained 256 KiB cover buffers; typed projection caching now shares immutable Data storage.
- [Final green](2026-10-20-native/library-metadata-green.log): **18 XCTest tests, zero failures/skips**.

Coverage includes normalize/save/reopen; uncommitted cancel; independent-field concurrent edits; retained clears/clock rollback; invalid bounds/write failure/corrupt JSON preservation; unknown fields; disc/revision/content identity separation; maximum field values; no-op byte stability; independent shards; filename/type/cloud-size validation; missing-shard preservation. Injected write failure proves the transaction does not publish success before its writer succeeds; production defaults to atomic Foundation Data.write.

No iOS/tvOS SDK build, installed UI, photo import/reencoding, cross-device merge or cross-app metadata acceptance is established by these host tests. The pinned provider's path classification requires the coordinated shared-package amendment; app-only scanner classification cannot establish delivery.


## Service review follow-up and SDK gates

Current reruns after synthetic homebrew-ID normalization: **18 metadata/store tests and 12 mirror scheduler tests pass, zero failures/skips**. The durable green logs above contain the current source run.

`Identity.game` now rejects empty, `<unknown>` and `ID-<basename>` placeholders. The UIKit service also rejects ELF/DOL raw platform 4 as a disc identity. Persistent homebrew content receipts use a complete Codable filesystem fingerprint (device/inode/size/mtime/ctime with nanoseconds); both cached reuse and pre/post streaming-hash checks require equality. This avoids assigning one executable's edits to different same-size bytes with a preserved modification date. [Placeholder red](2026-10-20-native/metadata-homebrew-placeholder-red.log) failed four assertions; the one Foundation service-test case then passed alongside the 18 store tests ([19-test log](2026-10-20-native/metadata-homebrew-placeholder-green.log)).

Warming retains the latest library items, cancels on background/emulation and retries on foreground/current physical drain. A single retry flag preserves a foreground/drain event arriving while a canceled hasher is still unwinding. `python3 Source/iOS/App/Project/Scripts/test_metadata_warming_native.py` executes the exact production warming methods with controlled UIKit/lifecycle/hash boundaries. [Red](2026-10-20-native/metadata-warming-retry-red.log) reproduced a dropped retry (one hash call instead of two); [green](2026-10-20-native/metadata-warming-retry-green.log) resumes exactly once. This seam is lifecycle policy evidence, not a UIKit/device test.

New `DolphiniOSTests/LibraryMetadataServiceTests.swift` contains **eight SDK test cases**: one Foundation placeholder case already ran natively; **seven UIKit cases and the complete SDK execution remain pending** after project regeneration. They cover preserved-mtime replacement invalidation, ELF/DOL identity, rename/content identity, canceled hash publication, bounded synced-cover pixels, bounded cover preparation and invalid/oversized artwork. No installed-editor Save/Cancel or real photo/URL interaction result is claimed. Root owns the SDK build/run and editor integration.

Cross-app scope remains explicit: iCube CloudKit shards are separate from ROM-only nearby protocol v1. Display names/artwork can appear in browse results, but custom title/art/tag edit convergence with Provenance needs an approved shared metadata transport/receiver contract. ROM copying tests cannot close that gate.
