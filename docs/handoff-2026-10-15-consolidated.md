# Handoff 2026-10-15 (late): consolidated iCube + Provenance state

Supersedes the "Open" section of `docs/handoff-2026-10-15-tvos-redesign-session.md`. That doc's
device-test list, agreements and housekeeping still apply. Everything below is pushed unless marked
otherwise.

## Where things stand

| Repo | develop | Notes |
|---|---|---|
| iCube | `de39d288c6` (docs) on `6b12f235b9` | mods/patching, CI lint fixes, strings, aps-environment all in |
| Provenance | `5f0707b9de` | #3746 (PVPatchEngine streaming) `b75cf3b8fa`, #3748 (Replace Original, merged by owner) `41df2da7fb`, iCube gitlink `1b3ae64f6a`, sharing slash fix `3eb76e258d`, App Store docs `465e567d14` |

## 1. iCube TestFlight (in progress)

- **Run** [38841260362](https://github.com/Provenance-Emu/iCube/actions/runs/38841260362) on `6b12f235b9` was queued/in progress at handoff. It is the first run on the self-hosted Mac Studio (Xcode 27): `MACOS_RUNNER_LABELS` = `["self-hosted","studio"]` since 2026-10-15 23:18 UTC (iCube #48, `22bd603b5f`).
- **Root causes of today's failures** (runs 38754231843, 38790776983). Read them from the raw log artifact (`gh run download <id>`, `testflight-log-<platform>/testflight.log`); the console log truncates.
  - **tvOS:** the archive was OK, but export validation failed: "missing the 'aps-environment' entitlement, which is required by tvOS apps that contain … icloud-services". Fixed in `6b12f235b9` (`aps-environment` = `development` in `iCube AppStore.entitlements`).
  - **iOS:** "Authentication failed … bearer token", then "No profiles for com.joemattiello.iCube". The same key provisioned tvOS 75 minutes later, so this looks transient. Confirm with the run above.
- **Ruled out:**
  - The ASC key 3HG74R58TM is not expired (HTTP 200 locally; secrets unchanged since 2026-09-05).
  - The App ID 8K454AA4AG already has all 3 iCloud containers and both App Groups (checked with `asc web`).
- **`asc web` (Developer Portal) needs** `--apple-id apple@joemattiello.com --developer-team S32Z3HMYVQ`. The mail@ account has no portal team. The session is cached on this Mac.
- **If the run fails on the Studio runner:** first decide whether it's the runner (Xcode 27, keychain, signing identities) or the code. Unsetting `MACOS_RUNNER_LABELS` sends jobs back to GitHub-hosted macos-26.
- **Re-run:** `gh workflow run testflight.yml -R Provenance-Emu/iCube --ref develop -f platform=all -f force=true`

## 2. Provenance TestFlight / develop health (not started)

- `Build and Upload Provenance` **fails on develop** at `5f0707b9de`. Not investigated.
- #3748 was merged with two real red checks. Both are unverified and possibly caused by #3748's PVUI hook `PatchReplacement.recoverInterruptedSwapsInLibrary()` in `AppState.initializeDatabase()`, which was never compiled locally (PVUI can't build in a worktree).
  - Build (Provenance-Dev-Coreless Simulator): https://github.com/Provenance-Emu/Provenance/actions/runs/38814981177/job/116697265801
  - PVUI Tests (tvOS Simulator): https://github.com/Provenance-Emu/Provenance/actions/runs/38814981177/job/116697308713
- **Known flaky or pre-existing tests:**
  - `PVWebFileEventObserverTests.testDeleteUnknownPathIsNoop` (1 s timeout).
  - `LibraryMoveJournalTests.testUnknownLocationRawValueIsDiscarded` was fixed in `00bc1eb5dd` (stale `pickedFolder` value).
- **Next steps:**
  1. Fix develop until it's green.
  2. Trigger Provenance TestFlight (`testflight.yml`; check its inputs).
  3. Provenance's main checkout still holds the other session's uncommitted `project.pbxproj` (an Xcode re-serialisation; drop it) and `Package.resolved` (never commit: v2 drops the ZipArchive pin). Leave both alone or discard the pbxproj with the owner's OK.

## 3. iCube issues (done today)

- **Closed:**
  - #7, ICUBE-1: path removed by `dbb93b4333`; dSYM uploads work since 2026-10-12.
  - Triage reports #12, #13, #22, #43.
- **Filed:**
  - #45: Fatal App Hang, ICUBE-2D/6H. Needs Instruments on an iOS 26 device.
  - #46: JIT write fault, ICUBE-AA/60, legacy JIT.
  - #47: iOS 26.0 `glassEffect` abort, ICUBE-86, low.
- **Open but not ours:** #4 alpha tracker, #11 JIT how-to.
- The weekly triage routine (`trig_014fxnY3g7GYXvNQgZsbdRRq`) will keep opening a report issue every Monday.
- Local `~/.sentryclirc` token returns 401 (CI uses its own token).

## 4. Mods / patching (shipped, device-unverified)

- Handoff with device tests: `docs/handoff-2026-10-15-mods-patching.md`.
- **PVPatchEngine** lives in its own repo, github.com/Provenance-Emu/PVPatchEngine (extracted 2026-10-17 with history). iCube, iFly and Provenance depend on it by URL; change it there and tag a release.
  - iFly consumes it as a local path dependency from this submodule path.
  - Its API is **frozen for iFly**: message the iFly session before changing it or before vendoring LZMA.
- **Worktrees:** `~/Workspace/icube-mods`, `-riiv`, `-engine`, `-browser`, `-disc` are all merged. Remove them once iFly confirms it no longer reads `~/Workspace/icube-mods`; it said it would repoint. Use `git worktree remove` from the dolphin-ios checkout.
- `~/Workspace/prov-replace-rebase` (Provenance worktree for #3748) is merged and can be removed. Its submodule folders are symlinks the agent added, so `git fetch` there needs `--no-recurse-submodules`.

## 5. Still owed from the tvOS-redesign handoff

- Device tests (NSO N64 pad, DualSense pointer, NFC, Send to Provenance, app-switcher close).
- AASA on icube-emu.com.
- CloudKit schema promote after the first device sync run.
- iFly billing.
