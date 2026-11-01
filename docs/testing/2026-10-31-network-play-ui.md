# Network Play UI port — draft scope

Owner-authorized port of Provenance's approved library-first Network Play design. Tracking: [#74](https://github.com/Provenance-Emu/iCube/issues/74). Base: `1101f524c2e0dc3a224c62d9771eb9c13e9df230`; branch: `codex/network-play-ui`.

## Delivered behavior

The library View menu opens an opaque themed full-screen Games/Rooms hub. Each game card context menu opens its multiplayer details directly. Phones use Games/Rooms tabs; wider layouts show both columns. Settings contains an off-by-default Unverified browsing preference. iCube typography, artwork, card focus and room tokens are reused. TV Back leaves search first, then returns from Settings/details to the hub, then to the library.

All recommendations are intentionally empty on this build. Unknown games are excluded from Suggested, All Supported, Recent and Favorites, including when Unverified browsing is enabled. That preference permits browsing only real local files; synthetic screenshot games and remote entries are excluded. A context-selected game's details explain the separate documentation, app connection and test evidence states.

## Backend audit and boundaries

`Source/iOS/App/Common` has no NetPlay client/server session, room-discovery service, NetPlay boot entry point or UI callback adapter. Existing mentions concern configuration layers and logging. `Source/Core/Core/NetPlayClient.{h,cpp}`, `NetPlayServer.{h,cpp}` and Qt/Android adapters implement Dolphin's protocol; their presence does not establish an iCube app integration.

Provenance's `Cores/Dolphin/PVDolphinCore/Core/PVDolphinCore+Netplay.mm` is a separate wrapper integration. It is not linked through iCube's app wrapper and was not copied. This UI PR changes no emulator/core source and installs no network backend. No room is fabricated; discovery is explicitly unavailable rather than shown as a successful search with zero results. Host/Join are explanatory unavailable states, never launch actions. Connection settings without a functioning integration are not offered.

The partial GameTDB catalog describes player modes, not per-game netplay compatibility. It is not bundled or title-matched by this PR. iCube currently has neither a trusted per-dump multiplayer confirmation store nor a reliable patched-variant identity at this surface; every adapted local game therefore has unknown documentation. No Tested or Verified badge exists. The pure eligibility policy's documented-mode/backend fixtures are tests, not production compatibility data.

## Separate backend prerequisite

Before enabling Host/Join, a separate change must provide an iCube-owned lifecycle adapter around the existing Dolphin protocol: serialize client/server creation and teardown; route Dolphin UI callbacks safely; match exact ROM/version/mode and bounds; recheck availability and file identity at admission; connect NetPlay boot to iCube's emulation coordinator with disconnect/error recovery; expose real discovery or manual connection results; and restore normal local input/config ownership after stop. Spectators, timing, relay and room-size controls must follow that integration's actual capabilities.

Eligibility metadata requires trustworthy provenance plus unpatched identity or exact-ROM confirmations, not disc prefixes or custom titles. Actual tested evidence must identify exact dump, core version, app build, platform and mode. Two-peer gameplay, mismatched-ROM rejection, host loss and reconnect remain unverified and cannot be established by this UI PR.

## Validation

Build, rule-test and native simulator results will be appended before review. Physical hardware and two-peer gameplay are outside this draft's verified scope.
