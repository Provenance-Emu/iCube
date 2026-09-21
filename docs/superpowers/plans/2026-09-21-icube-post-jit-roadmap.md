# iCube post-JIT roadmap — eight workstreams

Written 2026-09-21 against `develop` @ `d09f0ac62a`. Every claim below was verified by reading
the code; file:line references are real. Where something does not exist, this says so.

**Purpose:** split eight asks into workstreams that can be handed to separate sessions/models.
Each has a self-contained brief, verified current state, root causes, acceptance criteria, and a
size/model recommendation.

---

## Reading this document

Reference apps live at:

| Name | Path | Used as reference for |
| --- | --- | --- |
| iFly | `/Users/jmattiello/Workspace/Provenance/iFly/iFly` | WS-2, WS-3, WS-4, WS-5, WS-6 |
| Provenance | `/Users/jmattiello/Workspace/Provenance/Provenance` | WS-6, WS-7 |

**Two corrections to prior assumptions, both load-bearing:**

1. **The webserver re-port is already done and merged.** `docs/superpowers/plans/2026-09-16-web-server-single-port-uploader.md`
   has 54 unticked checkboxes, but every task landed. Verified: `33d42a8195`, `5c670ea3fb`,
   `c46ec4f263`, `17c008f41e`, `40fc5e427b` are all ancestors of HEAD. The checkboxes were never
   ticked. **Do not re-do this work.** WS-3 is now a much smaller lifecycle job.
2. **`CLAUDE.md` is stale** where it describes `PVWebServer` as GCDWebServer-based. It has been
   `NWListener`-based since the port. Fix this while touching WS-3.

---

## Sequencing

```
WS-3 (webserver lifecycle)  ──┐
                              ├──► WS-4 (nearby + continuity)
WS-1 (resume/boot safety)     │
WS-2 (controllers)            │
WS-7 (in-app docs)            │
WS-5 (cloudkit)   ────────────┘   (independent, but shares WS-4's file-classification work)
WS-6 (settings UX) ── runs alone, see conflict warning
```

**Start now, in parallel:** WS-1, WS-2, WS-3, WS-7, WS-8. All independent, no shared files.

**WS-8 (tvOS first run) is the best effort-to-impact ratio here** and is largely deletion plus
swapping a broken control for a working one. Consider doing it first.

**WS-6 conflict warning.** `SettingsRootView.swift` is 5382 lines and nearly every other
workstream adds a row to it. Running WS-6 concurrently guarantees merge pain. Either run WS-6
first and have everyone else build on the new structure, or run it last. Do not interleave.

**WS-4 and WS-5 share one thing:** the file-classification table that decides what is syncable
and what is transferable. Build it once (WS-5 Task 2), consume it in both.

---

## WS-1 — Resume, boot lockups, and booting into a chosen save

**Ask:** item 1. **Size:** M. **Model:** Sonnet. **Depends on:** nothing.

### Current state, verified

`655a85cf79` (Sep 19) added "Reset System" and "Start Fresh (Skip Resume)". Its own commit message
ends *"the app has not been built with this yet."* **This code has never run.** Treat WS-1 as
build-and-fix, not greenfield.

- Setting: `resume_where_left_off`, read via `SaveStateService.resumeEnabled`
  (`Source/iOS/App/Common/Swift/SaveStateService.swift:96`).
- Save: `TVEmulationBridge.stop` writes `{GameID}.auto` (`TVEmulationBridge.mm:44-52`).
- Load: `SaveStateService.resumeIfAvailable()` (`SaveStateService.swift:121-130`), called from the
  `DOLEmulationDidStartNotification` observers — tvOS `EmulationScreen.swift:564`,
  iOS `EmulationScreen.swift:714`.
- Save states on disk: `FilesystemSaveStateProvider.swift:19-93`. Pure filesystem scan, no DB.
  `{GameID}.s{NN}` numbered slots, `{GameID}.auto` for resume, `.png` thumbnail siblings, optional
  JSON metadata sidecar.

### Root causes

**1a. Reset System silently does nothing.** `TVEmulationBridge.mm:65` guards on
`!Core::IsRunning(system)`, and `Core::IsRunning` is defined as `s_state == State::Running`
(`Source/Core/Core/Core.cpp:199-202`). The pause menu means the state is `Paused`, so it always
returns early. Guard on "a game is booted" instead — `Core::IsUninitialized` (`Core.h:145`) is the
right test.

**1b. Reset System is weaker than its name even once fixed.** It calls
`ProcessorInterface::ResetButton_Tap()` (`Source/Core/Core/HW/ProcessorInterface.cpp:288-299`),
which toggles the reset line. RAM, memory cards and DSP state survive. If the bad state is baked
into RAM, asking the machine to reboot itself does not clear it. A true "power cycle" needs a
re-launch through the boot path. Consider offering both, named honestly.

