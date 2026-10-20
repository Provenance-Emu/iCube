# Nearby library mirroring for release

## Owner decisions

The release requires both explicit nearby browse/import and automatic ROM mirroring across iCube installs and Provenance. On October 20 the owner specified **nearby, with apps open**. Internet/cloud ROM mirroring is outside this requirement. Library editing and safe user-data sync remain required separately.

## Intended behavior

After pairing, the receiving user can enable automatic game copying for that peer. While both apps are active and the peer is advertising its library, the receiver periodically reads its catalog and copies missing games through the existing authenticated, checksum-verified importer. Enabling the option authorizes initial and subsequent additions from that peer. It does not grant an unknown peer trust, change the sender's sharing consent, or include saves/settings in a ROM catalog transfer.

The setting and job state are device-local. A trusted peer must still be advertising a compatible library and permit copying. A request-per-game host can continue requesting approval. Revocation, disabling the subscription, leaving the foreground, or starting emulation cancels scheduled/active automatic copying. On reconnect/foreground, the next pass retries resumable missing files. Only one automatic copy runs at a time; duplicate catalog entries and repeated discovery events do not create concurrent copies. Polling defaults to 60 seconds while eligible (builder's choice); discovery/lifecycle changes can trigger a pass sooner.

The receiver exposes waiting, checking, copying/progress, up-to-date and actionable failure states, plus disable/retry. Nearby browsing remains available when automatic copying is off. Both iOS and tvOS controls must be focusable, with no essential action hidden in a tvOS Menu.

## Ownership and data safety

- Existing local ROMs with matching hashes are registered without re-downloading. A same-path file with different bytes is preserved and reported as a collision; copying must not replace it silently.
- Remote deletions, exclusions, outages and an empty catalog do not delete local ROMs, saves, library edits or progress. This is an additive replica. This conservative deletion policy is the builder's choice.
- Temporary files are never playable entries. Registration follows verified completion; cancellation cannot report success or launch a game. Interrupted partials are retained for a later resume when safe.
- All incoming paths are confined to approved local storage, including symlink/staging paths. ROM mirroring must reject a manifest with user-data payloads rather than automatically applying a handoff manifest.
- Subscriptions are bound to stable paired peer identity, never only a display name or remembered IP address. Current discovery supplies endpoints; the host still requires paired-client authentication and its own sharing grants. The existing transport is plain local HTTP; the existing network-trust notice remains visible. Trust removal disables the subscription immediately.

## Reuse and interoperability

Preserve `_icube-continuity._tcp`, catalog/manifest v1, existing pairing/auth/grants, and the pinned transfer codecs. iCube uses its repaired library browse/copy controller. Provenance already serves the iCube dialect and imports through PVLibrarySharing; verify both source/receiver directions with frozen protocol fixtures. Receiving automatically in Provenance requires a counterpart implementation and its own tracked tests/build evidence; iCube-side tests cannot establish that behavior.

Keep ROM replication separate from iCube's CloudKit user-data file sync. Favorites/play history currently use LibraryStateDocument; custom title/artwork/tag editing needs an explicit additive metadata schema and read/write integration. Save states are not assumed portable across different emulator cores, and region-wide memory-card handoff must never be added to automatic ROM copying.

## Validation and delivery

First repair the reproduced editing, metadata merge/purge, pairing, cancellation and path/collision defects. Implement the automatic scheduler with injected discovery/auth/copy/lifecycle boundaries and production-model regressions for opt-in, peer filtering, initial/additional items, duplicate events, disconnect/cancel/revoke, retry/resume, no deletion, collision, and emulation ownership. Then wire user controls and lifecycle in iCube, and track the Provenance receiving counterpart independently.

Build affected iOS/tvOS app targets and run targeted tests. Device acceptance must demonstrate iCube↔iCube, Provenance→iCube and iCube→Provenance with both apps open, then background/disconnect/cancel/relaunch. Record source/build identity and actual copy/registration/launch; neither discovery nor a model test proves a usable imported ROM.

No App Store submission or new background-serving promise is implied by this work.

## Editing scope confirmed

The owner also confirmed custom titles, covers, and classification tags are required. App-owned metadata uses stable disc identity (game ID, disc, revision); homebrew uses a content digest. Edits live in per-game, bounded JSON shards at `Profiles/LibraryMetadata/<identity-sha256>.json`, with independently timestamped field records and retained clear/reset values. Cover JPEG data is embedded in its small shard (256 KiB per cover, 1 MiB per shard); changing one title does not rewrite every cover in the library. Unknown fields survive round trips. Whole-library storage is not capped by a single aggregate metadata file.

The shared PVSyncRules classifier needs a narrow reviewed allowlist for this directory because the real CloudKit provider reclassifies remote paths. App-only controlled-provider success cannot establish remote convergence. These opaque per-field records reuse the existing keyed timestamp merger and game-profile engine bucket, with the user-facing category explicitly including library edits. No cloud schema or ROM-cloud backend is added. Cross-app edited-field convergence still requires explicit Provenance adapters/tests; ROM copying does not prove it.
