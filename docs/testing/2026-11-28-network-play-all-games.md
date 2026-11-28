# Network Play: every game offered

Supersedes the list rules in [the 2026-10-31 UI port](2026-10-31-network-play-ui.md). Its backend audit still holds: iCube has no NetPlay session adapter, so the screen cannot host, join or discover rooms and says so.

## What changed

- Every library game this device can run is listed: an entry with no local file, a demo entry, or a system other than GameCube, Wii and WiiWare is left out. The eligibility policy, the Suggested / All Supported / Unverified filters, the "Show unverified games" setting and its stored preference (`network_play_show_unverified_v1`) are gone. The filters are All Games, Recent and Favorites.
- A game carries an optional hint: unknown (the default, drawn as nothing), "Reported working" or "Reported broken". A hint never hides a game or changes the order. `NetworkPlayLibrary.hint(forGameID:)` is the one place hints come from; it returns unknown for every game until a community database answers there.
- The screen is three tabs: Your Games, Nearby Rooms, Settings. Settings is a tab, not a button in the header. The tab row and the filter row scroll sideways when they are wider than the screen.
- Apple TV: Network Play is a row in the library rail and no longer an entry in the View menu. iPhone and iPad keep it in the View menu and in each game's context menu.
- Apple TV: the search row is a standard row button that opens the system text entry, because a text field there draws the system's white focus plate. Entering the tab or filter row focuses the chosen one. The remote's Back button leaves a game's details, then the screen; there is no on-screen Back button on Apple TV.

## Checks

- tvOS simulator app build: passes (`iCube (UI)` scheme, Debug (Non-Jailbroken), prebuilt core slice).
- iOS simulator app and test target build: passes (`build-for-testing`, same scheme).
- `NetworkPlayLibraryTests`: 7 of 7 pass, run on macOS in a throwaway Swift package holding `NetworkPlayLibrary.swift` and the test file, because no iPhone simulator could be created on the build machine that day. They were compiled for iOS with the test target but not run there.
- `Tools/dev-loop/test_action_schema.py`: passes.
- Apple TV 4K (3rd generation) simulator, tvOS 27.0, real remote presses through `Tools/release-audit/network-play-tv-actions.json`: see the pull request for which steps ran and their captures.

## Not checked

A real Apple TV, a real iPhone or iPad, the phone and iPad action scripts, `NetworkPlayContextAuditTests`, and anything involving two devices: there is no session to test.
