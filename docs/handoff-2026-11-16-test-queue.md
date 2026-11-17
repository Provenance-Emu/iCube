# Test queue, 2026-11-16

Everything below compiled and passed its unit tests in the simulator. None of it has run on a device.
Tick items off here as they are checked; add the build number you tested.

Where the code is:

- **Sections 1 to 6 and 8 are on `develop`, pushed 2026-11-16** (`c929cbbc6a`): the five feature branches plus
  `fix/release-triage-and-catalyst`.
- **The Mac desktop work in section 7 is on the local branch `feature/catalyst-desktop`**, checked out at
  `~/Workspace/Provenance/_worktrees/icube-integration`. Not pushed.
- **Not committed:** the rebuilt iOS and tvOS core slices in the main checkout.

## 1. Background downloads for remote libraries

Branch `claude/bg-remote-downloads-d0ef06`. Needs an Emulation Server, a RomM server and a WebDAV share.

- [ ] Emulation Server: start a large game download, leave the app for several minutes, return. The game is in
      the library and boots.
- [ ] Emulation Server: start a download, force-quit from the app switcher is NOT the test (iOS cancels those).
      Instead let iOS end the app in the background (open several heavy apps), then reopen: the download finishes
      on the next launch without tapping the game again.
- [ ] RomM single-file game: same leave-and-return check.
- [ ] RomM multi-file game: expected limit, the next file only starts while iCube is running. Confirm nothing is
      lost and a second tap picks up the files that already arrived.
- [ ] WebDAV: leave-and-return check. After the app was ended, tapping the item again adopts the finished file
      rather than downloading again.
- [ ] Tap the same game twice while it downloads: one download, not two.
- [ ] Revoke the device on the Emulation Server mid-download: the "server denied access" path shows, and no
      broken file lands in the library.
- [ ] Change the WebDAV password mid-download: access-denied message, no error page saved as a game.
- [ ] Airplane mode mid-download, then back: it resumes rather than restarting (check the byte count).
- [ ] tvOS: one leave-and-return download.

Known limits to keep in mind (not bugs to file):

- No screen shows a running download after a relaunch; it reconnects when the same game is tapped.
- A redirect to another host is rejected, but the Authorization header may already have been sent there.
  Decide whether that needs a fix before 1.0.

## 2. Silent CloudKit push for save sync

Branch `claude/cloudkit-silent-push-095177`. Needs two devices on one iCloud account, both with iCloud sync on.
Silent pushes never arrive in the simulator.

- [ ] Save in a game on device A. Device B is locked with iCube suspended. Within a few minutes, open B with no
      network: the new save is already there.
- [ ] Same, while B is in a game: nothing is written under the running game; the change applies after the game
      ends, through the usual conflict prompt if there is one.
- [ ] Make five saves quickly on A: B syncs once or twice, not five times (Console: one run per burst).
- [ ] Debug build and TestFlight build on the same device: each subscribes in its own CloudKit environment.
- [ ] Delete iCube's data in iCloud settings, then sync again: the subscription is recreated within a week, or at
      once after reinstalling.
- [ ] tvOS: receive a change from an iPhone while the Apple TV app is in the background.
- [ ] Battery and data: leave B idle for a day with A in use; check iCube's background activity in Settings.

## 3. Long imports that continue in the background

Branch `claude/bg-continued-imports-4376c6`. iOS 26 or later only; older systems, tvOS and the Mac keep the old
behaviour.

- [ ] iOS 26+: import a multi-gigabyte image from Files, leave the app at once. The system progress UI appears,
      the import finishes, the game boots.
- [ ] Import three files at once: one task with combined progress.
- [ ] Cancel from the system progress UI: the copy stops, no partial file is left under the final name, and the
      library shows no broken entry.
- [ ] Lock the phone for the whole import.
- [ ] iOS 17 or 18 device: import behaves exactly as before.
- [ ] iPad app on a Mac ("Designed for iPad"): import still works (the new path is switched off there).
- [ ] Upload check: App Store Connect accepts a build that has `BGTaskSchedulerPermittedIdentifiers` and no
      `processing` background mode. The docs do not say; the first TestFlight upload will.

Not covered by this change: web uploads, NAND import, disc patches, skin and mod installs.

