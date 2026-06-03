# ADR: iCube save-management overhaul

_Status: Accepted — 2026-06-03. Branch `feature/save-management` (worktree forked from `feature/rebaseline-2509` @ 010339358e). Implements the brief at `personal-os/.../2026-06-03-save-management-overhaul-brief.md`._

## Context

iCube (jitless iOS/tvOS Dolphin) currently exposes only Dolphin's numbered save slots: filename `{StateSavesDir}{GameID}.s{NN}` written via `State::Save(system, slot)` → `SaveAs(MakeStateFilename(slot))`. No titles, timestamps-as-labels, screenshots, or custom metadata. A read-only Swift browser scaffold already exists (`SaveStateInfo`, `SaveStatesViewModel`, `FilesystemSaveStateProvider`, `SaveState{Card,Filmstrip,Browser}View`) but populates no metadata and writes no thumbnails. Goals: rich per-save metadata + thumbnail, a modern manager UI, and "resume where I left off."

Hard constraints (from brief + codebase):
- `STATE_VERSION` is 176; old states are rejected, not range-loaded. **Do not bump the format.**
- **Do not touch the perf controllers** (`EmulationCoordinator.mm`, `AutoIRController.cpp`, `CoreTiming.cpp`) — a parallel session owns them. Note: `EmulationCoordinator.mm` *owns the `CAMetalLayer`*, so the emulation surface is off-limits for screenshot capture.
- Must build for **tvOS** (focus nav, no touch) as well as iOS.
- Tuist workspace is generated + gitignored → `tuist generate` after adding files.

## Decisions

### 1. Metadata storage → **sidecar JSON**, not embedded
A `{GameID}.s{NN}.json` (and `{GameID}.auto.json`) sidecar next to each state file. Fields: `schemaVersion`, `title`/`label` (user-editable), `createdAt`/`savedAt` (ISO-8601), `gameID`, `gameTitle`, `scmRevision` (from the state header), optional `playTimeSeconds`. Rationale: non-breaking, no `STATE_VERSION` bump, trivially read/written in Swift, and the state binary stays byte-identical to upstream. Embedding would force a format change and touch the rejection-on-mismatch loader.

### 2. Screenshot source → **decided but DEFERRED; degrades to nil**
Thumbnails are a `{GameID}.s{NN}.png` sidecar (a convention `FilesystemSaveStateProvider` *already reads*). But capture is the only piece that touches core/video code, has cross-thread GPU-readback concerns, and is boxed in by the off-limits `EmulationCoordinator` Metal layer. `SaveStateInfo.thumbnailURL` is already `Optional` and the VM/provider already handle its absence. Therefore: **all foundational phases ship with nil thumbnails; screenshot capture is an isolated final phase.** When implemented, prefer reusing Dolphin's existing screenshot-request path (`Core::SaveScreenShot` / `g_frame_dumper` / `Presenter` XFB readback in VideoCommon — backend-agnostic, avoids the Metal layer) over new bespoke readback; expect it to be **asynchronous** (writes on the next frame boundary), which is exactly why it is sequenced last.

### 3. Slot model → **keep numbered `.s{NN}` files; present them as labeled entries**
No migration of the underlying slot scheme (the bridge, `PauseMenuView`, `EmulationScreen`, `EmulationiOSViewController` are all coupled to int slots). The manager UI decorates existing slot files with sidecar metadata. New richer saves still land in slot files; the sidecar carries the human label. This keeps `State.cpp` untouched.

### 4. Auto-save → **separate filename namespace `{GameID}.auto`** via public `SaveAs`/`LoadAs`
`State::SaveAs(system, filename, wait)` and `LoadAs(system, filename)` are public and take arbitrary paths → the auto-save writes `{StateSavesDir}{GameID}.auto` with **zero core changes**. It never collides with slot enumeration (`State.cpp` only iterates `.s{NN}`). **Provider guard required:** `FilesystemSaveStateProvider.statesGroupedByGame()` currently treats every non-dir/non-`.png` file as a slot state, so it must explicitly recognize `.auto` and route it to the "Continue" entry instead of the slot list.

### 5. "Resume where I left off" toggle → **NSUserDefault, not a Config key**
This is pure frontend behavior (the Swift/ObjC launch path reads it; the core never does). A Dolphin `Config` key would be written through `DOLConfigBridge` but never `Config::Get`-read → `icube_config_lint` would *correctly* flag it as dangling. Store as `resume_where_left_off` in `NSUserDefaults` (sibling to `adaptive_clock_*`), surfaced on General > Basic. On **quit**: if enabled, `SaveAs({GameID}.auto, wait:YES)` **before** `Core::Stop` tears down the CPU thread. On **launch**: if enabled and `{GameID}.auto` exists, `LoadAs` it after boot.

### 6. Backward compat
Existing `.s{NN}` files with no sidecar show a synthesized "Slot N" entry (current behavior). `isCompatible` is computed from the state header's `scmRevision`/version vs the running build (today it is hardcoded `true`). No data migration; sidecars are created lazily on next save/rename.

## Consequences
- `State.cpp` / `State.h` are **not modified** (slot save, auto-save, and load all use existing public API).
- Net new: a save-metadata bridge/service (write sidecar at save time, read/rename), provider/VM/UI extensions, the resume toggle + launch/quit hooks, and (final, isolated) the screenshot path.
- Screenshot can be cut entirely without affecting the rest — thumbnails simply stay nil.

## Phase plan (lowest-risk first; build-verify + commit each)
1. ✅ This ADR.
2. Metadata sidecar + save-metadata bridge (nil thumbnails).
3. Save-manager UI: thumbnails(nil-ok)/labels/timestamps, rename + delete; tvOS focus-safe.
4. Resume toggle (NSUserDefault) + `.auto` save-on-quit/load-on-launch + "Continue" entry.
5. Backward compat: synthesized slot entries + real `isCompatible`.
6. (Isolated, last) Screenshot thumbnail capture; degrades to nil if cut.
