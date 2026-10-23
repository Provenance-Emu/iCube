# iPhone as the Wii Remote on Apple TV — one-tap design

Status: APPROVED 2026-10-23 for Phases 0 and 1. Nothing here is built yet.

**Owner decisions (2026-10-23):**
1. Trust model **(a)**: the TV confirms each new phone once per TV launch, and a phone in a one-tap
   session switches its DSU server to approval-required and answers only the TV the user approves on
   the phone's prompt. Nothing connects silently.
2. Touch-drag pointer from the phone: later (Phase 3); gyro only for now.
3. A pad already on Wii Remote 1: the phone takes Wii Remote 2.
4. Device name: an editable "Device Name" in iCube's Settings → Nearby, defaulting to the system name,
   used by Continuity and the DSU advert. No entitlement request.
5. TV-initiated connect (Phase 2, PVContinuity route): deferred.
Builds on the Siri Remote / pointer-source work
([design](2026-10-21-siri-remote-and-pointer-sources-design.md),
[plan](../plans/2026-10-22-siri-remote-pointer-sources.md)).

## Intent

Owner, 2026-10-22: the Siri Remote can't be a Wii pointer (the current remote has no motion API at
all; only the 2015 remote does), "phone has gyro … maybe a phone could be used as a touch or gyro ir
controller (we may already have that, just make it easier to setup and use)".

Goal: someone on the couch with an Apple TV and an iPhone, and no gyro controller, plays a Wii game
with the iPhone as Wii Remote 1, pointer included, after **one tap** and no IP addresses, ports or
settings screens.

## What exists (code read 2026-10-22)

Paths under `Source/iOS/App/`.

- **Phone DSU server** — `Common/Bridging/DSUServerBridge.{h,mm}`: cemuhook UDP server, port 26760, one
  pad (id 0); buttons, sticks, triggers, two touch points, accelerometer (g) and gyro (deg/s); 60 Hz
  push to every client seen. Bonjour `_dolphin-dsu._udp` named `UIDevice.current.name`; TXT only
  `layout`, `ext`, `sideways`, and only after the controller screen appears. Client approval exists
  (`dsu_approval_required`, allow list by IP, `setRestrictToClient`) but is **off by default**.
- **Phone controller screen** — `Common/Swift/DSUSessionView.swift` (Form: start/stop, port, QR code
  and `dolphinios://dsu/add?ip=&port=` link) opens `Common/Swift/Widgets/DSUControllerView.swift`
  (layouts: Apple virtual, GameCube, Wii Remote, Classic, sideways Wii; pointer modes Gyro / Follow /
  Drag via `PointerModeController`). `TCDeviceMotion.setDSUStreaming(true)` streams the phone's motion.
  Reached from Library menu → System → "Start DSU Controller" (iOS only). No idle-timer disable, no
  background handling: the screen can auto-lock and the stream stops when the app leaves the front.
- **Apple TV DSU client** — Dolphin core `DualShockUDPClient` (`DSUClient.ini` `[Server] Enabled`,
  `Entries = desc:ip:port;…`), bridged by `DOLConfigBridge` `dsuClientEnabled` / `addDsuServer`.
  Devices appear as `DSUClient/<pad>/<desc>` and the assignment engine treats them as physical pads
  (auto-assigned, can take Player 1). Default profile "DSU"; Wiimote `Data/Sys/Profiles/Wiimote/DSU.ini`
  binds buttons, `IMUAccelerometer/*` → `Accel *`, `IMUGyroscope/*` → `Gyro *`, `IMUIR/Enabled = True`,
  and **no IR/touch rows**: the pointer is gyro-only, and the phone's touch pointer is never used.
  The client's `Touch X/Y` inputs are relative (accumulated deltas, clamped).
- **TV discovery** — `Common/UI/Settings/SwiftUI/DSUDiscovery.swift` browses `_dolphin-dsu._udp` and
  lists servers in `DSUSettingsView` (Hub → Setup → "Motion Source (DSU)"); "Add" does not enable the
  client and nothing assigns the device.
- **Continuity** — `Common/Continuity/ContinuityManager.swift` over the PVContinuity package (separate
  repo): Bonjour `_icube-continuity._tcp` with `pid` (stable peer id) and `dt` (`ip`/`pd`/`tv`/`mc`),
  Ed25519 pairing (`trustedPeers`), HTTP routes for handoff and library sharing, and an approval-prompt
  pattern (`ContinuityApprovalRequest`). There is **no** generic request route, and a phone only
  advertises while handing off or sharing its library.
- **Pointer sources** — `Common/Swift/Controllers/PointerSource.swift`: a DSU Player 1 resolves as a
  pad with no capabilities, so tvOS falls to `.remoteGyro` (if a 2015 remote is around) or `.none`,
  and `RemotePointerBinding` would then fight the phone's IMU pointer.
