# Library editing integration — October 20, 2026

Owner-confirmed release scope includes custom titles, covers and searchable classification tags on iOS/iPadOS/tvOS. These extend existing favorites, platform assignment and deletion.

## Implementation

- The game context menu opens **Edit Library Details**. Fields are drafts until Save; Cancel does not commit. Initial load failures disable editing and offer Retry. Save failures keep the draft and display the failure.
- Custom title participates in library display/sort/search. Classification tags participate in search. Custom artwork uses a bounded ImageIO thumbnail and decoded-image cache.
- Cover files and HTTP/HTTPS response bodies are limited to 12 MiB before image preparation; persisted cover images are at most 256 KiB. Source URLs are not stored. Retry tasks are owned by SwiftUI's task lifecycle; cover work uses cancellation plus a presentation token.
- Disc edits share identity across copies with the same game ID, disc and revision, including patches that retain those headers. The editor explains that policy. Unknown/ELF/DOL files use a streaming SHA-256 identity; cached receipts require matching inode/device/size/nanosecond modification and change timestamps. Warming is capped to small unidentified files, cancels during gameplay/background, and resumes after the current physical core drain.
- Per-game metadata shards use independent timestamped title/cover/tag fields, stamped clears, validated size limits, atomic writes and the existing shared file-access gate. Full records use a 16 MiB / 64-entry cache; title/tag-only projections use a separate 4 MiB / 8192-entry cache. Before eviction, validated records are atomically preserved in local recovery snapshots excluded from sync. Recovery merges preserve newer clears across store instances. Title/tag cache hits avoid artwork decoding and filesystem work. The sync scanner accepts only the exact reviewed metadata shard paths. Remote edits trigger the library coordinator's debounced, gameplay-deferred refresh.

## Evidence and remaining gates

The [metadata store evidence](2026-10-20-library-metadata-store.md), [sync evidence](2026-10-20-library-sync-audit.md), [mirror scheduler evidence](2026-10-20-nearby-mirror-scheduler.md) and [adapter evidence](2026-10-20-nearby-mirror-adapters.md) contain targeted native test results. These do not establish rendered editor behavior.

English/Japanese string coverage and the design-token ratchet pass locally. The first integrated iOS build-for-testing passed before the bounded-cache follow-up; the updated candidate still requires its own SDK/test result. Integrated iOS SDK build/test, tvOS SDK build, rendered editor focus/Back/Save/Cancel, relaunch/rescan, real-device cloud convergence and final candidate identity remain pending at this checkpoint.

**Cross-app limitation:** ROM sharing v1 does not transfer timestamped edits or classification tags. Catalog title/artwork are browsing projections, not proof of receiver metadata convergence. Provenance edit convergence remains an open interoperability release gate.
