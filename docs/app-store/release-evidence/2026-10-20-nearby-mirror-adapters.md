# Nearby mirror adapter regressions — 2026-10-20

## Fixes

1. Peer identity consistency: `PeerBoundContinuityTransport` checks successful library/handoff auth-start response `serverId` against the selected advertisement's nonnil `peerId` before signing/auth-complete. Browse and Receive controllers set the context on each load. Browse reload invalidates the old endpoint token so a changed peer selection cannot reuse cached auth. Legacy advertisements without an ID retain their existing behavior; automatic sources require a stable trusted ID.

This check does not provide cryptographic server authentication. Existing LAN HTTP responses are unsigned and transport remains subject to its documented trusted-network limitation. No protocol codec/schema has changed.

2. Manifest-aware receipts: a catalog key identifies game/disc/revision, not bytes. `NearbyLibraryMirrorService` now fetches a fresh ROM-only manifest for every previously receipted entry before considering a skip. `ContinuityVerifiedFileReceipt` compares remote descriptor paths, kinds, hashes and sizes plus every local file fingerprint. A missing secondary file or changed remote bytes cannot be hidden by equal catalog size. Browse exposes `validatedManifest(for:)` and `verifiedDescriptors`; only a verified registered copy can produce the receipt. Manifest validation rejects user-data payloads, duplicate paths and another game's identity.

3. Served-file digest cache: `ContinuityPaths.describe` now uses `ContinuityFileDigestCache`. A digest is reused only for unchanged device/inode/size/mtime/ctime including nanoseconds. Hashing never holds the dictionary lock; publication requires identical pre/post-hash fingerprints. Changed metadata or read/hash errors invalidate the entry. Concurrent readers are supported. Source hashing therefore occurs again after an actual file change, rather than on every 60-second mirror poll.

## Reproduce native production tests

```sh
python3 Source/iOS/App/Project/Scripts/test_continuity_controllers.py /absolute/path/to/SourcePackages/checkouts --include-package-tests
```

The harness links pinned PVContinuity/PVSyncRules/PVWebServer read-only. It compiles actual production controllers, transports, file providers, digest/receipt helpers, with host-only substitutes for UIKit/ObjC application bridges. It does not replace pinned crypto, clients, codecs, planners or pullers.

- [Auth red](2026-10-20-native/nearby-mirror-peer-binding-red.log): actual clients accepted another selected peer's challenge and reached catalog/handoff work; two new tests failed four assertions.
- [Receipt/cache red](2026-10-20-native/nearby-mirror-receipt-cache-red.log): equal-key/size changed remote checksum skipped collision detection; unchanged file was hashed twice. Two expected failures.
- [Final green](2026-10-20-native/nearby-mirror-adapter-green.log): **208 pinned package tests + 35 controller/native tests = 243 passed, zero failures/skips**.

Additional coverage: matching selected peer works; changed selection cannot reuse token; same-size remote replacement reaches actual collision handler and preserves original bytes; missing secondary file is restored with only that missing download; same-size in-place local write with restored mtime produces a fresh digest; mutation during hashing is rejected before publication; stable retry and concurrent readers succeed. Existing manual pairing/cancellation/approval/transfer serialization regressions remain green. Swift syntax parsing and whitespace checks pass.

## Boundaries

The UIKit-owning mirror service received syntax parsing, not a native host or device SDK type-check in this subtask. Manager/browser ownership, post-emulation drain wake, installed UI, real LAN copies and Provenance receiving integration remain root/coordinated acceptance gates. No simulator/device changes, core/app builds, commits or pushes were performed here.