- **No-controller notice** — `Common/Swift/Controllers/NoControllerNotice.swift`: two rows today;
  a stale DSU entry counts as a gameplay pad and suppresses it.

## Bugs to fix first (independent of the one-tap flow)

1. **`_dolphin-dsu._udp` is not in `NSBonjourServices`** in either Info.plist. On iOS 14+/tvOS an
   undeclared type fails to publish/browse silently, so DSU discovery is very likely broken on device
   today. Add it to both (iOS and tvOS plists).
2. **Every phone is probably named "iPhone".** iOS 16+ returns the generic model name from
   `UIDevice.current.name` without the `user-assigned-device-name` entitlement, which iCube does not
   have. Continuity's identity uses the same call (`ContinuityManager.deviceName()`), so there is no
   user-editable name today. Proposed: a "Device Name" field in Settings → Nearby, defaulting to the
   system name, used by both Continuity and the DSU advert (owner question 4).
3. **Phone screen sleeps / stream dies in background.** Disable the idle timer while the controller
   screen is up; stop and restart the server on scene phase changes instead of silently going quiet.

## Design

### The one tap: on the phone (Phase 1, no package changes)

The phone cannot be woken by the TV (an iOS app in the background receives nothing), so the tap that
always works is on the phone, which the user is holding anyway.

- **Phone entry points**, all landing on the same full-screen controller:
  - iCube library: a prominent "Play on Apple TV" button (not buried under System), shown when a TV
    running iCube is on the network (Continuity browse sees `dt=tv`) or always as a secondary action.
  - An App Intent / Control Center control and a Lock Screen widget button, "Use iPhone as Wii Remote",
    so it is one tap without opening the app (the app opens straight to the controller).
- **What the tap does:** start the DSU server, open `DSUControllerView` in the Wii Remote layout with
  the Gyro pointer, keep the screen awake, and advertise `_dolphin-dsu._udp` with an identity TXT:
  `pid` (Continuity peer id), `name` (the iCube device name), `dt`, `role=controller`, `v=1`.
- **TV side, automatic:** while iCube is in the foreground the TV browses `_dolphin-dsu._udp` (it already
  can). For an advert with `role=controller`:
  - from any phone not yet confirmed in this TV launch: a confirm panel "Use 'Joe's iPhone' as a
    controller?" (Allow / Not Now) on the TV (decision 1); on Allow, add it to `DSUClient.ini`, enable
    the client, and show a toast "Joe's iPhone joined as Wii Remote 1";
  - the phone, in approval-required mode, shows its existing new-client prompt for the TV's first
    request and then answers only that TV (`setRestrictToClient`).
- **Assignment:** the existing engine already seats a connected DSU device in the first free slot and
  lets it take Player 1. For a Wii title the phone becomes Wii Remote 1 when no physical pad holds it;
  if a pad does, the phone takes the next Wii Remote (owner question 3).
- **Leaving:** the phone's "Done" (or the app backgrounding) stops the server; the TV removes the
  auto-added entry when the device has been gone for 10 s, so a stale phone never suppresses the
  no-controller notice.

### Pointer: wired into pointer sources

- New `PointerSource.phoneGyro(name:)` (persisted `Kind` raw value `phoneGyro`), label "%@ gyro"
  (e.g. "Joe's iPhone gyro"), icon `iphone.radiowaves.left.and.right`.