**1c. iOS has no escape from a bad auto-resume loop.** "Start Fresh (Skip Resume)" exists only in
the tvOS branch (`GameGridItem.swift:685-692`, inside `#if os(tvOS)` opened at `:467`). The iOS
`.contextMenu` at `GameGridItem.swift:906` offers Properties, Select Games and Cheats only. An
iPhone user whose auto-state hangs relaunches into it every time with no way out. **This is the
highest-severity item in the whole document.**

**1d. No boot-hang detection at all.** Nothing marks that a boot was attempted, so nothing can
notice it never completed.

### Reusable precedent

`JitManager` already implements exactly this pattern for the TXM handshake:
`kTXMHandshakeInFlightKey` (`JitManager.m:12`), `beginTXMHandshake` persists before the risky step
(`:155-159`, called from `EmulationCoordinator.mm:1751`), `noteTXMHandshakeResult:` clears
(`:167-170`), `txmHandshakeBlocked` is read next launch (`:151-153`, checked at `:136`), and a
Settings row gives a manual reset path. Copy this shape.

### Tasks

1. Fix the `resetSystem` guard (`TVEmulationBridge.mm:65`). One line.
2. Build and actually run `655a85cf79`'s UI on both platforms. It has never been executed.
3. Add "Start Fresh (Skip Resume)" to the **iOS** context menu (`GameGridItem.swift:906`).
   `SaveStateService.skipResumeOnce` (`:118`) already exists and works.
4. Boot watchdog: set a UserDefaults marker before the resume load, clear it on first successful
   frame or on clean exit via `TVEmulationBridge.stop`. If still set at next launch, decline the
   auto-resume and tell the user why. Mirror `JitManager`'s structure exactly.
5. Un-comment "View Save States" in both context menus (`GameGridItem.swift:699` and `:916`). The
   plumbing is already wired: `showSaveStates` closure (`GameGridItem.swift:21`) → `TVLibraryView.swift:952-956`
   → `SaveStateFilmstripView`.
6. **Boot into a chosen state.** This does not exist and is the only real new code here. Today
   `TVEmulationBridge.loadState(fromSlot:)` (`:97-102`) hot-swaps state on an already-running core.
   Add a `SaveStateService.pendingBootStatePath`, set it before launching, and consume it in the
   same `DOLEmulationDidStartNotification` observers that already call `resumeIfAvailable()`
   (`EmulationScreen.swift:564` / `:714`). Provenance's launch pipeline takes a save state as a
   boot parameter (`PVUI/Sources/PVUIBase/PVRootDelegate.swift:22`,
   `root_load(_:sender:core:saveState:)`) — that is the shape to copy.

### Acceptance

- Reset System visibly resets a running game on iOS and tvOS.
- An iPhone stuck in a bad auto-resume can be recovered from the library, without reinstalling.
- Killing the app mid-boot twice does not produce an infinite re-entry loop.
- Long-press a game, pick a save state, and the game boots directly into it.

---

## WS-2 — Controller ownership refactor

**Ask:** item 2. **Size:** L, the largest of the seven. **Model:** Opus. **Depends on:** nothing.

### Why tvOS cannot reach the pause menu

Four independent reasons, all verified:

1. `EmuEventVC.pressesBegan` (`Common/UI/Emulation/EmuEventVC.m:102-127`) only arms a **2-second
   long-press** timer that posts `DOLEmulationRequestExitToLibrary` — exit, not pause — then calls
   `super`. A short Menu press does nothing app-specific.
2. `installExtraInputHandlers` (`ControllerExtensions.swift:256-381`) only ever touches
   `c.extendedGamepad` (`:269`). It never touches `microGamepad`.
3. `microGamepad.buttonMenu` is set to `nil` or to an empty swallow closure in several places
   (`EmulationScreen.swift:644`, `TVLibraryView.swift:1197`, `:2497`, `:2603`) and **never** wired
   to the pause menu anywhere. The Siri Remote's Menu button is a dead key: its system gesture is
   disabled and nothing is substituted.
4. Where `extendedGamepad.buttonMenu` does get a handler it routes to
   `PauseGestureTracker.menuOrStartPressed()` (`ControllerExtensions.swift:289-298`), which hard-guards
   on `isAllShouldersHeld` (`PauseGestureTracker.swift:57`). L1+R1+L2+R2 must be held *simultaneously*
   with Menu. A microGamepad has no shoulders at all, so this is structurally unreachable, and it is
   undiscoverable even on a full gamepad. Only DS4/DS5/Xbox get an ungated pause, via their Home
   button (`ControllerExtensions.swift:313-348`). Switch Pro and bare MFi get nothing.

