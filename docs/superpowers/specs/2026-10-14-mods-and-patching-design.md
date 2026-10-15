# Mods and disc patching for iCube — design

Date: 2026-10-14. Branch: `feature/mods-patching` (worktree `~/Workspace/icube-mods`).
Owner request: reuse Provenance's ROM patching for iCube, support every patch kind we can,
and add an online mod search/market if one is feasible. Owner went away and asked for all
three pieces to be built; this spec records the decisions taken on their behalf.

## Findings that shaped the design

- Provenance `PVPatching` (pure Swift, IPS/IPS32/BPS/UPS/PPF) builds the whole patched
  output as one in-memory `Data`. A 1.4 GB GameCube disc would be jetsam-killed on a phone,
  BPS caps targets at 4 GiB (Wii discs go to 8.5 GB), and xdelta/VCDIFF — the format most
  GameCube hacks ship in — throws `unsupportedFormat`. It also has no notion of compressed
  disc images (RVZ/WIA/GCZ/WBFS/CISO). Its modes are "play patched" (a cached hidden copy)
  and "export copy"; it never writes the original.
- iCube's core already contains Dolphin's complete Riivolution implementation
  (`DiscIO/RiivolutionParser`, `RiivolutionPatcher`) and the GameMod descriptor
  (`DiscIO/GameModDescriptor`): `BootParameters::GenerateFromFile` boots a `.json`
  descriptor (base disc + Riivolution patch choices) as a true soft patch — nothing is
  copied (`Core/Boot/Boot.cpp:287-300`). Paths in the descriptor resolve relative to the
  `.json`. The library scan already lists `.json` descriptors as their own games
  (`UICommon/GameFileCache.cpp:33`, `UICommon/GameFile.cpp:156`). The iOS app wires none of it.
- Online sources: GameBanana (`https://gamebanana.com/apiv11`) is the only catalogue with a
  public JSON API and real GC/Wii coverage (Brawl ~2,850 mods, MKW ~2,150, Melee ~490).
  romhacking.net is read-only and cartridge-era; romhack.ing disallows crawling;
  Romhack Plaza has no GC/Wii section. Gecko codes from codes.rc24.xyz are already wired.
- iCube is its own repo (Provenance-Emu/iCube) with its own CI, so it cannot reference
  Provenance's `PVPatching` by relative path. Vendoring a package under `Source/iOS/PV*`
  is the established pattern (PVWebServer, PVHelp, ...).

## Scope

Three sub-projects, built in order A + E, then B + C:

| Id | What | Where |
|----|------|-------|
| A | Riivolution soft patching (play once / add to library), pack install | iCube app |
| E | `PVPatchEngine`: streaming IPS/IPS32/BPS/UPS/PPF + xdelta3/VCDIFF | `Source/iOS/PVPatchEngine` (SwiftPM) |
| B | Disc patching flow: compressed-image handling, play / save copy / apply to original | iCube app, uses E |
| C | GameBanana mod browser: search, detail, download, classify and install | iCube app, routes to A/B/textures |

Non-goals: hosting or mirroring any file; downloading disc images; Graphics Mods and
resource packs; NKit images (cannot be byte-patched — refused with a message); baking
Riivolution into an ISO; Provenance backport of E (follow-up).

## Mode semantics (the owner's "for a run / to a copy / to the original")

| Mode | Riivolution (A) | Byte patch (B) |
|------|-----------------|----------------|
| This run | Temp descriptor in `<User>/Cache/ModRuns/`, booted directly, swept on next launch | Cached patched copy in `<User>/Cache/PatchedDiscs/<key>/`, reused on the next play; only the most recent copy is kept by default |
| Copy | Descriptor saved to `<Software>/Mods/<name>.json` → own library tile, zero disc bytes copied | New file in `<Software>/Patched/<name>.<ext>`, ISO or RVZ (user choice, RVZ default) → own tile |
| Original | Not applicable: Riivolution never writes the disc (UI says so) | Destructive, behind a confirmation: patch to a temp file, verify, then atomically replace the original (same container format as the original) |

## A — Riivolution

**Storage.** Packs live in Dolphin's standard SD layout under `File::GetUserPath(D_RIIVOLUTION_IDX)`
(`<User>/Load/Riivolution/`): `riivolution/*.xml` plus the files the XMLs reference.
Selections persist in `riivolution/config/<ID4>.xml`, exactly as desktop Dolphin does.