## 4. Live Activity and Control Center control

Branch `claude/widget-live-activity-control-e2ab75`. iPhone and iPad only.

- [ ] First TestFlight archive with the widget extension embedded: automatic signing creates the
      `com.joemattiello.iCube.Live-Activity` App ID and profile, and the upload is accepted.
- [ ] Start a game: a Live Activity appears on the Lock Screen and in the Dynamic Island with the right title.
- [ ] Play for ten minutes: the title and subtitle stay (they used to blank after the first update).
- [ ] Quit the game: the activity ends. Kill the app mid-game and relaunch: the stale activity is removed.
- [ ] Start game A, quit, start game B: only B's activity shows.
- [ ] Add "Resume Last Game" to Control Center (iOS 18+). Tap with the app closed: iCube opens into the last game.
- [ ] Tap it with no game ever played: the app just opens.
- [ ] Tap it while a different game is running: note what happens (launches still end the running game without
      asking; the prompt for that is not built yet).
- [ ] Recent Games widget still draws on the Home Screen.

## 5. AirPlay button and universal links

Branch `claude/airplay-universal-links-0dbc1f`.

- [ ] Pause menu on iPhone and iPad shows the AirPlay button beside Close; it is absent on Apple TV.
- [ ] Pick an Apple TV or AirPlay speaker: write down what you actually get (mirrored video with sound, sound
      only, or nothing) and whether the game keeps its frame rate.
- [ ] Universal links need the owner steps below first. Then: paste `https://icube-emu.com/play?id=<game id>`
      into Notes and tap it, with the app closed and with it open. Long-press shows "Open in iCube".
- [ ] A link with an unknown path or a bad id opens Safari or does nothing; it never crashes the app.

## 6. Fixes from the release session

- [ ] Skylanders: open the portal and press Clear All with empty slots, in a game and from the library. No crash.
      Needs a rebuilt core slice for the core half of the fix; the app half works without it.
- [ ] WebDAV source with a folder of 1,000+ files: the library stays responsive while it lists.
- [ ] Settings > Reset All while a game runs, and from the library: per-game settings survive, and the game's
      `GameSettings/<id>.ini` on other devices is not emptied by sync.
- [ ] `Logger.ini` no longer syncs between devices.
- [ ] Resume Where I Left Off: play, press Home, end the app from the switcher, reopen the game. It resumes from
      the moment you left, not from the last Quit.
- [ ] Same on Apple TV.
- [ ] Background the app within a second of booting a game that has a resume state: the resume state is not
      replaced by a fresh-boot state.
- [ ] Save & Quit in History mode: a new history entry appears and quick slot 1 is untouched.
- [ ] Save & Quit in Slots mode: the chosen slot is written, as before.

## 7. Mac Catalyst

`develop` as pushed compiles for the Mac with no patched packages (Debug, 2026-11-16). The App Store
configuration compiled on 2026-11-15.

Menu bar and windows (branch `feature/catalyst-desktop`). Checked on the Debug build on 2026-11-16: the
menu-bar icon appears; closing the window leaves the same process running with no window; opening the app
again brings a window back in that process; File has Import Game… and no New Window; iCube > Settings…
opens Settings. Nothing below that needs a click on the menu-bar icon, a game, a second device or the Dock
was checked.

Use `make run-mac` for a local build. It is sandboxed and signed ad hoc, so its library is in
`~/Library/Containers/com.joemattiello.iCube-debug`, and it has no iCloud, app group or shared keychain.

- [ ] A game-controller icon appears in the menu bar while iCube runs. Its menu has Open iCube, a line saying
      whether the library is shared, Share Library on Local Network, Keep Running When the Window Is Closed,
      and Quit iCube.
- [ ] Close the window with the red button and with Command-W: iCube stays in the menu bar and the Dock.
      Open iCube, or a click on the Dock icon, brings the window back with the library intact.
- [ ] With sharing on and the window closed, browse this Mac's library from an iPhone or Apple TV and download
      a game. Leave the Mac alone for an hour and try again (App Nap is held off while sharing is on).
- [ ] Untick Keep Running When the Window Is Closed, then close the window: iCube quits, as it used to.
- [ ] Close the window while a game is running: iCube quits (a game cannot run without its window), and the
      resume state is there on the next launch.
