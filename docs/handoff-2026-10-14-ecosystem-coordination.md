# Ecosystem coordination: iCube, Provenance, iFly (2026-10-14)

Owner report after installing the 2026-10-14 TestFlight builds of all three apps:
iCube still says iCloud sync "is not available in this build yet"; Provenance's
"View iCube library" is hard to find and does not seem to work; iCube's "Send to
Provenance" does nothing; Provenance's shared-folder setting is not working or easy
to set up; the three apps should launch together and work together.

This document records what was found, what iCube changed, and the briefs for the
Provenance and iFly sessions. Each app's gates (build, tests, device) stay in its
own session; the protocol below is the contract they share.

## Findings

### iCloud sync (iCube)

Not a bug: a deliberate gate. `CloudKitAvailability.containerIsProvisioned` is
`false` in `Source/iOS/PVCloudSync/Sources/PVCloudSync/CloudKitAvailability.swift`,
so every build uses `InertSyncProvider` with reason `.containerNotProvisioned`, whose
text is the message the owner saw. The App Store Connect API confirms why: the bundle
id `com.joemattiello.iCube` has only the `IN_APP_PURCHASE` and `APP_GROUPS`
capabilities, no `ICLOUD`, and the container `iCloud.com.joemattiello.iCube` does not
exist. No entitlements file requests it. Flipping the flag before the container exists
breaks code signing for everyone and traps at launch on any build that does get signed.

The sync engine itself (WS-5) is implemented, tested and shipping inert. What is left
is the owner's developer-portal work, then two source changes that are staged in
`docs/cloudkit-entitlements.patch` (its header is the checklist):

1. developer.apple.com → Identifiers → iCloud Containers → new container
   `iCloud.com.joemattiello.iCube`.
2. Enable iCloud → CloudKit with that container on every shipping bundle id listed in
   the patch header (eight of them), then let signing regenerate profiles.
3. Apply the patch to the four entitlements files and set `containerIsProvisioned = true`.
4. Run a device build with sync on so the record type is created in Development,
   then deploy the schema to Production before the next App Store build.

Steps 3 and 4 are an hour of agent work once step 2 is done; the iCube session can do
them on request.

### "Send to Provenance" and Provenance's "Import" (iCube ↔ Provenance)

Root cause, same for both directions: the hand-off asked the receiving app to download
the disc image over HTTP from a session the sending app opened. On one device that
cannot work. Opening the peer by URL sends the sender to the background, iOS suspends
it, and the HTTP server is gone before the first byte is fetched. Provenance's
`EcosystemFetchService` then fails with `unreachable` and only logs it, so the user
sees nothing. iFly shares the same design (`EcosystemShareCenter` →
`advertisement.urlCandidates`), so iFly → Provenance transfers fail the same way.

iCube fix (this session, branch `fix/ecosystem-share-sheet`): both routes now end in
the system share sheet with the disc image. The sender tapping Send, or approving a
`requestGame` ask, gets the sheet; Provenance appears as "Copy to Provenance" because
it declares the GameCube and Wii disc UTIs, and iOS does the copy itself (works while
iCube is suspended, no size limit). Provenance's `handle(fileURL:)` puts the copy in
`Imports/` and the importer picks it up. The `fetch` callback, the transfer id, the
continuity share session and the `provenance-ecosystem` capability-marker scheme are
removed from iCube; `gameInfo`, `open`/`play` and `requestGame` are unchanged.

### "View iCube library" (Provenance)

It is three levels down: Settings → External Emulator Migration → Ecosystem
Integration → "iCube Library" → Browse. The flow itself is sound (Provenance opens
`dolphinios://gameInfo?scheme=provenance`, iCube replies
`provenance://dolphinios?games=…` from its App Group library snapshot, Provenance posts
`ecosystemGamesReceived`), but the list only arrives while that view is on screen and
the snapshot is empty until iCube has scanned its library once after install. Not
verified on a device this session; a Console filter on `Ecosystem:` in Provenance
shows whether the reply arrived.

### Shared library folder (Provenance ↔ iCube)

Provenance's Library Storage → "Choose a folder…" (subtitle: "Share ROMs and BIOS
files with iCube and iFly through a folder in Files") is one-sided. iCube has no
picked-folder support at all: it scans only its own `Software/` folder
(`GameFileCacheManager`), so a folder chosen in Provenance is never read by iCube. The
promise in that subtitle is not true until iCube (and iFly) gain the counterpart.

## What landed in iCube

- `Common/Ecosystem/EcosystemShareCenter.swift`: `exportItems` + share sheet instead of
  the HTTP session; `exportItems(forFilePath:)` is unit-tested.
- `Common/Ecosystem/UI/EcosystemShareApprovalModifier.swift`: presents the sheet (iOS).
- `Common/Ecosystem/UI/EcosystemSendButton.swift`: gated on Provenance being installed,
  not on the removed marker scheme.