- `PointerPlayer1.from(qualifier:pads:)` recognises `DSUClient/` qualifiers as a phone with gyro
  (capability from the advert's TXT, default gyro on).
- Resolver order on tvOS becomes: override → pad gyro → pad touchpad → **phone gyro** → remote gyro →
  none. On iOS the phone *is* the device, so this only matters on tvOS (and an iPad host).
- `RemotePointerBinding.apply` unbinds for `.phoneGyro` (the phone's IMU pointer is the source).
- The "No pointer" explanation on tvOS gains "or use your iPhone as the Wii Remote".
- Touch pointer from the phone: the client's touch axes are relative, so the phone's **Drag** mode
  maps naturally; **Follow** (absolute) does not. Phase 1 ships Gyro only for the TV pointer, with the
  phone's Drag mode bound through a `DSU (Touch).ini` Wiimote variant as a follow-up (owner question 2).

### On the TV: making it discoverable (Phase 1)

- **No-controller notice** gets a third row, "Use your iPhone", which shows a short panel: a QR code to
  the App Store / iCube, and "Open iCube on your iPhone and tap Play on Apple TV". If a paired phone is
  already advertising, the row says "Use Joe's iPhone" and simply connects it.
- **Controllers hub:** a "Phones" section listing advertising phones with Connect / Disconnect, and the
  existing DSU settings stay for manual servers (PCs, third-party DSU apps).

### TV-initiated request (Phase 2, needs PVContinuity)

A TV-side "Use Joe's iPhone" that works when the phone's iCube is open but not on the controller screen:
a new authenticated PVContinuity route (`POST /api/continuity/controller/request`) between paired
peers; the phone shows an approval prompt (the library-pull pattern) and opens the controller. It does
nothing when the phone app is closed, so it is a convenience on top of Phase 1, not a replacement. The
phone also has to advertise Continuity while iCube is open for this to find it (today it only does
while sharing). Package change: tag a PVContinuity release and bump the pin.

## Goals, non-goals, anti-goals

- Goals: one tap on the phone; zero typing; the pointer works and is labelled with the phone's name;
  a stale or departed phone never blocks the no-controller notice; paired phones connect without a prompt.
- Non-goals: Apple Watch and AirPods head-tracking (both would relay through the phone: extra latency,
  little gain); the 2015 Siri Remote; real Wii Remotes (Apple TV cannot pair them); encryption of the
  DSU stream (LAN-only and documented, same as Continuity).
- Anti-goals: any LAN device silently driving a game (today's default-open server); a phone that
  locks mid-game and leaves the player frozen without a message; breaking manual DSU use with PCs or
  third-party DSU apps (DSUController, MotionSourceiOS).

## Phases

0. Bug fixes 1–3 above. Small, testable now, worth shipping alone.
1. Phone one-tap entry (library button + App Intent/Control), identity TXT, TV auto-connect with
   paired/unknown handling, departure cleanup, `.phoneGyro` pointer source, notice and hub rows.
2. PVContinuity request route for a TV-initiated connect.
3. Touch (Drag) pointer from the phone via a DSU touch Wiimote profile variant.

Gate for each phase: unit tests for the resolver, TXT parsing, auto-connect decisions and cleanup; a
tvOS + iOS simulator build; and **a device test with a real iPhone and Apple TV**, including latency
("does the cursor feel connected?") and screen-lock/background behaviour.

## Builder check (2026-10-22) — answers folded in

- **Mid-game connect works without a restart.** The core's DSU client registers a config-changed
  callback (`DualShockUDPClient.cpp:423`, `:486`) and restarts its backend when `Enabled` or `Entries`
  change, so adding or removing a server from the app takes effect in a running game.
- **Endpoint freshness (my call):** auto-added entries are rewritten on every Bonjour re-resolve (IP or
  port change), keyed by the advert's `pid`; the entry `desc` is the phone's name, made unique with
  " (2)" when two phones share one. The capability TXT is matched by that same `desc`.
- **Browser lifetime (my call):** the TV browses whenever iCube is in the foreground, library included,
  so a phone started before the game is already seated; the notice row lives inside the existing
  once-per-boot notice.
- **Non-Wii games (my call):** the phone seats like any DSU pad through the existing engine (GameCube
  titles use `GCPad/DSU.ini`); the Wiimote `DSU.ini` works on any Wii Remote slot.
- **Local network usage text:** present for iOS too, through `INFOPLIST_KEY_NSLocalNetworkUsageDescription`
  in `Project.swift`.
- **Trust is the real open question** (below, question 1): TXT records are unauthenticated, so a
  claimed `pid` proves nothing, and the phone's server is open by default.

## Open questions for the owner

1. **Trust model.** TXT is unauthenticated, so "paired phones connect silently" is spoofable on the LAN.
   Options:
   (a) **TV confirms every new phone once per TV launch**, and the phone switches its server to
       approval-required for one-tap sessions, so it answers only the TV the user picked on the phone's
       existing approval prompt (proposed: two quick confirms, no pairing needed, nothing silent);
   (b) paired Continuity peers connect silently after a signed challenge over the Continuity routes
       (needs the PVContinuity change from Phase 2 first);
   (c) accept any advertising iCube phone silently (simplest, matches today's open DSU default).
2. **Touch pointer from the phone:** worth Phase 3, or is gyro enough?
3. **A pad already holds Wii Remote 1:** phone takes Wii Remote 2 (proposed), or offers to take
   Player 1?
4. **Device names:** request Apple's user-assigned-device-name entitlement, or use the name set in
   iCube (proposed: iCube's Continuity name, no entitlement request)?
5. **Phase 2:** worth a PVContinuity release for a TV-side connect that only works while the phone app
   is open?

## Calls I made

- Phone-initiated first: it is the only tap that works without the phone app already open.
- Reuse DSU rather than a new protocol: it works with third-party DSU apps and PCs, and the core already
  consumes it.
- Gyro-only TV pointer in Phase 1; the existing Wiimote `DSU.ini` already drives the IMU pointer from it.
- Auto-added DSU entries are owned by the auto-connect code and removed by it; manual entries are never
  touched.