**Bridge** (`Common/Mods/RiivolutionBridge.{h,mm}`, ObjC++): 
- `packsForGame(path)` → parse every XML under `riivolution/`, keep those where
  `Disc::IsValidForGame(gameID, revision, discNumber)`, apply the saved config defaults,
  return Swift value types (pack → sections → options → choices, selected index, 0 = off).
- `saveSelections(...)` → write `config/<ID4>.xml` (port of `RiivolutionBootWidget::SaveConfigXMLs`).
- `writeDescriptor(baseFile:, selections:, displayName:, to:)` → `DiscIO::WriteGameModDescriptorFile`
  with paths relative to the descriptor's directory, so it survives the app container moving.

**Pack install.** The archive import path (`ZipImportHelper` and the Files/share/web-server
import entry points) checks the extracted tree: if it contains `riivolution/*.xml` (at the
root or one folder down, which is how most packs are zipped), the tree is merged into
`Load/Riivolution/` instead of the game library. Same-path files are overwritten (pack
updates), every path goes through the existing zip-slip validation, and the snackbar says
"Installed Riivolution pack <name> (n options)". Packs dropped straight into the folder via
the Files app are picked up too, because the bridge reads the folder on demand.

**UI.** Game context menu (iOS `GameGridItem` and the tvOS library) gets "Play with Mods…"
for disc games whenever at least one installed pack matches. It opens `RiivolutionLaunchView`:
packs → sections → options; each option is a list of choices (Disabled + choices) using
rows/`NavigationLink`, not `Menu`/`Picker` (neither works on tvOS). Buttons: **Play**
(this run) and **Add to Library** (prompts for a name, default "<Game> — <Pack>"). An empty
state explains how to install packs and offers the online browser (C) for that game.

**Caveats surfaced in UI.** Dolphin disables loading-time emulation for Riivolution boots
(`Core/BootManager.cpp:143`). Packs without a savegame redirect share the base game's save.

## E — PVPatchEngine

New SwiftPM package `Source/iOS/PVPatchEngine` (iOS/tvOS 17, macOS 14 so `swift test`
runs on the Mac), no dependencies. Seeded from Provenance `PVPatching` patchers (keep the
copyright headers and say where they came from), rewritten to stream:

- API: `PatchEngine.apply(patch: URL, source: URL, output: URL, progress:) async throws -> PatchResult`
  plus `PatchEngine.detectFormat(_:)` and `PatchEngine.inspect(patch:)` (format, declared
  source/target size and CRCs when the format carries them).
- Memory: peak resident memory stays under ~64 MB regardless of disc size; all offsets 64-bit;
  must handle 8.5 GB outputs. IPS/IPS32/PPF: copy source → output in chunks, then apply records
  by seeking. UPS: streamed XOR. BPS: buffered random reads of source and output for
  SourceCopy/TargetCopy, streamed CRC32 of source and target.
- xdelta3/VCDIFF: vendor the xdelta3 3.1.0 decoder (Apache-2.0) as a C target `CXdelta3`
  using the `xd3_stream` API with a file-backed source (`getblk` reads blocks on demand).
  Built-in secondary compressors (DJW/FGK) enabled; LZMA secondary only if the SDK's liblzma
  links on iOS and tvOS, otherwise a clear `unsupportedSecondaryCompression` error.
- Errors are typed (`sourceMismatch(expected:actual:)`, `truncatedPatch`, `unsupportedFormat`,
  `outputTooLarge`, `cancelled`). Source checks: BPS/UPS CRC32, PPF validation block,
  xdelta's own adler32 window checks. An explicit `ignoreSourceChecksum` option exists and is
  actually honoured (Provenance's "Apply anyway" toggle is a no-op for BPS/UPS — don't copy that bug).
- Cancellation via `Task` cancellation; output written to `<output>.partial` then renamed.

## B — Disc patching flow

**Entry points.** Game context menu "Apply Patch…" (file picker for
`.xdelta .vcdiff .bps .ips .ups .ppf`), and importing a patch file through the normal import
path asks "Which game is this patch for?" (list of disc games; the best guess first when the
patch declares a source size/CRC that matches). C hands downloaded patches to the same flow
via `DiscPatchFlow.present(patchURL:, suggestedGame:)`.