### Why player index drifts

**Six writers, no arbiter, no ordering guarantee.** On a single connect event, `reconcile()` fires
policies 3 and 4 from inside the same handler that already ran 6 (which itself calls 1), so a
controller can be assigned, re-decided and reassigned several times within one callback.

| # | Writer | Location |
| --- | --- | --- |
| 1 | `ControllerAssignmentService.assign()`, the documented single source of truth | `ControllerAssignmentService.swift:31-38` |
| 2 | Fallback that bypasses the service and skips port activation | `TVControllerMappingBridge.mm:94-126` |
| 3 | A second auto-assign policy, in C++ | `TVControllerMappingBridge.mm:154-255` |
| 4 | A third auto-assign policy, in Swift | `AssignmentEngine.swift:8-21` |
| 5 | Four direct `playerIndex =` writes | `ControllerManager.swift:119`, `:318`, `:345`, `TVControllerMappingBridge.mm:125` |
| 6 | A fourth policy in C++ that hardcodes `isWii:NO` | `EmulationCoordinator.mm:1541-1623`, esp. `:1620` |

Writer 6's hardcoded `isWii:NO` means that during a Wii game, auto-assign only ever touches GC pad
config and silently no-ops on Wiimote config. Writer 4 reads only GC port assignments even though
its snapshot carries `isWiiSystem` (`ControllerStateStore.swift:22-25`).

### The competition is NOT where we assumed

Dolphin's native `ciface::iOS::MFiController` (`Source/Core/InputCommon/ControllerInterface/iOS/MFiController.mm`)
does **not** install handler closures. It wraps each button and **polls** `.isPressed` on demand
(`:222-250`), matching Dolphin's per-frame `UpdateInput()` model. So core and wrapper never fight
over a handler slot. The real problems are:

- **Swift versus itself.** `pressedChangedHandler`/`valueChangedHandler` are single-slot properties
  assigned from at least three overlapping lifecycle points: `ControllerManager` connect
  (`:206-221`), `EmulationScreen.onAppear` (`:536-539`), and `TVLibraryView` appear/disappear
  swallow closures. Last writer wins, and the screens are not strictly ordered, so a stale swallow
  can outlive its screen. `EmulationScreen.onDisappear` (`:639-645`) only nils two of them.
- **Semantic collision.** The core treats Menu as an ordinary bindable input (`MFiController.mm:91`,
  `:135`) with no notion that the app reserves it. iFly has a real shared concept for this
  (`EMU_BTN_MENU`) that both layers agree on. Dolphin has no equivalent.

### What iFly does

- **One write path for port assignment.** `IOSGamepad::set_maple_port()` (`flycast/shell/apple/emulator-ios/emulator/ios_gamepad.h:313-318`)
  is the only code that writes `playerIndex`. The UI never sets it directly; it calls through
  (`ControllerAssignmentView.swift:239-251`). A comment records that setting `playerIndex` alone was
  tried first and did not move the real port, so it was made a side effect of the canonical write.
- **Deliberate non-collision.** C++ installs `valueChangedHandler`; Swift installs
  `pressedChangedHandler` — different properties on the same button, documented at
  `GameControllerManager.swift:334-336`. Both fire harmlessly.
- **Per-brand Start relocation**, `applyDefaultStartButton` (`ios_gamepad.h:444-479`): DS4/DS5 with a
  touchpad put Start on the touchpad; anything with an Options/View/Share/`-` button puts Start
  there; a bare MFi with neither puts Start on R3. Menu is then reserved for pause.
- **tvOS Menu capture** in `EmulationEventViewController` (`Sources/UI/Views/EmulationViewController.swift:90-99`):
  `preferredFocusEnvironments` returns `[]`, `shouldUpdateFocus` returns `false`, and `pressesBegan`
  intercepts `.menu`, posts `.showPauseMenu`, and **does not call `super`**.
- **A LIFO scope stack** for app-UI input, `ControllerFocusCoordinator.swift:22-56`, so covered and
  covering surfaces stop double-routing. Self-contained and liftable.

### Tasks, in priority order

1. Wire `microGamepad.buttonMenu` to the pause menu, ungated, for the Siri Remote.
2. Give `extendedGamepad.buttonMenu`/`buttonOptions` an unconditional pause path. Keep the shoulder
   chord as an *additional* combo, not the only one.
3. Make `EmuEventVC.pressesBegan` post the pause notification on a short Menu press and not call
   `super` for it. Near-verbatim from iFly.