- `Common/UI/Settings/SwiftUI/Leaves/ConnectedAppsSettingsView.swift` (+ model builder
  and tests): Settings → Sync & Network → Connected Apps, iOS only. Shows whether
  Provenance and iFly are installed, opens them (or their App Store page), and explains
  both sharing directions.
- `Info.plist`: `LSApplicationQueriesSchemes` is now `provenance`, `ifly`.

## Brief for the Provenance session

Repo `Provenance-Emu/Provenance`, branch `develop`. Everything ecosystem-related is in
`PVLibrary/Sources/PVLibrary/Importer/Services/EcosystemIntegration/` and
`PVUI/Sources/PVSwiftUI/Settings/Views/EcosystemIntegrationView.swift`; the URL entry
point is `handleEcosystemCallback` in `PVUI/Sources/PVSwiftUI/App Delegate/PVAppDelegate+Open.swift`.

1. Move the ecosystem UI to a top-level Settings entry named "Connected Apps" (keep the
   link under External Emulator Migration if you like, but it must not be the only
   way in). Add it to `SettingsSearchIndex+Entries.swift`. iCube and iFly use the same
   name for their leaf.
2. The "Import" button for iCube and iFly games no longer receives a `fetch` callback.
   Importing now ends with the user picking Provenance in the sending app's share
   sheet; the file lands in `Imports/` through `handle(fileURL:)`. Change the button's
   copy to say that ("Ask iCube for a copy"), and show the import banner on
   `handle(fileURL:)` for a file that arrived from a sibling app (source application
   `com.joemattiello.iCube` / iFly's bundle id in `options[.sourceApplication]`).
3. `EcosystemFetchService` / `EcosystemFetchParser` and the `provenance-ecosystem`
   capability-marker URL type: keep them only while iFly still sends `fetch`
   callbacks; once iFly ships the share-sheet change below, remove them and the marker
   from both Info.plists. Until then a failed fetch must surface an error alert, not
   just `ELOG`.
4. Verify on a device with iCube installed: Browse lists iCube's games (iCube must have
   been launched once so its snapshot exists), Play launches the game in iCube, Import
   ends in a copy under `Imports/` and the game appearing in the library.
5. Library Storage "Choose a folder…": test the full flow on a device (pick, move,
   rescan). If it works, the subtitle still over-promises until iCube and iFly read the
   same folder; change it to "Keep your library in a folder in Files" until they do.
6. Shared purchase (future iCube Plus like iFly's): nothing to build now; note that
   StoreKit family/shared entitlements across apps need the same team and a shared
   App Group or iCloud KVS to mirror the receipt state, so the design should start from
   iFly's existing implementation.

Do not change the three URL routes (`gameInfo`, `play`/`open`, `requestGame`) or the
`games=` callback shape; both sibling apps implement them.

## Brief for the iFly session

Repo JoeMatt/iFly (remote `GitHub`), branch `develop`. Ecosystem code is in
`Sources/Core/Ecosystem/` and `Sources/UI/Views/EcosystemShareApprovalModifier.swift`.

1. Replace the HTTP hand-off in `EcosystemShareCenter` with the system share sheet,
   exactly as iCube did (see iCube `Common/Ecosystem/EcosystemShareCenter.swift` on
   `develop` after this change): "Send to Provenance" and an approved `requestGame`
   both present `UIActivityViewController` with the game file(s); drop the `fetch`
   callback, the continuity share session and the `provenance-ecosystem` probe. Keep
   `gameInfo`, `open`, `requestGame`. Multi-file games (GDI + tracks, CHD sets) must
   offer every file of the set in one sheet.
2. Add a "Connected Apps" leaf in Settings matching iCube's: installed state of
   Provenance and iCube (add `dolphinios` to `LSApplicationQueriesSchemes`), open them,
   and the two sharing sentences.
3. Tell the Provenance session when this ships, so it can delete the fetch service.
4. Device gate: Provenance → iFly Browse, Play, Import; iFly → Send to Provenance.

## Shared next step: a library folder all three apps read

The only way the apps can share files without copies is a folder the user picks in
Files, read by all three. Provenance already has the picker and the move
(`LibraryLocation.pickedFolder`, security-scoped bookmark, `LibraryFolderInspector`).
iCube and iFly need the counterpart: a "Library folder" setting that stores a
security-scoped bookmark, starts access at launch, and adds the folder as a scan root
(iCube: a second root in `GameFileCacheManager` next to `Software/`; Dolphin's own
`ISOPath` list can carry it). Writes (saves, states, settings) stay in each app's own
container. Plan this as one spec covering both apps so the folder layout is agreed
first (Provenance's `ROMs/<system>/` tree is the natural one: iCube reads
`ROMs/GameCube` and `ROMs/Wii`, iFly reads `ROMs/Dreamcast`, …).
