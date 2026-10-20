# Nearby mirror scheduler evidence — 2026-10-20

Foundation-only implementation: `Source/iOS/App/Common/Continuity/NearbyLibraryMirror.swift`.

Run actual production sources and repository XCTest tests without core/Xcode app builds:

```sh
python3 Source/iOS/App/Project/Scripts/test_nearby_library_mirror_native.py
```

Optional `--work-directory /tmp/icube-nearby-mirror-audit` retains the SwiftPM package/cache. The harness links production source and tests directly; injected transport/discovery/clock fixtures are scheduler boundaries, not installed-app transfers.

Initial contract tests ran against API-only no-op implementation and failed 25 assertions across seven tests. Subsequent adversarial testing reproduced a pass remaining in Copying after a later peer disappeared; it now skips that peer and settles normally. Final run: **12 XCTest tests, zero failures/skips**. [Initial red](2026-10-20-native/nearby-mirror-scheduler-red.log), [later-peer red](2026-10-20-native/nearby-mirror-scheduler-later-peer-red.log), [green](2026-10-20-native/nearby-mirror-scheduler-green.log).

Verified scheduler behaviors: trusted explicit opt-in, no unknown pairing; initial/subsequent additions; exact resource-ID deduplication per peer/pass; local-presence reevaluation after a purge; no deletion for empty catalog; one physical copy at a time despite discovery storms or rapid disable/re-enable; immediate transport cancellation and stale-completion rejection for disable, trust revoke, background and emulation; missing-peer wait/reconnect; actionable failure/explicit retry; 60-second injected polling and stale timer suppression; disabled late catalog results cannot start an import.

## Integration contract

- Root adapter supplies stable authenticated cryptographic peer IDs, never discovery UUID/display name/IP.
- `Entry.id` is an opaque resource identity that distinguishes disc/revision/format. Do not reduce it to gameID.
- Catalog and copy closures execute on MainActor and may suspend; transport owns verified durable ROM-only import, path/collision enforcement and registration. `isPresent` defaults false so transport can perform manifest-hash verification/no-op. No cross-pass completed-item cache exists.
- `setEnabled(_:for:)` requires current trust. Root persists `enabledPeerIDs` device-locally; `onChange` reports state/opt-in changes, including pruning revoked peers.
- `environmentChanged()` is required on discovery/trust/foreground/emulation changes. `retry()` clears actionable failure. `stop()` cancels while retaining opt-ins, then waits for an explicit event before resuming.
- Canceled tasks remain tracked until their async operation exits. The supplied cancel closure must terminate transport; stale operation completion cannot update scheduler state or start overlapping work.
- Failure pauses automatic passes until explicit Retry or a lifecycle transition makes the scheduler wait and resume. Eligible successful passes poll after 60 seconds. Missing peers wait for discovery; no background polling promise exists.

Manager/UI wiring, subscription durability, actual byte transfer/checksum/collision behavior, Provenance receiving counterpart and all SDK/device acceptance remain separate gates. This evidence does not prove usable ROM import, launch or cross-app convergence.