4. Collapse six writers into one. Pick the Swift engine (it is already unit-tested,
   `ControllerAssignmentServiceTests.swift`). Make the C++ side purely mechanical: enumerate and
   report candidates, never choose a port or write config.
5. Delete the bypass path at `TVControllerMappingBridge.mm:94-126`.
6. Make auto-assign system-aware; remove the hardcoded `isWii:NO` at `EmulationCoordinator.mm:1620`.
7. Port a `ControllerFocusCoordinator` equivalent; retire the per-screen swallow-closure pattern.
8. Consolidate the three `installExtraInputHandlers` call sites into one connect-time install plus
   scope-aware enable/disable.
9. Clear the module-level `shoulderStates` / `activeTurboControllers` / `touchpadIRStates` dictionaries
   (`ControllerExtensions.swift:15-36`) on teardown; they currently leak across games.

### Constraint

Do not try to transplant flycast's design. It has one bespoke `IOSGamepad` class with a single
`set_maple_port`. Dolphin routes input through the general-purpose `ciface`/`ControllerEmu`
framework with per-system INI profiles, polled rather than pushed, shared with every other Dolphin
backend. The arbitration layer must be built in the iOS app/bridge code.

### Acceptance

- Siri Remote Menu opens the pause menu during gameplay and still exits elsewhere.
- Every controller type reaches the pause menu without a chord: Xbox, DualShock/DualSense, Switch
  Pro, bare MFi.
- Connect/disconnect/reconnect three controllers repeatedly; port assignments stay put.
- Controllers connecting during a Wii game land on Wiimote slots.

---

## WS-3 — Webserver lifecycle ownership

**Ask:** item 3. **Size:** S. **Model:** Sonnet. **Depends on:** nothing. **Unblocks WS-4.**

### Current state

The port from iFly is **done**: single `NWListener` on one port, per-request WebDAV-versus-browser
classification, package-resource upload page, benchmark script, real tests. Verified merged.

### Root cause of "glitchy, doesn't always start"

Nobody owns the lifecycle.

- iOS starts it only from `SettingsRootView.swift:142`, in an `onAppear`. The comment above it
  admits there is no app-root start site. **If the user never opens Settings, the server never runs.**
- tvOS starts it at `TVRootView.swift:10`.
- `stop()` exists (`ROMUploadServer.swift:270`, `PVWebServer.swift:127`) and is **never called** from
  the app.
- There is no `scenePhase` handling anywhere near the webserver.

### Tasks

1. Add a `WebServerManager` as the single lifecycle owner, modelled on iFly's
   (`Sources/Core/WebServer/WebServerManager.swift`, 361 lines). Move both start sites into it.
2. Handle `scenePhase`: stop or keep alive deliberately on background, restart on foreground.
3. Decide iCube's stance on pausing the server during emulation. iFly stops it while a game runs
   because it competes for I/O (`WebServerManager.swift:313-343`), with exceptions for active
   transfers. The Sep 16 spec deliberately deferred this; revisit it now.
4. Port the establishment watchdog: a timer that cancels a socket which connects but never sends a
   complete request, so WebDAV clients retry cleanly instead of hanging (iFly
   `NativeWebServer.swift:135`, `:538-557`). Check whether iCube already has it before writing.
5. Port the Bonjour silent-failure self-check (`WebServerBonjourAdvertiser.swift:57-70`). `NetService`
   can fail to publish without erroring; iFly logs a warning if publication is not confirmed within
   five seconds. iCube's `advertiseWebDAV` (`ROMUploadServer.swift:249-262`) has no equivalent, so
   the same bug would be invisible here.
6. Fix the stale GCDWebServer claim in `CLAUDE.md`.
7. Tick the checkboxes in the Sep 16 plan, or mark it superseded, so the next reader is not misled
   the way this one was.

### Known perf gaps, deliberately deferred

iFly's own audit flags two it has not fixed: the download path still reads in 256 KB chunks with no
overlap (`NativeWebServer.swift:1325`) while the rest of the server uses 4 MB, and PROPFIND
double-stats every directory entry. Check whether iCube inherited these; do not fix ahead of iFly
unless download speed is a live complaint.

### Acceptance

- Fresh install, never open Settings: the server is reachable.
- Background the app for five minutes, return: still reachable, or deliberately restarted.
- WebDAV mount from Finder survives a sleep/wake cycle.

---

## WS-4 — Nearby library sharing and continuity handoff

**Ask:** items 4 and 6b. **Size:** L. **Model:** Opus. **Depends on:** WS-3.

