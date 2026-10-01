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
9. **WebDAV URL shapes (ICUBE-87, core C++)** — add WebDAV sources whose URL has credentials (`http://user:pass@host:port/…`) and, if you can, an IPv6 host (`http://[fe80::…]:port/…`); let the library list their games, then force-quit and relaunch twice. Before the fix every launch crashed ("stoi: no conversion") while such a source existed. Also check a plain `http://host:port/` source still finds its already-downloaded cache (cache folder IDs are unchanged for normal URLs).

## Passive checks (no dedicated session needed)

- **Sentry off in test hosts (ICUBE-9P)** — after the next on-device `iCubeTests` run, Sentry gets no new "Fatal App Hang" events from that device (environment `development`, XCTest frames).
- **ICUBE-G stack** — the next "mutex lock failed: Invalid argument" event from a build with the C++ exception V2 handler should carry the throwing thread's frames (all sampled events so far had none). ICUBE-G fires during `exit()` static destruction at app termination; the Dolphin `Analytics` thread (alive in 7/10 events) and a `WorkQueueThread` (4/10) are the suspects. Fix the thread it names.
- **Alpha dSYMs** — the next alpha crash or hang in Sentry shows iCube/PVlibDolphin function names instead of `?` (upload verified in run 170; symbolication itself not yet seen on a real event).

## Still open (not fixable from Sentry samples)

- **ICUBE-2D** (fatal) and **ICUBE-2H** (non-fatal) are catch-alls: most samples are SwiftUI view-graph / UIKit layout work with no app frames, on every build and OS. So are ICUBE-9T, A7, 9X, 98, 91, 8J. Next step is Instruments (Hangs + SwiftUI) on an iOS 26/27 device: launch into a large Library, context menus, return from background.
- **ICUBE-5R (TXM JIT, for the JIT owners)** — `EXC_BAD_ACCESS` code 50 (`KERN_CODESIGN_ERROR`) executing an unblessed JIT page, after an authorized TXM JIT boot (breadcrumb `jit: TXM boot decided authorized=true`, then `emulation started`). Sideload alpha 169/170 on iOS 26.5+/27, `jit: txm`; the PC is in JIT code, so no symbols. Suspects: JIT code emitted outside the blessed range, a page whose blessing was lost (debugger detach, region reuse), or a missed bless in the pipelined path.
- **ICUBE-AA (legacy JIT, for the JIT owners; likely the symbolicated form of ICUBE-60)** — `KERN_PROTECTION_FAILURE` writing JIT code in `Arm64Gen::ARM64XEmitter::EncodeLoadStorePair` during boot. Alpha 170 only (first alpha with core dSYMs; no JIT/core change between 169 and 170), `jit: legacy` on iOS 17/18 with a debugger, CPU core 4; two iPads crash on every boot. The legacy region is mapped RX (`MemoryUtil_iOS_Legacy.cpp`) and every JIT write goes through `ScopedJITPageWriteAndNoExecute(region)` → `JITPageWriteEnableExecuteDisable_Legacy` → `JITMemoryTracker` flipping the page RW; the no-arg toggle is counter-only on iOS but no JIT code calls it. **ICUBE-A9** (alpha 170, `jit: legacy`) faults the same way in `Arm64Gen::ARM64CodeBlock::PoisonMemory`, which writes the whole unused code buffer — so the region is not writable at all when emission runs, which points at the toggle/tracker (e.g. a `FindRegion` miss for the guard's pointer, far code / a sub-region) rather than one unguarded emitter write. Less likely: nesting leaving the region RX. Next step: legacy-JIT device session (iOS 17/18 + debugger JIT, core 4) with logging/breakpoint in `JITRegionWriteEnableExecuteDisable` / `FindRegion`.
- **ICUBE-86 (iOS 26.0 only, small fix)** — Swift runtime abort "Failed to look up symbolic reference" in `TVLibraryView.aboutDolphinToolbarBackground`: `.glassEffect()` under `#available(iOS 26.0, …)` compiles against a type iOS 26.0's SwiftUI lacks (SDK-vs-OS mismatch). Raise that guard to iOS 26.1 and audit the other `glassEffect` uses in `LibraryPlatformCategory.swift`. 4 events, 2 users, all iOS 26.0.
- **ICUBE-60** — `KERN_PROTECTION_FAILURE` write inside the core on pre-dSYM sideload builds (alpha 13/109/110/138, mostly iOS 18); probably the same bug as ICUBE-AA above. Resolve together once AA is fixed.
- The core is built with `-fomit-frame-pointer` (`BuildiOSXCFramework.py`), so Sentry cannot walk into PVlibDolphin frames — the config deadlock's saver frames were invisible for this reason.
- `Config::Shutdown/RemoveLayer/AddLayer` still destroy layers under the write lock (`~Layer` saves); only `Shutdown` with a dirty Base layer could self-deadlock today.
