# Ecosystem, App Intents and quick launch across iCube, iFly and Provenance

Date: 2026-09-24. Status: approved for implementation (three parallel workstreams).

## Goal

Give amateur users the system-level surfaces they already know: Siri, Shortcuts,
Spotlight, the Action button, home-screen quick actions and a widget, and let
Provenance see, launch and pull games from iCube the way it already does from iFly.
No File Provider work in this round.

## Existing building blocks (do not re-derive)

- iCube library snapshot: `Source/iOS/PVLibrarySnapshot` (App Group
  `group.com.joemattiello.icube`, `LibrarySnapshotStore().load()` returns
  `LibrarySnapshot` with `recentlyPlayed`, `favorites`, `byGameID`; games carry
  `id` (6-char disc ID), `title`, `filePath`, `isFavorite`, `lastPlayed`, cover under
  `LibrarySnapshotAppGroup` media dir). `dolphinios://play?id=<gameID>` is handled in
  `Source/iOS/App/Common/MainDisplaySceneDelegate.swift`, which also already has
  `performActionFor shortcutItem` and `handleShortcut`.
- iCube already ships a WidgetKit extension: `Source/iOS/App/Live Activity/`
  (`Live_ActivityBundle: WidgetBundle`, target `LiveActivityExtension`, embedded when
  `APP_EMBEDS_APPEX`). New widgets go into that bundle, not a new target.
- iCube peer transfer server: `Source/iOS/PVContinuity` (Bonjour + HTTP session server
  with bearer token, ported from iFly). iFly's `Sources/Core/Ecosystem/EcosystemShareCenter.swift`
  shows how to answer a `requestGame` with a short-lived session on that server.
- iFly: SwiftData library (`GameEntry`, `ModelContext`), `.onOpenURL` in
  `Sources/App/iFlyApp.swift`, `ifly://open?md5=`, widgets share via
  `Sources/Shared/WidgetSharedData.swift`, App Group `group.com.joemattiello.ifly`.
- Provenance: `PVAppIntents` (entities in `Entities/`, intents in `Intents/`, the
  pattern is: intent writes a pending key to App Group defaults, app reads it in
  `applicationDidBecomeActive`). Ecosystem hub: `PVLibrary/.../EcosystemIntegration/
  EcosystemApp.swift`, `EcosystemFetchService.swift`, callbacks parsed in
  `PVUI/.../PVAppDelegate+Open.swift`, UI in `PVUI/.../EcosystemIntegrationView.swift`.

## Workstream A: iCube App Intents, Spotlight, widget, quick actions