**These are one workstream, not two.** In iFly both live in a single vendored SPM package,
`Externals/ContinuityKit/`, sharing one Bonjour service, one TXT beacon, one JSON-over-HTTP route
set and one trust store. Planning them apart duplicates discovery, pairing and transport.

### Prerequisite, and it is smaller than it looks

iCube's production server has **hardcoded private routes** — `routeRequest` / `routeHTTP` /
`routeWebDAV` (`ROMUploadServer.swift:875`, `:932`, `:1630`). iFly's equivalent exposes
`addAsyncHandler(forMethod:path:)` (`NativeWebServer.swift:521`), and ContinuityKit registers its
routes through a thin adapter (`Sources/Core/Continuity/ContinuityRegistrarAdapter.swift:7-27`).

So the prerequisite is **a route registry on the existing server**, not a new server. (An earlier
analysis called this the biggest net-new item because it only found iCube's *debug* server at
`Common/Swift/Debug/NativeWebServer.swift`. That one is MCP tooling and is the wrong host.)

### What iFly has

- **Discovery:** Bonjour `_ifly-continuity._tcp` via `NWBrowser` (`Discovery/ContinuityBrowser.swift:11-40`),
  published with `NetService` (`ContinuityBonjourAdvertiser.swift:31-39`). On iOS/iPadOS/macOS,
  `NSUserActivity` Handoff is the primary trigger; tvOS has no system Handoff so Bonjour is its only
  path (`Protocols/ContinuityAdvertising.swift:1-8`).
- **Transport:** custom HTTP on the app's own server. Client is `URLSession`, ephemeral, six
  connections per host, streams to disk, Range-based resume
  (`Client/URLSessionContinuityTransport.swift:4-24`).
- **Trust, two tiers.** Session-scoped: a 256-bit bearer token compared as a SHA-256 digest
  (`Server/BearerTokenValidator.swift:7-37`). Cross-session: a 6-digit pairing code with an
  HMAC-SHA256 proof binding both devices' Curve25519 keys (`Trust/ContinuityPairingMath.swift:15-41`),
  3 attempts, 120-second lifetime (`Trust/ContinuityPairingServer.swift:551-553`), persisted as
  public keys only (`Trust/ContinuityTrustStore.swift:16-68`).
- **Tokens are redacted from the LAN-visible Bonjour TXT** (`Model/ContinuityAdvertisement.swift:70-79`);
  only the same-user Handoff path carries one inline.
- **Manifest:** `Model/ContinuityManifest.swift:9-61` — session, source device, game identity, save
  state descriptor, files, BIOS, optional extras. Version-gated decode.
- **Fallback is a pure decision table** and fully unit-tested
  (`Fallback/ContinuityFallbackMachine.swift:45-80`): bootable if the ROM is local or was pulled
  complete; then proceed with pulled state, else latest local state, else fresh, else fail with
  `insufficientToBoot`. No silent stub. **Lift this verbatim.**
- **Pull ordering** by `FileKind.pullPriority` (`Model/FileKind.swift:1-40`), smallest first, so a
  mid-transfer failure leaves the most usable partial payload.
- **Library sharing granularity:** per-device via a `sharesLibrary` flag, per-game via
  `excludedFromNearbySharing`. Grants are per-peer: `.everything` / `.askPerGame` / `.denied`
  (`Trust/ContinuityLibraryGrantStore.swift:6-9`).
- **Offline variant:** a `.iflypkg` ZIP carrying the same manifest, for AirDrop
  (`Package/ContinuityPackage.swift:9-14`).

### Security posture to carry over consciously

The transport is **plaintext HTTP on the local network**. iFly documents this deliberately
(`ContinuityPairingMath.swift:7-12`): pairing authenticates peers, it does not add confidentiality.
Requires `NSAllowsLocalNetworking`. Adopt this as a stated tradeoff, not by accident.

### Tasks

1. Add a route registry to `ROMUploadServer` mirroring `addAsyncHandler`. **Prerequisite.**
2. Vendor an iCube-branded ContinuityKit. Lift near-verbatim: `ContinuityBrowser`,
   `ContinuityAdvertising`, `BearerTokenValidator`, `ContinuityPairingMath`, `ContinuityTrustStore`,
   `ContinuityFallbackMachine`, `ContinuityOutcome`, `ContinuityPuller`, transport, `ByteRangeRequest`,
   `ContinuityPackage`.
3. Write iCube's `GameIdentity`. iFly ladders flycast id → MD5 → serial; iCube should use the
   six-character Nintendo game ID it already uses as the state-file stem, with an MD5/CRC fallback
   for multi-disc and revisions.
