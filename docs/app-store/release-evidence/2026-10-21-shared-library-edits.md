# Shared library edits — implementation evidence

October 21, 2026. This records observed component results, not installed cross-app acceptance.

## Approved scope

Owner approved the [design](../../superpowers/specs/2026-10-21-shared-library-edits-design.md) and requested implementation. [Tasks](../../superpowers/plans/2026-10-21-shared-library-edits.md) include custom titles, covers and tags, paired nearby devices on different accounts, separate per-peer metadata consent and metadata-only same-account convergence. ROM import/mirroring and saved-progress compatibility remain distinct gates.

## Compatible shared store

Isolated writable PVCloudSync branch `codex/shared-library-metadata`, commit `da3815c5ef83ca53b1dad14f4a37c690e8b89661`, based on 1.0.0 `82ff294c772c79029312fda12a943760b934c9de`. This commit is not yet a published package release or an app dependency.

- Original unmodified iCube store: 32 native tests pass before extraction. Six fixed-reference-date fixtures captured before moving code, including three identities and explicit clears.
- New independent Foundation/CryptoKit `PVLibraryMetadata` target: 38 tests pass, comprising all original 32 tests and six compatibility tests.
- Complete package suite: 142 tests pass, zero failures, including 104 existing PVCloudSync tests.
- Independent task review: spec compliance and code quality pass; no findings. Reviewer inspected immutable fixture hashes, import-only original-test port, public-only source extraction and target isolation; it did not rerun the implementation's tests.
- Exact title/tag/artwork/document bounds, identities/shard names, field timestamps, nulls, unknown fields, cache budgets and recovery/failed-write semantics remain unchanged.

Commands use `DEVELOPER_DIR=/Applications/Xcode_27_1.app/Contents/Developer xcrun swift test --jobs 2`, targeted with `--filter PVLibraryMetadataTests` before the full suite. Plain `swift` on this Mac resolves an old 5.3 installation; use the selected Xcode command.

Original source SHA-256: `42542d7cc96dd93b4b7c2912e774227433393409d7c2e586feca9ae20e7487bc`.
Original tests SHA-256: `773c5fad14d987b1fc0e14e57ac9c10913138fedd5a52e09f2921de0025cadc8`.
The package commits fixture provenance/SHA256SUMS. Full local reports and saved test logs remain in this plan's ignored SDD workspace and `build/release-audit/2026-10-21-performance-distribution/`.

## Open gates

- [ ] Atomic remote merge/export, shared wire contract and revocation-safe commit API.
- [ ] Published immutable package release and both consumer resolutions.
- [ ] Verified Provenance identity binding; all app projections/editors/search/sort/nearby previews.
- [ ] Separately authorized bidirectional nearby exchange, including existing edits and emulation deferral.
- [ ] Metadata-only Production CloudKit adapter and account-transition isolation.
- [ ] Receiver PR #3753 fresh iOS/tvOS SDK integration. Reviewed cancellation/lifecycle/filename-collision and cached-reopen repairs are pushed at `7b9ccda0b59aa4a6a9fa4c3ad85860f12b622d43`; 30 focused native tests pass, including failing-before-fix regressions. SDK/installed acceptance remains open.
- [ ] Installed iPhone/iPad/Apple TV, both directions and different accounts; Production CloudKit convergence.

Physical testing is explicitly deferred by the owner. No device or simulator UI operation was used for the package results. No new TestFlight upload, package publication, cross-app convergence or App Store readiness is established by these results.