**Pipeline** (`Common/Mods/DiscPatch*`):
1. Refuse NKit, WAD, DOL/ELF with a message. Free-space check: plain size of the source plus
   the output (plus the original's size for RVZ re-compression); fail early with numbers.
2. If the source is not a plain image (RVZ/WIA/GCZ/WBFS/CISO), convert it to a temporary
   plain ISO through DiscIO (`DiscIO::ConvertToPlain`, the same call DolphinQt's convert dialog uses),
   in `<User>/Cache/PatchWork/`, with progress.
3. `PatchEngine.apply` → patched plain ISO.
4. Output per mode: keep as cached copy (this run) / convert to RVZ (`ConvertToWIAOrRVZ`,
   zstd level 5, 128 KiB blocks — Dolphin's defaults) or keep ISO (copy) / replace the
   original in its own container format (original), then delete temp files.
5. Rescan the library; select the new tile.
All of this runs off the main thread with a progress sheet and cancel; work files are swept
at launch. A background task keeps it alive briefly when the app is backgrounded.

**Save-state safety (A and B).** Dolphin keys save-state slots by game ID, and patched games
keep the base game's ID. A modded run must never auto-resume from, or overwrite, the vanilla
game's auto-resume state. Find how iCube's auto-resume names its state and key it on the
booted file path (descriptor or patched copy), or skip auto-resume for modded boots if that is
not cleanly possible. Manual slots stay shared; the launch sheet says so in one line.

## C — GameBanana mod browser

- `GameBananaClient` (async `URLSession`): `NameMatch`, `Mod/Index` filtered by
  `_aFilters[Generic_Game]`, `Mod/Categories`, `Mod/<id>/ProfilePage`, plus text search if a
  search endpoint verifies live. Decoders tolerate missing fields. Serial requests, short
  in-memory response cache, polite `User-Agent: iCube/<version>`.
- `ModGameTable.json` (bundled): GameBanana game id ↔ GameTDB IDs (all regions) for the
  GC/Wii titles that have mods; generated by a small script under `Tools/` that queries
  `NameMatch`, then committed. Region/revision mismatches are warned, not blocked.
- UI: "Find Mods Online" from a game's context menu (filtered to that game) and a top-level
  "Mod Browser" listing supported games the user owns first. Mod detail: preview images,
  description as plain text, submitter credits, licence, file list with size, AV result and
  analysis warnings, link to the GameBanana page. Every screen credits GameBanana.
- Downloads: background `URLSession` into `<User>/Cache/ModDownloads/`, progress, cancel,
  resume data, storage warning above 500 MB, MD5 checked against `_sMd5Checksum`.
- `ModPackageClassifier` (pure Swift, tested): after extraction (existing `ZipImportHelper`
  extractors incl. 7z/rar if supported) → `.riivolution` (→ A installer), `.discPatch(urls)`
  (→ B), `.textures(gameID, root)` (→ `Load/Textures/<GameID>/` and enable
  `GFX_HIRES_TEXTURES`, asking first), `.gecko` (append to the game's user Gecko codes
  only if the format is a Dolphin `.ini`/`.txt` codes file), else `.unsupported(reason)`.
  Executables are never run and are not installed; disc images inside archives are refused.
- Feature flag `ModBrowser.isEnabled` (single constant, default on in all builds) so the
  App Store build can drop it if review objects.
- tvOS: browse and download work; focus-friendly lists; storage note that tvOS may purge
  `Caches` (the iCube user root there).

## Testing and gates

- `cd Source/iOS/PVPatchEngine && swift test`: per-format fixtures (small synthetic files;
  xdelta fixtures generated once with the `xdelta3` CLI and committed), round-trips, corrupt
  and truncated patches, source mismatch, cancellation, and a sparse-file test with a >4 GiB
  output that asserts bounded memory.
- iCubeTests (`cd Source/iOS/App && make test SIM="iPhone 17 Pro"`): descriptor writing with
  relative paths, pack detection/merge, classifier, GameBanana decoding against recorded JSON
  fixtures, game-table lookup.
- Compile gates, both platforms:
  `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS|tvOS" CODE_SIGNING_ALLOWED=NO`
  then `git checkout -- build/xcframework`.
- Owed on device (owner): boot NSMBW with Newer, MKW with a track pack, Brawl with Project+;
  apply an xdelta to an RVZ GameCube disc in all three modes; download and install one mod of
  each class from the browser.

## Follow-ups (not in this branch)

- Backport `PVPatchEngine` streaming + xdelta into Provenance `PVPatching` so its Dolphin core
  and every other core get disc-sized and xdelta patching.
- GameBanana/licence check with GameBanana staff before an App Store release that includes C.