4. Write iCube's `SaveStateDescriptor` against `{GameID}.s{NN}`. iFly warns the stem must be used
   verbatim and never re-derived; the same applies here.
5. Replace `FileKind`'s Dreamcast cases with GameCube/Wii ones. **Share this with WS-5 Task 2.**
6. Register the route set on the WS-1 server; wire `ContinuitySessionServer`.
7. Build the sender UI (pause-menu card, cf. `PauseMenuView+Continuity.swift:10-60`) and the
   receiver UI (browse view, cf. `ContinuityBrowseView.swift`). Both need full iCube rewrites.
8. Nearby Libraries on top: manifest/art/pull routes, grant store, per-game exclusion flag, and the
   settings surfaces.
9. Tuist/Info.plist: `NSBonjourServices` with an iCube service type, `NSLocalNetworkUsageDescription`,
   `NSUserActivityTypes`, `NSAllowsLocalNetworking`. Note iFly authors these in `Project.swift:86-108`,
   not the derived plist — do the same in iCube's Tuist config.

### Acceptance

- Two devices on one LAN see each other; a game handed off resumes at the same point.
- Receiving device without the ROM either pulls it or fails with a clear message. Never a stub.
- Revoking a peer's trust takes effect immediately.
- Per-game exclusion is honoured in the served manifest.

---

## WS-5 — CloudKit sync of everything except ROMs

**Ask:** item 6a. **Size:** L. **Model:** Opus. **Depends on:** nothing. Shares Task 2 with WS-4.

### iCube's starting point

**Zero.** No CloudKit, no peer transfer, no iCloud entitlement in any of the four entitlements
files. Also **no ORM at all** — no Realm, Core Data or SQLite. The library is a filesystem catalog
plus flat JSON side-stores (`GameProfiles.swift:22-54`, `SaveStateMetadataStore.swift`). This is
architecturally unlike iFly (SwiftData) and Provenance (Realm), and it cuts both ways: nothing to
reconcile against, but no scaffolding either.

### Where iCube's data actually lives

| Category | Path |
| --- | --- |
| Save states | `User/StateSaves/{GameID}.s{NN}` + `.json` sidecar + `.png` thumb |
| Resume state | `User/StateSaves/{GameID}.auto` |
| GC memory cards | `User/GC/MemoryCardA.raw`, `MemoryCardB.raw` |
| Wii saves | `User/Wii/` NAND tree |
| Settings | `User/Config/*.ini` |
| Per-game settings **and cheats** | `User/GameSettings/{GameID}.ini` |
| Artwork | `User/Cache/GameCovers/` |
| App prefs | `UserDefaults` / `@AppStorage`, ~27 files |

Note cheats and per-game settings share one INI. iFly keeps them separate; iCube cannot without a
split.

### What iFly does

Container `iCloud.com.joemattiello.iFly`, private DB, custom zone `FlycastSaves`, **one** record
type `FlycastSaveFile` (`CloudKitSyncProvider.swift:11`). Record name is the **relative path**
(`:246-251`), normalized through `CanonicalRelativePath` — a documented fix for a bug that mangled
this. `CKAsset` for every payload, no inline/asset branching (`:261-282`).

**Conflict resolution** (`TimestampConflictResolver.swift:8-29`): identical checksum wins
immediately; within a 5-second window with differing checksums it escalates to manual; otherwise
last-writer-wins by mtime. Deletions are **never** propagated — additive union merge only.
`SyncCoordinator` pre-filters by checksum and a 2-second mtime tolerance.

**ROM exclusion is structural first.** ROMs live in a sibling directory outside the scan root; the
extension blocklist and a 64 MB cap are belt-and-braces (`FlycastDataScanner.swift:17-19`, `:57-60`,
`:27`). `classify()` is a positive allow-list: anything unmatched is never synced (`:79-147`).
**Adopt the allow-list shape. Never write a blocklist.**

**Triggers** (all → `performSync()`): foreground/background, filesystem watchers with 500 ms debounce,
a 30-minute timer, and manual. Sync is gated off entirely while emulating and flushed on stop
(`SyncCoordinator.swift:97-101`, `:300-308`).

**Not synced by iFly:** artwork (no case exists), and the library database itself is explicitly
`cloudKitDatabase: .none`.

**Failure handling gaps worth improving:** no `CKError.requestRateLimited` handling and
`retryAfterSeconds` is never read; retries are generic exponential backoff, 3 attempts. No
`partialFailure` handling because it never batches — every write is a single-record save.

### Tasks

1. Provision a CloudKit container for iCube. Add `icloud-container-identifiers` and
   `icloud-services` to all entitlements files. Net-new capability.
