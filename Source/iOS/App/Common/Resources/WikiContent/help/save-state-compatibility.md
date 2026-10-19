# Save State Compatibility

## Save states vs. game saves — these are different things

* **Game saves** (memory card files, or a Wii game's internal save data) are
  written by the *game itself* and behave exactly like they would on real
  hardware. These are safe across iCube updates.
* **Save states** are a snapshot of the *entire emulated machine* — CPU
  registers, RAM, GPU state, and more — frozen at an exact instant. They let
  you resume exactly where you left off, mid-frame if needed, but they are
  tied to the exact internals of the core version that created them.

If you only remember one thing from this page: **use save states for
short-term convenience (pausing mid-session, "just let me try this jump
again"), and rely on the game's own save/memory-card system for anything you
want to keep long-term.**

## Why a save state can become "Incompatible"

Every save state is tagged with a version marker that has to match the
Dolphin core build that created it. When iCube's core is updated — which
happens often, since the emulator itself is still actively improved — old
save states from a previous core version are checked against the new
version marker. If they don't match, iCube marks the state **Incompatible**
(you'll see a red badge on it in the save state browser) rather than risk
loading it into a mismatched core, which could crash or corrupt emulation.

This isn't a bug or data loss on iCube's part — it's the same trade-off any
emulator with active development makes. The alternative (silently trying to
load a mismatched state) is far worse: unpredictable crashes or silent
corruption instead of a clear "this one won't load" signal.

## What to do about it

* If a save state shows **Incompatible**, it can't be safely loaded. Use the
  game's own in-game save system to reload the closest earlier progress
  point instead.
* After any iCube update, create a **fresh** save state once you're back in
  the game — don't rely on carrying old ones forward indefinitely.
* For anything you'd be upset to lose, prefer the game's built-in save
  feature over a save state. Save states are a convenience layer on top of
  that, not a replacement for it.