- New SwiftPM-free source folder `Source/iOS/App/Common/AppIntents/` in the app target:
  `iCubeGameEntity` (`AppEntity`, id = snapshot game id, `EntityQuery` with
  `entities(for:)`, `suggestedEntities()` = recently played + favorites,
  `EntityStringQuery` on title), `LaunchGameIntent`, `ContinueLastGameIntent`,
  `PlayRandomGameIntent`, and an `AppShortcutsProvider` with phrases
  ("Play \(.$game) in iCube", "Continue my game in iCube", "Play a random game in iCube").
  Intents run with `openAppWhenRun = true` and hand off through the existing
  `dolphinios://play?id=` path (write a pending id to the shared suite, the scene
  delegate consumes it on activation, same as Provenance's pattern).
- Spotlight: `SpotlightIndexService` already exists in
  `Source/iOS/App/Common/Services/`; extend it to index every snapshot game as a
  `CSSearchableItem` (title, platform, cover thumbnail data, `contentType` = the
  exported disc UTI) whenever the snapshot is rewritten, and handle
  `CSSearchableItemActionType` in `scene(_:continue:)` to launch the game.
  On iOS 18+, also conform the entity to `IndexedEntity` so Siri Suggestions and
  Spotlight show the same entities; keep iOS 17 compiling with availability.
- Quick actions: after every snapshot write, set `UIApplication.shared.shortcutItems`
  to the three most recent games (type `com.joemattiello.icube.play`, userInfo `id`);
  route through the existing `handleShortcut`.
- Widget: add `RecentGamesWidget` (small and medium, last 1 or 3 played with cover
  art, each cell is a `Link` to `dolphinios://play?id=`) to `Live_ActivityBundle`.
  Data comes from the App Group snapshot; the app calls
  `WidgetCenter.shared.reloadTimelines(ofKind:)` after each snapshot write.
- tvOS: intents compile on tvOS 17 but the shortcuts provider and widget are iOS only.

## Workstream B: iFly App Intents and Spotlight

Same shape as A, against SwiftData: `iFlyGameEntity` (id = md5), `LaunchGameIntent`,
`ContinueLastGameIntent`, `PlayRandomGameIntent`, `AppShortcutsProvider`, launch via
the existing `ifly://open?md5=` route. Spotlight index of the library on every library
change (there is no snapshot; observe the existing library change notification or the
`LibraryManager` save path) plus `CSSearchableItemActionType` handling in
`iFlyApp`'s `onContinueUserActivity`. Widgets and Top Shelf already exist; leave them.
No home-screen quick actions unless iFly already has none and it is under 30 lines.

## Workstream C: iCube joins the Provenance ecosystem

Protocol (mirrors iFly's, identity is the 6-char disc game ID instead of md5):

| Direction | URL |
|---|---|
| Provenance asks for the library | `dolphinios://gameInfo?scheme=<cb>` |
| iCube answers | `<cb>://dolphinios?games=<base64url JSON [EcosystemGameScheme]>` (`titleId` = game id, `titleName`, `developer` = maker code, `version` = platform name) |
| Provenance launches a game | `dolphinios://play?id=<gameID>` (add `open?id=` as an alias) |
| Provenance asks for the files | `dolphinios://requestGame?id=<gameID>&scheme=<cb>` |
| iCube answers after user consent | `<cb>://dolphinios?fetch=<base64url JSON FetchPayload>` |

`FetchPayload` field names are fixed by `EcosystemFetchPayload` in Provenance
(`name`, `md5`, `bases`, `manifestPath`, `filePath`, `fileQueryKey`, `token`). iCube
fills `md5` with a lowercase hex transfer id, the first 32 hex chars of
SHA-256(`gameID + "/" + filename`), because hashing a multi-GB disc image on request is
not acceptable; Provenance only checks that the prefix is hex.

Provenance changes: register the `provenance-ecosystem` marker scheme in both
`Provenance-Info.plist` and `Provenance-AppStore-Info.plist` (the code already expects
it, iFly probes it, and it is missing today); add `dolphinios` to
`LSApplicationQueriesSchemes`; add `case icube = "dolphinios"` to `EcosystemApp`
(display "iCube", platform "GameCube · Wii", symbol `cube`); make
`EcosystemFetchService` name the import container `<displayName>-<8 hex>` instead of
the hardcoded `iFly-`; show iCube in `EcosystemIntegrationView` exactly like iFly.

iCube changes: `LSApplicationQueriesSchemes` gains `provenance` and
`provenance-ecosystem`; new `Source/iOS/App/Common/Ecosystem/` with `EcosystemBridge`
(parse the three routes, validate the callback scheme with the same charset rule iFly
uses, build callbacks) and `EcosystemShareCenter` (consent sheet, then a short-lived
PVContinuity session serving the game's files, then the fetch callback); a
"Send to Provenance" item in the game context menu that only appears when the marker
scheme resolves. Wire the routes into `MainDisplaySceneDelegate.openURLContexts`.

## Out of scope

File Provider extensions, iFly-to-iCube direct transfer, metadata-rich Quick Look,
tvOS for anything that needs `UIApplication.open` of a foreign scheme.

## Verification

Each workstream builds its app for iOS (and tvOS where the target is multiplatform)
with the Tuist workspace, runs the module's unit tests where a test target exists,
and adds unit tests for pure logic (entity queries against a fixture snapshot, URL
parsing and callback building, transfer-id derivation). Device gates are Joe's.
