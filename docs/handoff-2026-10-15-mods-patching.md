# Handoff 2026-10-15: mods and disc patching

Branch `feature/mods-patching` (worktree `~/Workspace/icube-mods`), 38 commits on top of
develop `5de3f14a4c`. **Not pushed, not merged.** Design: `docs/superpowers/specs/2026-10-14-mods-and-patching-design.md`.

## What landed

- **PVPatchEngine** (`Source/iOS/PVPatchEngine`): a new SwiftPM package with no dependencies.
  - It streams IPS/IPS32/BPS/UPS/PPF and xdelta3/VCDIFF into an output file, so memory stays bounded at ~30 MB on discs larger than 4 GiB.
  - Malicious patches are refused with a typed error rather than crashing.
  - It is vendored from xdelta3 3.1.1 (Apache-2.0 branch `release3_1_apl`). DJW and FGK secondary compression work; LZMA does not and is refused with a message.
- **Riivolution soft patching**:
  - "Play with Mods…" boots a GameMod `.json` descriptor, so nothing is copied.
  - "Add to Library" saves the descriptor under `Software/Mods/` and gives it its own tile.
  - Packs install from imported archives into `Load/Riivolution`.
- **Disc patching**:
  - "Apply Patch…" accepts RVZ/GCZ/WIA/WBFS/CISO and unpacks them to plain first.
  - Three modes:
    - **This run** plays a cached copy.
    - **Save Copy** writes an RVZ or ISO under `Software/Patched/`.
    - **Replace Original** needs confirmation and is offered only for patches that verify the source or target.
  - tvOS lists patches from `<User>/Patches/` and from web-server uploads.
- **GameBanana browser**:
  - Live API, covering 52 games and 181 game IDs.
  - Downloads are checked against their MD5, then classified into Riivolution, disc patch, textures or Gecko, and installed.
  - Disc images and executables are refused.
- **Cross-app UX rules** (relayed from you via the iFly session):
  - A "Patches & Mods" context-menu section on the base game.
  - A count badge on the base game's tile.
  - "Patched"/"Mod" captions on modded tiles.
  - Settings › Interface › Library UI › "Show Patched Versions as Separate Library Items" (default on).
- **Modded boots never touch the vanilla `{GameID}.auto`.** That covers the boot, quit, pause-menu filmstrip, Continuity and Spotlight paths. Manual save slots stay shared with the base game, and the sheets say so.

## Gates (last run on c9f1d90122)

- iCube (NJB) Debug: iOS and tvOS builds both pass.
- iCube (AppStore) Release: iOS build passes.
- `make test`: 1887 tests, 0 failures, 6 skipped.
- PVPatchEngine `swift test`: 97 tests, 0 failures.
- A review pass found 6 defects, all fixed with tests:
  - an archive delete that lost games
  - an unverified Replace Original
  - an auto-state bypass
  - 3 overflow traps on malicious patches

## Owed on device (nothing was run on hardware)

1. NSMBW with the Newer pack: Play with Mods, Add to Library, then boot from the new tile.
2. Mario Kart Wii with a Riivolution track pack.
3. Brawl with Project+ (needs its SD layout; check that the savegame redirect works).
4. A GameCube RVZ with an xdelta hack (for example a Melee mod): try all three modes. For Replace Original, confirm the result is still an RVZ.
5. A BPS patch with the wrong revision: expect a mismatch, then try "Apply anyway" with Save Copy.
6. From the browser, download and install one of each: a texture pack, a Riivolution pack and a patch.
7. tvOS:
   - focus and tilt with the tile badge
   - the "Patches & Mods" section in the context menu
   - focus in the Riivolution sheet
   - a web-server upload of a patch
8. After a modded play, the vanilla game's Continue tile still resumes its own state.

## Decisions for you

- **Merge `feature/mods-patching` into develop and push?** The commits are unsigned (`commit.gpgsign=false`). Three older subjects run past 72 characters.
- **App Store:** the browser sits behind `ModBrowser.isEnabled`, which is on in every build. Ask GameBanana staff before an App Store release that includes it.
- **xdelta LZMA secondary compression:** enable it by using the headers in `Externals/liblzma`, if real GameCube patches turn out to need it.
- **tvOS:** user data lives in Caches, so packs, mods and patched copies can be purged. There is a one-line note for this, and it is not solved.

## Known gaps

- Share-sheet "Open in iCube" for patch files isn't done. It needs document types and a UTI.
- Removing a Riivolution pack deletes only its XML. Data files may be shared, so they are kept.
- Manage doesn't list cached "this run" copies; only the newest is kept anyway.
- Downloads run in a foreground session, and resume data is kept in memory only.
- `.rar` archives aren't supported.
- The shared catalog `provenance-emu.com/patches/catalog.json` is being designed in the iFly session. iCube can read it once it exists.

## Worktrees

All of these are clean:
- `~/Workspace/icube-mods` (integration)
- `~/Workspace/icube-mods-{riiv,engine,browser,disc}`: each one's branch is fully merged into `feature/mods-patching`, so these four can be removed.
