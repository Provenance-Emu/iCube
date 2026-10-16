# Handoff 2026-10-16: iCube + Provenance CI on the Mac Studio (Xcode 27)

Follows `docs/handoff-2026-10-15-consolidated.md`. Goal 1 is done, goal 2 is blocked on one PR, goal 3 is done.

## Status

| | State |
|---|---|
| iCube TestFlight | **Uploaded and distributed**, run [38936798770](https://github.com/Provenance-Emu/iCube/actions/runs/38936798770) on `48d9255743`: iOS build 1792171841, tvOS build 1792170957. External groups and Sentry dSYMs succeeded. |
| Provenance develop | Still red, now only on realm-core vs the Xcode 27 libc++ (`lazy_synth_three_way_comparator.h`). Fix: realm-swift ≥ 20.0.6 plus a MarkdownView 1.7.0 / iOS 27 SDK fix. These are owned by the "Fix Xcode 27 archive: Multiple commands produce" session, which is opening a PR. |
| Provenance TestFlight | **Not triggered.** Trigger it once develop builds green: `gh workflow run testflight.yml -R Provenance-Emu/Provenance --ref develop -f platform=all`. Routing and signing are already in place. |
| Cleanup | `~/Workspace/prov-replace-rebase` and all five `~/Workspace/icube-mods*` worktrees removed (iFly confirmed; branches kept). |

## What broke when CI moved to the Studio, and the fix for each

The Studio has only Xcode 27.0 (27A266a). Its runners are LaunchDaemons running as `ghrunner`, with no sudo for us. Local Xcode 27.2 beta does NOT reproduce problems 3 and 4. Reproduce on the Studio instead (see below).

1. **"0 valid identities" after the p12 import.** The System keychain has only the WWDR intermediate that expired in 2023, and `ghrunner` has none. Fix: `testflight.yml` imports AppleWWDRCAG3/G6 into the job keychain. On a user that already has them, the import tolerates "already exists". (iCube `8459e1e4f8`, `48d9255743`; Provenance `38d0dee1b4`, `8d64a8f238`.)
2. **Missing Metal Toolchain** ("cannot execute tool 'metal'"). Installed once, system-wide. The self-hosted "Select Xcode" step in build/testflight/release/tests now downloads it when missing.
3. **iCube: PLzmaSDK "uses unsafe build flags".** Xcode 27.0 refuses it as a direct project dependency, even when revision-pinned. Fix: the local package `Source/iOS/PLzmaShim` re-exports it (`78aac599fe`). Provenance already reaches it through local packages.
4. **Provenance: "Multiple commands produce .../Provenance.app".** Xcode 27.0 gives two targets that build the same product an implicit dependency on each other ("via file 'Provenance.app' in build phase 'Copy Files'"). Fix: the plain `Provenance` target builds `Provenance-Dev.app`. Its module is still `Provenance`, and `TEST_HOST` and the schemes follow (`38d0dee1b4`, `7baa4ee623`). Shipping builds use `Provenance (AppStore)` and are unchanged.
5. **Deployment targets below 15.0 are errors.** PPSSPP's committed cmake pbxproj (11.0) and PVDolphin `Make XCFrameworks` (13.0) are now 17.0. `Cores/PPSSPP/cmake/CMakeCache.txt` still says 13.0; it was left alone so `ZERO_CHECK` doesn't re-run cmake.
6. **Codesign `errSecInternalComponent` on `ghrunner`.** `ghrunner` has never logged in and has no default keychain. Passing `--keychain` and setting a default didn't help. Fix (owner-approved): extra repo-level runners as **LaunchAgents in jmattiello's GUI session**.
   - Location: `~/actions-runner/{icube,provenance}` on the Studio, named `studio-gui-icube` and `studio-gui-provenance`, with the single label `studio-gui`.
   - Load with `launchctl bootstrap gui/501 ~/Library/LaunchAgents/actions.runner.Provenance-Emu-<Repo>.studio-gui-<repo>.plist`.
   - The repo variable `TESTFLIGHT_RUNNER_LABELS=["self-hosted","studio-gui"]` routes only `testflight.yml` there. Builds and tests stay on `MACOS_RUNNER_LABELS` (ghrunner).

## Owner notes

- TestFlight jobs (dispatch, schedule and tag triggers; never fork PRs) now run **as your admin account**, with access to your home directory and your unlocked login keychain.
- The GUI runners only run while you're logged in at the Studio console. After a reboot they need auto-login, which FileVault can block. Otherwise TestFlight jobs queue indefinitely; unset `TESTFLIGHT_RUNNER_LABELS` to fall back to `ghrunner` (signing fails there) or remove both variables to use hosted macos-26.
- The Studio disk was at 88% (54 GB free) after setup.
- Unrelated #3748 PR checks that were red on hosted runners: Coreless "Could not resolve package dependencies" and PVUI tvOS "PackageBuildInfoPlugin … Operation not permitted". Not investigated.

## Reproducing on the Studio

`cp -cR` an APFS clone of `/Users/ghrunner/runners/<repo>/_work/<Repo>/<Repo>` into your home. Then run a planning-only `xcodebuild archive` that kills itself at the first `CompileC`/`SwiftCompile`/`PhaseScriptExecution`, and grep for `Multiple commands produce` / `via file`. Tuist for your user comes from `mise` at `~/.local/share/mise/shims/tuist`. Delete the clones afterwards.