2. **Write the classification allow-list against the table above.** Pure function, no network, fully
   unit-testable. **WS-4 Task 5 consumes this.** Decide explicitly: is artwork synced (iFly says no,
   but it is cheap and iCube caches remote art)? Are Wii NAND saves in scope, given size?
3. Port `CloudKitAvailability` — its entitlement-trap avoidance is Apple-generic — plus
   `SyncProvider`, `CloudKitSyncProvider`, `TimestampConflictResolver`, the directory watcher, and
   the `SyncCoordinator` state machine. Rename record type and zone.
4. Improve on iFly where it is weak: read `retryAfterSeconds`, and handle rate limiting explicitly.
5. Sync status UI: indicator, settings pane with per-category counts, conflict resolution view.
6. Decide the app-prefs story. `UserDefaults` is not covered by a file mirror;
   `NSUbiquitousKeyValueStore` is the usual answer and iCube uses none today.

### Acceptance

- Two signed-in devices converge on save states, memory cards and per-game settings.
- No ROM ever leaves the device. Assert this in a test against the classifier.
- Airplane mode, then reconnect: converges without loss.
- A genuine conflict surfaces for the user rather than silently discarding a save.

---

## WS-6 — Settings and emulation-menu UX

**Ask:** item 5. **Size:** M-L. **Model:** Sonnet, with a design pass. **Depends on:** see warning.

### Current state

`SettingsRootView.swift` is **5382 lines**. The root is a shallow `List` of about ten
`NavigationLink`s (`:393-455`), each pushing into its own flat sub-list. There is **no `.searchable`
anywhere** in the file. The tvOS Help screen is literally
`List { Text(L("TODO: Help content for tvOS")) }` (`:1747-1750`).

The in-game menu (`PauseMenuView.swift:55-77`) is a flat grid of seven or eight buttons, no search,
no quick toggles.

### What the reference apps do better

- **iFly** has a real sidebar architecture: eleven named, icon-labelled tabs
  (`SettingsView.swift:145-169`) in a persistent split view shared by iPad and tvOS (`:189-210`),
  plus genuine full-text search (`SettingsView+Search.swift:1-92`) that jumps to the matching tab and
  scroll-anchors to the section. Search is deliberately excluded on tvOS because remote text entry is
  slower than flipping through ten tabs — a good call worth copying.
- **Provenance** surfaces about twenty specific sections at the top level of one scrolling list
  (`SettingsSwiftUI.swift:1246-3112`), so "Haptics" or "RetroAchievements" is visible immediately
  rather than three taps deep. It also gives Documentation its own section.

### Tasks

1. Restructure the root into many specific sections rather than ten broad buckets.
2. Add full-text search on iOS/iPadOS; skip it on tvOS.
3. Replace `HelpPlaceholderView` with the real thing from WS-7.
4. Rework the pause menu: quick toggles for the things people reach for mid-game, and a layout that
   does not grow unboundedly as features land.
5. Split the 5382-line file. It is the single worst merge hazard in the repo.

### Conflict warning

Nearly every other workstream adds a settings row. Run WS-6 alone. Either first, so others build on
the new structure, or last. Never interleaved.

---

## WS-7 — In-app documentation

**Ask:** item 7. **Size:** S-M. **Model:** Sonnet. **Depends on:** nothing. Pairs with WS-6 Task 3.

### Current state

iCube has nothing. `DolphinBlogView.swift` reads the upstream Dolphin **blog** RSS feed (`:288`) and
opens posts in Safari — not help content, no caching, not contextual. tvOS Help is the TODO stub
above.

### What Provenance does

`PVHelp`, 839 lines across 6 files:

- Markdown fetched from a wiki repo's raw GitHub URL, with a parallel human-facing web base URL for
  link-outs (`WikiConstants.swift:3-4`).
- Cache-first with a 24-hour TTL and background refresh-if-stale
  (`WikiContentProvider.swift:18-24`, `:63-70`).
- **Offline fallback to a bundled `SUMMARY.md`** when there is no cache and no network (`:29-30`,
  `:48-56`); individual pages degrade to a placeholder rather than erroring.
- Navigation tree parsed from the wiki's own `SUMMARY.md`, so the app's table of contents is the
  wiki's table of contents.
- **Named constants for well-known pages** (`WikiConstants.Paths`, `:24-33`), which is the good part:
  `BIOSGuideLink` (`PVUI/Sources/PVUIBase/GameLaunching/BIOSGuideLink.swift:29-49`) attaches to every
  missing-BIOS error and turns a dead-end diagnostic into a button.

### Tasks

1. Decide the content source: an iCube-owned wiki repo, or the existing icube-emu.com content
   restructured as Markdown. The JIT guide written this month is a natural first page.
