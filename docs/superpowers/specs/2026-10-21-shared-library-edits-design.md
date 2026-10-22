# Shared library edits across iCube and Provenance

October 21, 2026. **Owner approved: “Approve and implement.” Implementation and installed acceptance remain open.**

## Owner requirements

Release 1.0 includes custom titles, covers and searchable classification tags. These edits must converge across iCube installs and Provenance, including paired nearby devices on different accounts. Nearby operation requires both apps open. Manual ROM browsing/import and optional automatic nearby ROM mirroring remain separate required features. Existing save-state, native-save and ROM transport behavior is preserved.

The current iCube editor and same-account metadata document merging exist. Cross-app metadata convergence does not. Provenance PR #3753 implements ROM receiving/mirroring; completing it does not implement this design.

## User experience

Each paired library gets a separate **Sync Custom Library Edits** option covering titles, covers and tags. It starts off; the remote owner must grant edit synchronization before either app can exchange edits. Pairing, ROM read access and automatic ROM copying do not imply this permission. Both participants must opt in to bidirectional synchronization. Disabling or revoking it stops pending network work and prevents subsequent commits from that session; already committed local edits remain.

After consent, edits merge automatically while both apps are foreground and reachable. Show the peer, connected/waiting/error state, last successful synchronization and a Sync Now action. Signing into the same iCloud account is unnecessary for nearby synchronization. Games are not copied implicitly by this switch: a missing game uses the existing explicit import or automatic ROM-copy option. Recheck metadata after an import successfully registers its files.

Changing a title on one side and tags on the other combines both edits. Competing changes to the same field use the existing deterministic field-merge rules. Clearing a field is a synchronized removal of the custom override; each app then uses its own catalog fallback, which may differ. Cancelling an editor sends nothing. A failed local write leaves the previous visible edit intact and reports failure.

## Common data and identity

Extract the existing iCube canonical identity, field codec, bounds, normalization and merge rules into a shared `PVLibraryMetadata` product in the existing PVCloudSync repository. Keep the core codec/store independent of UIKit and Realm. Both apps consume one implementation and golden compatibility fixtures. Retain existing iCube shard paths and bytes; do not replace them with a new incompatible format.

Each field retains its own timestamp and explicit null clear. Preserve unknown fields, use canonical bytes for deterministic ties, and ensure a new local edit advances beyond the latest observed field stamp. Reuse the existing limits: titles 200 characters, up to 32 normalized tags of 40 characters, artwork 256 KiB and a shard 1 MiB. Platform image adapters validate/decode artwork with existing bounded normalization before storage or display. Local transactions and remote merge commits use the same short file lock without holding it over network awaits.

Match verified game/disc/revision identities or verified SHA-256 content identities. Provenance MD5 keys, filenames and best-effort serials cannot select a sibling shard. Add a durable Provenance local binding to verified file evidence, using a read-only Dolphin metadata reader for supported disc formats or the existing authenticated, hash-verified import receipt. Missing disc/revision information remains unresolved rather than being assumed zero. Unknown or unsupported identity stays visibly pending and cannot mutate a guessed game's metadata. Never treat native saves or save states as portable through this contract.

## Transports and consent

Nearby metadata uses an additive versioned capability and dedicated authenticated manifest/read/merge routes in PVContinuity and PVLibrarySharing. Preserve legacy discovery and ROM wire compatibility. Old peers without the capability show the feature as unavailable and retain existing ROM behavior. Use existing paired-peer authentication; introduce no shared public trust salt.

The metadata grant authorizes only canonical metadata identities. It grants no filesystem paths, ROM access, saved progress, firmware or settings. Enforce body/shard/image limits before decoding and committing. Fetch bounded manifests of identity, verified content evidence and revision digest, then exchange changed shards. For nearby transfers, request shard bodies only for verified local matches or after a successful import; do not accumulate unknown remote artwork in an unbounded inbox.

The receiver validates identity and grant/session ownership, merges atomically and returns its committed digest/state. Recheck revocation immediately before the write. Concurrent edits are merged rather than replacing the whole document. Retry failures with bounded backoff; do not restamp received values or create upload loops. Revocation/disconnect/foreground transitions cancel stale work and prevent stale callbacks publishing success. Resume uses fresh digests and current grants.

For same-account automatic convergence, add an explicit Provenance metadata-only adapter to the existing private iCube zone. This uses the same shared records but an independent account-bound index and preference. It may access only canonical metadata shards, never iCube saves, firmware, INIs or the provider's whole-zone purge. Account transitions invalidate stale workers and account-bound state before publication. Nearby pairing is independent of iCloud-account authorization.

## Provenance integration

Keep catalog/legacy cloud values as fallbacks and the shared sidecar as the custom override. Route title/artwork/tags through one effective metadata projection for cards, details, UIKit/tvOS presentations, search, sort and served nearby previews. Publish changes to the real observed library snapshots and invalidate caches. Legacy ROM cloud refreshes cannot erase or restamp shared overrides. Classification tags remain separate from catalog genres and hidden-game markers.

New explicit edits always commit to the local canonical override store, including while transport is off. Turning synchronization off controls exchange rather than disabling editing or discarding local changes. Builder proposal: the enable confirmation explicitly says it will merge **existing and future custom edits** for matched games; accepting it publishes already-stamped custom records without restamping them. Nothing is published to an unapproved peer. Do not automatically adopt every historical catalog title as a custom title. Legacy Provenance title/artwork adoption, where no reliable customization record exists, remains a separate explicit user action that fills only absent shared overrides and exports bounded artwork bytes rather than cache keys. Preserve existing edit behavior while integrating the sidecar; use a reviewed additive migration if reader/writer coverage requires one, never a lossy rewrite.

## Builder choices and acceptance

Builder proposals, not additional owner requirements: the product name above, a sidecar projection instead of overwriting Realm fields, and an immediate debounced refresh plus lightweight foreground manifest polling around ten seconds. The implementation plan must name actual package releases/pins, identity-reader APIs, routes, projection readers and lifecycle ownership before coding. Measure rather than promise a delivery latency budget.

Required verification includes golden byte compatibility in both apps; independent/concurrent fields and null clears; deterministic ties; malformed/oversized/wrong-identity payloads; same-name different ROMs and disc/revision differences; failed writes and interrupted transfers; old peers; read-only/absent/revoked grants; stale callbacks; foreground/background and emulation deferral; legacy cloud updates; restart and cache loss; every display/search/sort/edit/export projection; and account changes without unrelated data access or deletion.

Installed acceptance covers iPhone, iPad and Apple TV, both directions between apps, same-account Production CloudKit and different-account foreground nearby peers. Record exact builds, consent, transfer/import receipts and signed entitlements. Simulator/host tests supplement this gate; the owner's deferred physical testing remains deferred until a new device window is granted.

## Sequence

First finish and verify both current iCube TestFlight uploads and processing. Resolve the Provenance ROM receiver's build/integration blockers. Then implement the common contract and identity binding, counterpart projections/edit adapters, consented nearby routes, same-account adapter, and installed convergence tests. Keep all still-open acceptance gates visible in the release tracker.

Prior research and detailed source pointers: [October 20 proposal](2026-10-20-cross-app-library-metadata-proposal.md). This design makes different-account nearby metadata a required release path rather than that proposal's optional extension.
