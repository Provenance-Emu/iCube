# R4 nearby library sharing audit — 2026-10-20

Working-tree verification, after TestFlight 1.0.0 (1792472425). These results
do not describe the published binary. No device, simulator, app or core build
was performed in this audit. No shared package or Provenance source was changed.

## Contract and directions

Preserved `_icube-continuity._tcp`, catalog/manifest version 1, separate
pairing and library-auth exchanges, and current grants. Provenance's October 14
cross-app spec was read through its later **as-built** sections, and checked
against its current `ICubeContinuitySource`, `ICubeDialectServer`, `PeerBrowser`,
and library host sources. Legacy Provenance manifests use `Software/<filename>`;
iCube resolves that against Dolphin's User root (Caches on Apple TV).

| Direction / journey | Current source support | Evidence / remaining gate |
|---|---|---|
| iCube → iCube, separate devices, iPhone/iPad/Apple TV on either side | Nearby discovery, code pairing, catalog and ROM copy | Pinned package tests plus app-controller native tests pass. Actual discover/pair/copy/register/boot on each platform still required. |
| iCube → Provenance, separate devices | Provenance `ICubeContinuitySource` consumes iCube legacy protocol and maps GC/Wii systems | Counterpart source/fixture audit only in this run. Provenance import, completion and boot need its own build/device evidence. |
| Provenance → iCube, separate devices | Provenance legacy server serves only GC/Wii, ROM-only `Software/` paths; iCube now pairs while host is idle | Native iCube controller test verifies pairing's 404-as-paired rule then fresh library auth. Actual cross-app discovery, grants, transfer and boot remain open. |
| iCube → Provenance, same iPhone/iPad | User-confirmed system share sheet, including requestGame | Source-supported; independent ecosystem audit/runtime acceptance required. Does not require background HTTP serving. |
| Provenance → iCube, same iPhone/iPad | Must use counterpart's system file sharing/import support | Not established by continuity tests or URL browse/play. Requires the ecosystem/import audit and device acceptance. |
| Same-device system sharing on Apple TV | Unsupported; tvOS has no system share sheet | Nearby sharing with a second foreground device is the supported route. |
| Automatic nearby ROM mirroring | Owner approved foreground nearby additions; root agent implementing separately | This audit supplies safe copy/cancel/registration APIs. No automatic mirroring acceptance is claimed here. |
| Off-LAN/background ROM mirroring, shared-folder scanning, cross-app save/state sync | Not supplied by this contract | No claim of support. CloudKit user-data sync and Handoff saves are separate. |

Both apps must be open and serving during nearby transfers. Provenance stops its
listeners in the background. Catalog presence never proves a ROM is local.

## Reproduced defects and bounded repairs

1. A first-time library-only peer could not pair: the only pairing UI was behind
   a handoff game. The browse controller now starts code pairing after unpaired
   auth, exposes code entry, accepts legacy pairing's idle-host 404, and obtains
   a separate library token. Wrong-code retry keeps the handle.
2. A checksum-matching existing image skipped library registration. No-op copy
   now follows the same registration path as a completed download.
3. Cancelling receive changed only its label: a late manifest could still
   download, register and launch. Both controllers now own cancellable tasks;
   superseded/cancelled operations cannot publish late success/progress, register
   or boot. Screens expose Cancel and cancel on disappearance.
4. Wire paths were appended without confinement. Actual provider tests reject
   empty, absolute, dot/traversal and symlink escapes; ordinary Software/state/
   memory-card paths remain valid. Destination `.part` paths use the same
   confinement check. Each ancestor is resolved separately because Foundation
   can leave a parent symlink unresolved when the final leaf does not exist.
5. A differing incoming ROM replaced an existing same-filename local ROM. The
   provider now rejects that collision before downloading; it preserves local
   bytes and reports a file-exists error. Matching ROMs still register normally.
   There is no destructive automatic replacement or alternate-path remapping.
6. A malformed library manifest could carry GameSettings or other handoff data.
   Copy now rejects empty/non-ROM/state-bearing manifests before planning or
   writing. Valid legacy ROM-only manifests keep their existing shape.
7. A library host at the main screen could not see incoming pairing approval.
   The app root now owns the sole pairing prompt; duplicate Nearby/Sharing/
   Handoff attachments were removed. Modal stacking/focus needs runtime proof.
8. The shared server's structured timeout could not finish its losing app
   approval task. The new app approval helper resumes exactly once on user
   answer or cancellation and clears only its own prompt ID. Late/repeated
   responders cannot dismiss a replacement prompt.
9. Approval-bearing file requests used the normal short idle deadline. The app
   wrapper now routes only `library/file` through a 135-second idle session;
   ordinary browse/auth routes keep the existing fast session. It checks task
   cancellation after each request/download result, before the shared puller
   can finalize a cancelled transfer.
10. Concurrent automatic/manual controllers shared `.part` paths. One app-wide,
    cancellation-aware transfer lease now covers plan/execute/registration
    (and handoff boot resolution). Planning and collision checks run after the
    lease is acquired; a queued cancellation finishes without waiting for the
    active transfer.