2. Port a `PVHelp`-shaped module: fetch, 24h cache, offline bundled fallback, `SUMMARY.md`-driven nav.
3. Replace `HelpPlaceholderView` (`SettingsRootView.swift:1747-1750`) and wire the Help link (`:440`).
4. Add the contextual-link helper. Best first targets in iCube: missing BIOS, the JIT/TXM settings
   rows, and save-state incompatibility.
5. Keep the site and the in-app docs on one source so they cannot drift.

### Acceptance

- Help is readable on a device in airplane mode that has never opened it.
- tvOS Help shows real content.
- At least three error surfaces offer a contextual link instead of only a message.

---

## Handing these out

Each workstream above is a self-contained brief. When dispatching, give the session: this file, the
workstream ID, and the reference repo paths. Tell it to verify current state before changing
anything, because this document is a snapshot and `655a85cf79`-style "written but never built" code
is a real hazard here.

Recommended first wave, five parallel sessions with no shared files: **WS-1**, **WS-2**, **WS-3**,
**WS-7**, **WS-8**.

One caution that applies to every workstream: this repo has shipped code that was written but never
built (`655a85cf79`). Verify current behaviour on a device before assuming a feature is missing —
several of these turned out to be present and broken rather than absent.

---

## WS-8 — tvOS first run, empty library, and the dead toolbar

**Ask:** added 2026-09-21. **Size:** S-M. **Model:** Sonnet. **Depends on:** nothing.

High user impact for a small amount of work: this is the first thing a new Apple TV user sees, and
right now most of it does nothing.

### 8a. The tvOS toolbar buttons genuinely do not work — root cause found

`libraryToolbar_tvOS` (`Common/Swift/TVLibraryView.swift:1300-1331`) has four items. Three of them
wrap a SwiftUI **`Menu`**:

| Item | Kind | Icon | Works on tvOS |
| --- | --- | --- | --- |
| `libraryViewMenu` (`:1377`) | `Menu` | `square.grid.3x3` | No |
| `libraryImportMenu` (`:1388`) | `Menu` | `square.and.arrow.down` | No |
| `librarySystemMenu` (`:1400`) | `Menu` | `gamecontroller` | No |
| `librarySettingsButton` (`:1412`) | `Button` | `gearshape` | Yes |

SwiftUI `Menu` has no usable tvOS presentation. The `.focusable(true)` modifiers applied to each
one (`:1318`, `:1322`, `:1326`) are a band-aid that suggests someone already hit focus trouble.
This exactly matches the report: the import and controller icons do nothing, while Settings — the
only plain `Button` — works.

**Fix:** on tvOS, replace each `Menu` with a focusable `Button` that pushes a list of the same
actions, or presents them in a sheet. The menu *contents* already exist as
`libraryViewMenuSection` / `libraryImportMenuSection` / `librarySystemMenuSection`, so they can be
reused as the body of the pushed screen. Do not try to make `Menu` work.

This is not limited to the empty library — it is broken with ROMs present too, since the toolbar is
the same in both states.

### 8b. Remove the unofficial-build notice

`Common/UI/BootNotice/UnofficialBuild/UnofficialBuildNoticeViewController.{h,m}` plus the tvOS
variant `Common/Swift/TVOSUnofficialBuildNotice.swift` (host at `:39`, C entry point
`TVOSMakeUnofficialBuildNoticeController` at `:58`). It interrupts first launch and lands in front
of the import flow.

Remove it rather than making it dismissible — that is the ask. Check for strings to prune in
`Common/UI/Localization/*/Core.strings` and the reference in `SettingsRootView.swift`. Confirm
nothing else depends on the boot-notice presentation chain before deleting, since `BootNotice/` may
host other notices.

### 8c. Give the empty library something useful

There is no meaningful empty state today. A first-run Apple TV user sees an empty grid and a
toolbar whose buttons do nothing, which is the worst possible combination.

The empty state should state plainly that no games were found and offer the routes that actually
work on tvOS: the Wi-Fi upload server with its on-screen URL (which after WS-3 will reliably be
running), adding a network source, and a link to the import documentation from WS-7. Prefer real
focusable buttons over instructional text, since the whole complaint is that nothing is actionable.

**Sequencing note:** 8a must land before 8c is meaningful, otherwise the empty state points at a
toolbar that still does nothing. Do 8b first since it is a deletion and unblocks testing the import
flow end to end.

### Acceptance

- On a fresh tvOS install the first screen offers at least one working route to getting a game on.
- Every toolbar icon on tvOS responds to a click.
- No unofficial-build dialog appears on first launch.