- [ ] Command-N does nothing and File has no New Window: there is only ever one library window.
- [ ] File > Import Game… (Command-O) and iCube > Settings… (Command-,) open those screens, also when the
      window was closed. Both are greyed out during a game.
- [ ] Drag game files from Finder onto the library window: they import (this was already in the code).
- [ ] Drop a game on the Dock icon, and use Open With > iCube in Finder: the game imports. Several files at
      once import as one batch.
- [ ] iPhone and iPad: "Open in iCube" from Files and AirDrop of a game now import it too. Before this they
      did nothing.
- [ ] Quit from the menu bar, from the Dock and with Command-Q: all quit at once.

Everything else:

- [ ] Import a game and boot it. Video, sound, keyboard, a controller.
- [ ] Add an Emulation Server by PIN (the QR scanner is compiled out on the Mac).
- [ ] RomM and WebDAV sources.
- [ ] Save state, quit, resume.
- [ ] A signed build: iCloud, the shared keychain group and the app group all work.
- [ ] `make testflight-mac` archive and upload. App Store Connect has a macOS 1.0.0 version to receive it.
- [ ] TestFlight workflow, run by hand with platform `mac`: builds the Catalyst core, archives and uploads.
      Never run; `all` and the nightly are still iOS and tvOS only.
- [ ] Rebuild an iOS and a tvOS core slice with the changed `BuildiOSXCFramework.py`; the framework layout code
      was refactored for the Mac and the other platforms were not rebuilt afterwards.

## 8. Remote libraries in the library filter bar (already on develop)

- [x] Simulator, 2026-11-16, against the live Emulation Server on the Studio: the server appears as a filter
      pill and a Nearby Libraries card with no pairing step, and picking it shows its 22 games with cover art.
- [ ] iPhone and iPad, on a device: nearby devices, discovered Emulation Servers, saved Emulation Servers and
      saved RomM servers appear as sources, and picking one shows its games in the grid.
- [ ] Apple TV: servers are reachable from the library menu only. Confirm that path works end to end.

## Owner steps (not tests)

- Enable **Associated Domains** on the App ID `com.joemattiello.iCube`, and host
  `docs/app-store/apple-app-site-association` at `https://icube-emu.com/.well-known/apple-app-site-association`
  (details in `docs/app-store/apple-app-site-association.md` on the integration branch).
- Done 2026-11-16: App Store Connect has a macOS 1.0.0 version on the iCube record (Prepare for Submission).
  Its screenshots, description and review details are still empty.
- Emulation Server repo: iCube's current pin (`817cc049`) predates the QR scanner view, so the Mac builds
  today. The next pin bump brings that view in, and it does not compile for the Mac until its five
  `#if os(iOS)` lines in `DevicePairingView.swift` become `#if os(iOS) && !targetEnvironment(macCatalyst)`.
  Commit `8387f9b` on the unmerged branch `claude/catalyst-scanner-gate` does that for the pairing branch; it
  does not apply cleanly to `main`.
- Decide whether the wider iCloud sync filter (controller profiles, device-bound keys) goes in before 1.0.

## Simulator results for the merged branch

Run on `develop` at `e1f9247856`, 2026-11-16:

- Design-token check: passes.
- Full iOS simulator test suite: 2,835 tests, 2,828 passed, 7 skipped, 0 failed.
- tvOS simulator build: succeeds.
- The merged build installs and launches in the iOS simulator (Welcome screen), with the Live Activity
  extension embedded.

Live Emulation Server in the simulator, same build, 2026-11-16:

- The server is offered as a library source and lists its 22 games (section 8).
- Wii Play (93 MB) downloaded with a progress banner and landed in `Documents/Software/EmulationServer/`.
- 4x4 Evo 2 (1.08 GB) kept downloading with the app in the background, 36 MB to 882 MB over about two and a
  half minutes, and finished and unpacked after returning to the app. It did not restart.
- Not covered there: a download after the app was ended rather than backgrounded, the server that needs
  pairing, RomM and WebDAV. Section 1 still needs a device.
- Booting the downloaded game in the simulator stopped at repeated Metal "Failed to compile pipeline …
  reading from a rendertarget is not supported" alerts. Not checked on a device; the simulator's Metal is the
  likely cause.
