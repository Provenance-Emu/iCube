# CI core disk failure and preflight — 2026-10-20

[Build run 39389325141, job 118516765193](https://github.com/Provenance-Emu/iCube/actions/runs/39389325141/job/118516765193), head `e1b860e9567ee438025b47f7a90199fe246de871`, failed on self-hosted runner `studio-icube`.

At 07:57:54 UTC, the fourth slice, `SIMULATOR_TVOS`, failed archiving `Source/Core/Core/libcore.a`:

```text
write64() failed, returned -1 expected 317393344, errno=28
ranlib: error writing file 'Source/Core/Core/libcore.a'
ar: internal ranlib command failed
```

`errno=28` is `ENOSPC` (no space left on device). `OS64`, `SIMULATORARM64` and `TVOS` had explicitly completed. Static pugixml compiled and linked successfully; this was not the earlier dynamic-dependency configure failure.

## Change and validation

`build.yml` now checks disk capacity after restoring the core cache and before the core build. It prints filesystem/free-space information and fails with an actionable error below the configured budget. Repository variable `DOL_MIN_FREE_DISK_GB` accepts a positive integer, default **20 GiB**. This is a configurable headroom budget for the four-slice core and subsequent app archives; runner capacity still must be reclaimed or provisioned before retrying.

The existing static dependency mode and all four required slices are unchanged. No cleanup is performed by the workflow.

Validation extracted the actual inline Python from parsed workflow YAML and mocked disk capacity: default budget rejected 5 GiB free, accepted exactly 20 and 30 GiB; an 8 GiB override accepted 10 GiB; malformed and negative settings failed clearly. All six checks, step order, unchanged build command, YAML parsing and `git diff --check` passed. No core/app build or CI rerun was performed for this change.

## Read-only runner inspection

Trusted SSH alias `studio-runner` confirmed `.runner` agent name `studio-icube`, repository `Provenance-Emu/iCube`, and workspace `/Users/ghrunner/runners/icube/_work/iCube/iCube`. Workspace and runner configuration are owned by `ghrunner:staff`. At inspection the volume had **14.83 GiB free**; iCube's runner was online/not busy, while Provenance work was active on the shared host.

These failed-job CMake intermediate directories were all **absent**, so no ownership/size or deletion candidate could be established for them:

- `/Users/ghrunner/runners/icube/_work/iCube/iCube/build-iphoneos-Release`
- `/Users/ghrunner/runners/icube/_work/iCube/iCube/build-iphonesimulator-Release`
- `/Users/ghrunner/runners/icube/_work/iCube/iCube/build-appletvos-Release`
- `/Users/ghrunner/runners/icube/_work/iCube/iCube/build-appletvsimulator-Release`

The sole existing `build*` entry was the cached framework output at `/Users/ghrunner/runners/icube/_work/iCube/iCube/build`, 212,452 KiB by `du -sk`. Preserve it. **No verified abandoned iCube intermediates were proposed for deletion, and nothing was deleted.** No global Xcode setup, process termination, binary change or user-data inspection was performed.

Scratch evidence: `/tmp/icube-ci-39389325141/{failed.log,diagnosis.json,preflight-red.log,preflight-green.log,runner-storage.txt,runner-config.txt}`.
