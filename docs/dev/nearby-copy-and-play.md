# Nearby copy and play

The main library's nearby tiles use an explicit copy/download confirmation. A local
copy is matched by the catalog identity (including disc and revision) and an existing
local file, not merely by GameID. The user can play that local copy or add save states.
A completed transfer offers a boot picker: no state, latest compatible state, or a
specific local/imported state. It uses the normal library storage/replacement/profile
checks. Cancelling either boot gate clears the requested state and skip-resume flag.

The receiver may choose no save states (default), latest, a selection, or all.
The host must approve save sharing separately, even for a peer with permanent ROM
permission. This is save-state copying, not native memory-card or Wii NAND sync.
An older host without the extension below continues to support ROM copying and
reports that save-state copying is unavailable. Matching Dolphin state versions
are required to boot a state; incompatible imports remain visible but cannot be
selected in the boot picker.

## Optional iCube save-state extension, version 1

- POST `/icube/library/states/v1/catalog`: JSON `SignedRequest` with the exact encoded
  `Request` bytes and an Ed25519 signature using the existing paired signing key.
  The signing message is `icube.library.states.v1\0` followed by those bytes. The
  request binds peer ID, server ID, game catalog key, UUID nonce and issued date
  (Foundation JSONEncoder's default Date encoding). Accepted timestamps are within
  120 seconds of the server clock. Nonces are single-use for 240 seconds; the replay
  cache is bounded to 256 entries. Each request checks live pairing, sharing enabled,
  library grant and per-game exclusion. The owner has 120 seconds to approve; only
  Allow Once and Not Now are offered for saves. No persistent ROM grant is changed.
- After approval, the server snapshots committed states for that game's ID under
  the local I/O gate. Memory cards, NAND, INIs, credentials and thumbnails are not
  included. Sources must resolve directly inside StateSaves. The catalog includes
  opaque IDs, labels, dates, lengths and SHA-256 hashes, bound to the game key.
- GET `/icube/library/states/v1/file?id=...`: requires the catalog's random bearer
  token. It streams only a listed snapshot and rechecks live trust, sharing and
  exclusion. Grants expire after ten minutes; revocation and disabling sharing
  remove grants immediately. Pending approvals cannot survive a revocation epoch.
  Catalogs are bounded to 100 states / 1 GiB; over-limit requests fail without
  silently truncating All. There are at most 16 active catalogs and one consent
  request/snapshot operation at a time. Expiry removes the temporary snapshots.
- The receiver transfers selected snapshots before a potentially long ROM download.
  Every state is staged, length/hash verified, and then installed under a generated
  UUID `.sav` filename with newly generated metadata, under the local I/O gate.
  It never uses remote paths or overwrites a slot, autosave or existing import.
  A failed import removes all files published by that import. Once saves are safely
  imported, a later failed/cancelled ROM download leaves those imported saves intact.

This extension follows the existing plaintext LAN transport disclosure: pairing
and signed requests authenticate access; they do not encrypt traffic. Both devices
must run an iCube version with this extension for save-state copying. No shared
PVContinuity protocol changes or cross-app save compatibility are implied.

## Validation

`NearbySaveTransferTests` exercises signature binding, stale/future requests, key
mismatch, tampering, domain separation, replay bounds and progress unit/precision.
Run through iCubeTests; the Foundation/CryptoKit models can also be tested natively
without the emulator. iOS/tvOS compile and installed transfer/boot evidence must be
recorded separately; passing these model tests does not establish device acceptance.

2026-11-08 implementation evidence (branch `codex/nearby-copy-and-play`, base
`715122a524`, uncommitted source):

- iOS Simulator signed build and tvOS Simulator build passed with the existing
  simulator core slices (`DOL_SKIP_CORE_BUILD=1`).
- Installed iOS build launched on the iPad simulator and displayed onboarding.
  This is a launch smoke check, not nearby-transfer acceptance.
- Four Foundation/CryptoKit tests passed natively on macOS; new Swift files pass
  repository SwiftFormat rules, localization-key validation and strings plist checks.
- Targeted iCubeTests compiled; both simulator launch attempts were rejected as Busy
  while the application was installing. No simulator tests executed. The retry
  result bundle is `/tmp/icube-copy-play-targeted-retry.xcresult`.
- Pending: two updated devices exercising approval, none/latest/specific/all save
  selections, cancellation/retry, already-owned boot, and Apple TV focus/scrolling.
  No physical-device or full-suite acceptance is claimed.