11. Outbound pairing did not remember the approved server locally. Both
    controllers now call injected `didPair(handle)` exactly once after a
    successful 200 or legacy idle-host 404, validating an advertised peer ID
    against the handle's server ID. Unapproved/cancelled pairing records
    nothing. Root integration owns the callback's actual trust-store persistence.

`ContinuityLibraryBrowseController` exposes async `load`, `copy`, `cancel`,
published terminal phase, `copiedFileURLs` and its first-file convenience
`copiedFileURL`. A successful copy records every actual provider destination
after verifying that it exists and registering it. The array is cleared on the
next load/copy/cancel. `load(from:allowsPairing:false)` permits trusted browsing
while refusing to initiate pairing, as needed by the automatic queue.
Registration handles every ROM
descriptor and fails instead of reporting completion with no local file.

## Native evidence

Command, from the repository root:

```sh
python3 Source/iOS/App/Project/Scripts/test_continuity_controllers.py \
  /tmp/icube-tvos-audit-2026-10-19/packages/checkouts \
  --scratch /tmp/icube-sharing-controller-tests --include-package-tests
```

The script builds an isolated macOS Swift package with **actual production**
browse/receive controllers, file provider, path resolver, transport wrapper,
approval helper and transfer lease. It also compiles exact production approval
method bodies extracted from the UIKit manager into a host prompt owner. It links candidate
PVContinuity/PVWebServer/PVSyncRules sources read-only. Only UIKit/ObjC app
bridges, trust-persistence callback and network responses are substituted; filesystem/hash/crypto/wire/
planning/transfer code is real. This is native host/controller evidence, not an
integrated iOS/tvOS app pass. PVContinuity revision:
`9dae36f45f181b5ca357672e0dd99d165eb18223`.

- **234 passed, zero failed:** all 208 pinned PVContinuity tests plus 26
  controller/provider regressions. Package tests cover grant/revoke/default
  ask, ROM-only manifests, checksum rejection, interruption/Range retry and
  wire versions.
- Controller tests cover unknown idle-host pairing, pairing 404, wrong-code
  retry, matching-file registration, cancelled copy/receive with late response,
  ordinary/unsafe paths, differing ROM preservation, rejecting user data,
  unanswered approval cancellation, stale/repeated responses, queued/concurrent
  copy, cancellation before finalize, route isolation, multi-file registration,
  automatic non-pairing auth and approved-host callback identity/exactly-once behavior.
- Initial red runs preserve actual failures, including replacement of a 23-byte
  local image by the incoming 3-byte image and writes of an injected INI.
- Logs: `2026-10-20-native/sharing-{controller,path,collision,rom-only}-red.log`
  plus `sharing-{approval,finalize,lease,host-trust}-red.log` and final
  `sharing-final-green.log`. The preceding `sharing-package-and-controller-green.log`
  records the earlier 208+10 pass. The older
  `sharing-controller-green.log` records the preceding nine-test pass.

`git diff --check` passed. The localization checker found the one new pairing
message key; root integration owns its en/ja entries. No app build is implied.

Actual localhost timeout probe, with production wrapper and pinned URLSession
transport source (not a timing/routing model):

```sh
python3 Source/iOS/App/Project/Scripts/probe_continuity_approval_timeout.py \
  /tmp/icube-tvos-audit-2026-10-19/packages/checkouts
```

The fixture delays HTTP response headers for 65 seconds. Ordinary catalog
timed out at **16.045 seconds**; the approval file route received and checked
the intact fixture after **69.415 seconds**, beyond the default request's
60-second boundary. This confirms the injected session deadline applies.
Log: `2026-10-20-native/sharing-approval-timeout-probe.log`.

## Remaining acceptance and source findings

- Run actual iPhone/iPad/Apple TV matrices with both apps foreground: discovery
  allowed/denied/offline, first pair, approve/deny/revoke, large RVZ/WBFS, Wi-Fi
  loss/resume, checksum failure, storage exhaustion, duplicate, another revision/
  disc/format, source deletion, destination persistence and successful launch.
- Verify global alert presentation over settings/handoff sheets, code-entry
  focus and Cancel/Back. A source-level alert attachment is insufficient proof.
- Pinned discovery silently finishes its stream on NWBrowser failure; the app
  does not show a distinct local-network-denied/offline error. The legacy
  16-character service name remains a discovery risk requiring actual evidence;
  this audit does not rename a deployed protocol.
- Controllers still select only the first advertised URL. URL fallback is not
  verified; a stale first address may fail despite another reachable candidate.
- The app wrapper closes the delegate-return cancellation gap and the new
  approval helper releases structured timeout cancellation. Actual device
  cancellation at the final byte and owner approval near the timeout boundary
  still need acceptance. Shared package source itself remains unchanged.
- Counterpart import/dedupe target-system routing and checksum/Range behavior
  were inspected, not executed here. No Provenance build or package-suite pass
  is claimed.
