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

App source checkpoint: `3277f2c6ffe8bf8204bc88260761c635e9aec038`. Later handoff changes affect QA/docs only.

- iOS 27.1 SDK Debug NJB app/test-target build passes; final app build with explicit focus routing also passes.
- tvOS 27.0 SDK Debug NJB app build passes with the explicit header/control/search focus routes. Both reuse committed simulator framework slices via `DOL_SKIP_CORE_BUILD=1 ICUBE_FAST_DEV=1`; no core rebuild or gameplay certification.
- Seven production eligibility/ordering XCTest cases pass standalone. The real iOS app-linked selection passes **8/8**: those seven plus the existing library-card body-metadata regression. The full app suite was not rerun for this port.
- Final iPhone 17 Pro / iOS 26.5 native XCTest: **22 actions pass**, including Games/Rooms, off-by-default Unverified, preference persistence, restore Off and dismissal. An earlier separate real long-press library context-menu run passed through the selected fixture's details and Back to the hub; that route is unchanged, while the later focus changes are covered by the final phone/TV flows.
- Apple TV 1080p / tvOS 26.5 native XCTest: **34 actions pass**, including header Right/Select, Down to the control, Off→On→Off, Menu to hub/library, search focus and Back. Focused/unfocused card text was visually reviewed. The original header Down transition failed for both the stock Switch and a Button; explicit `FocusState` routes repair it. The TV card also removes the stock toggle's low-contrast focused surface.
- SwiftFormat, strict SwiftLint on new Swift files, design-token and localized-key checks pass. English and Japanese keys are included.

### iPad gate remains open

The owned iPad Pro 13-inch M4 / iOS 26.5 simulator completed initial migration and a warm boot (16 seconds), but its native UI runner did not reach a test case after more than five minutes. That attempt was stopped. A single direct DEV app-launch request also failed to respond within two minutes and was stopped. The genuine 2064×2752 capture shows SpringBoard/Home, not iCube, so **no iPad app-layout acceptance is claimed**. The earlier unit-host attempt failed during bootstrap with Mach error -308; the same focused unit selection passes on the working phone.

A bounded follow-up narrows this to the simulator control/launch boundary rather than establishing an app crash: the compiled and installed app both identify as `com.joemattiello.iCube-debug` (build 13, minimum OS 17, device families 1 and 2), and the app/data containers exist. No matching app process was observed before or after the probe. Even a read-only `simctl get_app_container` timed out after 15 seconds; direct launch timed out after 30 seconds without a PID or output. A recent SpringBoard log query returned no matching bundle-launch event. The existing UI-runner exit is **-15 from explicit termination**, with no test-case-start record, not a failed iCube assertion. Full local details are in `build/network-play-evidence/ipad-classification.json`. Missing bundle files are ruled out; live install registration remains unconfirmed because its lookup stalls. Neither app exit/crash nor a PR-specific startup failure is established. Next: once that same simulator's container lookup responds, launch the existing built app once and run the prepared layout checks. This is not an irrecoverability claim or authorization for broad simulator repair.

Portrait actions are preserved in `Tools/release-audit/network-play-ipad-actions.json`. The standalone `NetworkPlayContextAuditTests.testIPadLandscapeLayout` compiles and is ready for the requested one-change `.landscapeLeft` check, but has **not run**. It requires real rendered 2752×2064 landscape Games/Rooms and Settings on this same initialized simulator; rotating or resizing a portrait image would not satisfy the gate. No further device/boot retry loop, global service restart or host cleanup was performed.

### Reproduce and inspect

The action runners are `Tools/dev-loop/FastInteractionTests.swift` and `FastInteractionSchema.swift`; prepare with the existing `Tools/dev-loop/icube.py` CLI. Each JSON file is a QA script, not a precomputed result. Register an explicit simulator target, install the validated DEV app, prepare the `actions` suite, then run:

```sh
python3 Tools/dev-loop/icube.py test --target YOUR_TARGET --suite actions --existing-dev \
  --only FastInteractionTests/testActions --actions Tools/release-audit/network-play-tv-actions.json
```

Use the phone/iPad JSON file for that target. `--existing-dev` makes no automatic binary-freshness claim: this run installed the manually built app from the isolated worktree's `Source/iOS/App/build-network-play/Build/Products` and keeps that provenance explicit. The standalone context/landscape audit is a simulator-only UI XCTest bundle; it imports no iCube internals and never boots a game. Native remote events are `XCUIRemote.shared.press(...)`; landscape uses `XCUIDevice.shared.orientation = .landscapeLeft`.

Raw build logs, `.xcresult` bundles, exported attachment manifests and full-resolution QA images are preserved under ignored `build/network-play-evidence/` in the owning worktree. Selected rendered QA images are linked below. Procedural DEBUG catalogue artwork in the game-details capture is a fixture; it is not real-game or NetPlay compatibility evidence. No marketing template has been created.

Physical hardware, two-peer gameplay, exact-ROM launch admission, actual discovery/hosting/joining, and the iPad portrait/landscape gate remain pending. CI/protection and main/release-owner review remain separate from these local results; this PR stays draft.


### Rendered QA evidence

These are real simulator renders, reduced in size only for PR review. Full-resolution exports and their XCTest manifests remain under `build/network-play-evidence/`. They are not marketing templates or NetPlay gameplay evidence.

| Evidence | Capture |
| --- | --- |
| Final phone hub, 1206×2622 original, portrait | [Games](network-play-2026-10-31/phone-games.png) |
| Final phone settings, portrait | [Settings](network-play-2026-10-31/phone-settings.png) |
| Final phone room-discovery unavailable state | [Rooms](network-play-2026-10-31/phone-rooms.png) |
| Selected game's details, procedural DEBUG fixture artwork | [Fixture details](network-play-2026-10-31/phone-fixture-details.png) |
| Final TV hub, 1920×1080 original, landscape | [Games/Rooms](network-play-2026-10-31/tv-games.png) |
| Final TV preference with actual focus and On value | [Focused settings](network-play-2026-10-31/tv-settings-focused.png) |
| Final TV search focus before Back | [Focused search](network-play-2026-10-31/tv-search-focused.png) |
| iPad portrait 2064×2752 and landscape 2752×2064 | Pending: no iCube UI rendered in the blocked attempt |
