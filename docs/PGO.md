# Profile-Guided Optimization for the core

The jitless engine is dozens of tiny handlers with cold tails, which is exactly what PGO lays out
and inlines well. One command records a profile; after that every core build uses it on its own.

```bash
tools/pgo/pgo.sh record     # build + install the instrumented app, play, pull, merge, rebuild
tools/pgo/pgo.sh status     # what the profile was recorded from, and how stale it is
tools/pgo/pgo.sh device     # which connected device `record` would use (PGO_DEVICE=<name|udid>)
tools/pgo/pgo.sh merge DIR  # merge .profraw files you already have
tools/pgo/pgo.sh clean      # drop the instrumented build dirs
```

## What `record` does
1. Builds the app with `DOL_PGO=generate` (scheme `iCube (NJB)`, configuration
   `Debug (Non-Jailbroken)`, so it installs next to your everyday app). The instrumented core lives
   in its own build dir (`build-<platform>-Release-pgogen`); the normal one is untouched.
2. Checks the embedded core really is instrumented, installs and launches it.
3. You play: a few minutes per game, in heavy scenes, exiting to the library between games. The mix
   you play IS the profile. Go to the Home Screen when done: that flushes the counters to
   `Documents/Software/pgo/icube-*.profraw` (the app also flushes whenever a game is stopped).
4. Pulls that folder with `devicectl`, merges with `llvm-profdata` into `pgo/icube.profdata`, and
   refuses the result unless it contains the interpreter's hot code (`CachedInterpreter`,
   `MicroOpHandlers`). The previous profile is kept as `icube.profdata.prev`.
5. Rebuilds the optimized core (`PGO_NO_REBUILD=1` skips this).

## Automatic use
`BuildiOSXCFramework.py` (`resolve_pgo()`) uses `pgo/icube.profdata` whenever it exists: Xcode's
"Build Dolphin Core" phase, manual runs and CI alike. `DOL_PGO=off` opts a build out;
`DOL_PGO=use DOL_PGO_PROFILE=<path>` picks another profile. Commit `pgo/icube.profdata` and its
`.meta.json` so CI and TestFlight builds get it too.

## Staleness
Clang ignores the profile for any function whose code changed since recording, so an old profile is
harmless but does less and less. `pgo.sh status` counts core commits since the recording; re-record
after significant engine work (it says when).

## Notes
- IR-based PGO (`-fprofile-generate` / `-fprofile-use`): counters sit after inlining, which is what
  the handlers' block layout wants.
- The first instrumented build and the first optimized build are each a full core build.
- `PGO_KEEP_OLD=1` merges a new recording into the existing profile (e.g. to add one more game).
