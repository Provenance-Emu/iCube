# Verification queue 2026-09-28 — Sentry hang fixes (batch for one device session)

Everything below landed from the Sentry hang sweep (sessions 2026-09-26 → 09-28). All of it is
unit-tested and/or compile-gated (iOS + tvOS Release) — **none of it has run on a device**. Run
these together on one DEV build at or after `77c735d4a3`, which contains every fix below. The Config fix is core C++: a local
app build rebuilds the core slice, so run `git checkout -- build/xcframework` afterwards.

## Landed

| Fix | Commit | Sentry |
|---|---|---|
| Library reads no longer `dispatch_sync` behind a rescan (published snapshot) | `1778eeb927` | ICUBE-F, ICUBE-9E (resolved) |
| Spotlight indexing built off the main thread, bursts coalesced | `f6d724bd8c` | ICUBE-5A (resolved) |
| `TVGameItem`s built once per GameFile, reused across reads; rebuilt on GC/Wii language change | `b438c5138f` | follow-up to F |
| Game delete (single + batch) removes files off main (`LocalGameDeleter`) | `fffdc2dcfe` | ICUBE-2F (resolved) |
| tvOS Library "Clean" background: adaptive black/white instead of the unavailable `.systemBackground` | `44916d2976` | tvOS build break from `38efa43fc1` |
| `Config::Save/Load` no longer hold the layers lock across loaders (recursive shared-lock deadlock vs `RemoveLayer`) | `a5f5ff4c12` | 1 event of ICUBE-2D (still open) |
| Alpha CI uploads dSYMs to Sentry | `b49f087fee` | verified in alpha run 170 |
| Sentry not started when the app is a unit-test host | `ddaae83d50` | ICUBE-9P (resolved) |
| stdout/stderr non-blocking at launch (undrained JIT-debugger pipe) | `77c735d4a3` | ICUBE-AC + ICUBE-AV (open until device check) |
| Save/load refused unless the core is running (ASSERT `Core::IsCPUThread()` during boot) | `70c3a5d8d2` | ICUBE-9Y (open until device check) |

Also resolved as already fixed by earlier commits (no new code): ICUBE-37 (`60b8b951d8`, `757447ad21`) and
ICUBE-54 (`c0029c9284`), ICUBE-7R (`60b8b951d8`) — main thread waiting on the Dolphin host queue from controller / EmulationScreen / scene-resign code.

## Device tests owed

1. **Library launch/refresh (ICUBE-F)** — large library, ideally with a WebDAV source: cold launch straight into the Library, then pull-to-refresh and add/remove a source. No stall; list complete; new imports appear after the refresh completes.
2. **Spotlight** — after launch, search a game by title in iOS Spotlight: result shows maker • year • country and the cover; tapping it opens the game.
3. **Item reuse + language** — scroll the Library; favorites star toggles still update. Change Settings → GameCube language, pull-to-refresh: titles switch to the new language (they will NOT switch on a plain reload until a refresh/scan — expected).
4. **Delete (ICUBE-2F)** — delete one multi-GB game from its context menu, then batch-delete several: UI stays responsive, snackbar text unchanged, list updates after the rescan. A remote (WebDAV) item still reports "cannot be deleted".
5. **tvOS Clean background** — Library background style "Clean" in both light and dark appearance: titles readable, background black in dark / white in light.
6. **Config deadlock (a5f5ff4c12)** — seen twice with an identical 3-thread signature (main in `Config::Get`, CPU-GPU thread in `Config::RemoveLayer`, motion handler in `mainTouchPadIRMode`): alpha 170 iPad iOS 18.7 and TestFlight 1790524073 iPhone15,5 iOS 27 (2026-09-28 23:39, breadcrumbs: settings toggle, then "emulation ended" 7 s later). The risky window is emulation STOP right after a settings change. Repeat ~10×: boot a Wii game with touch/motion IR active, change a setting from the pause menu, quit the game immediately. No hang on stop; settings persist after relaunch (INI + SYSCONF still written, e.g. Wii language survives a relaunch).
7. **Stdio under a JIT debugger (ICUBE-AC, ICUBE-AV)** — sideload build, JIT enabled through StikDebug/SideStore (the debugger attaches, enables JIT, detaches). Play 20+ min with controller connects/disconnects and a few library rescans (lots of NSLog/printf). No freeze; before the fix main blocked in `writev` from NSLog once the undrained pipe filled. Also launch once from Xcode and confirm the console still shows logs.
8. **Save states during boot (ICUBE-9Y)** — start a game and, while it is still booting, use the top-bar Load State → Slot N (and Save State) menu repeatedly; also quit during boot with "Resume where left off" on. No Dolphin "An error occurred … Core::IsCPUThread()" dialog, no crash; the request is ignored (console: `[SaveState] Ignoring …`). Then, once running and while paused from the pause menu, save and load a slot: both still work.

## Passive checks (no dedicated session needed)

- **Sentry off in test hosts (ICUBE-9P)** — after the next on-device `iCubeTests` run, Sentry gets no new "Fatal App Hang" events from that device (environment `development`, XCTest frames).
- **Alpha dSYMs** — the next alpha crash or hang in Sentry shows iCube/PVlibDolphin function names instead of `?` (upload verified in run 170; symbolication itself not yet seen on a real event).

## Still open (not fixable from Sentry samples)

- **ICUBE-2D** (fatal) and **ICUBE-2H** (non-fatal) are catch-alls: most samples are SwiftUI view-graph / UIKit layout work with no app frames, on every build and OS. So are ICUBE-9T, A7, 9X, 98, 91, 8J. Next step is Instruments (Hangs + SwiftUI) on an iOS 26/27 device: launch into a large Library, context menus, return from background.
- The core is built with `-fomit-frame-pointer` (`BuildiOSXCFramework.py`), so Sentry cannot walk into PVlibDolphin frames — the config deadlock's saver frames were invisible for this reason.
- `Config::Shutdown/RemoveLayer/AddLayer` still destroy layers under the write lock (`~Layer` saves); only `Shutdown` with a dirty Base layer could self-deadlock today.
