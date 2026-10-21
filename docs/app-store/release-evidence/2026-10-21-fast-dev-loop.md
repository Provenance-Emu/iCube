# Faster DEV iteration — October 21, 2026

Status: implementation and native integration verified on dedicated simulators; independent review has no open Important findings. This changes local Debug tooling, not the shipped TestFlight binary. Physical automation remains deferred by the owner.

## Workflow

[CLI and command reference](../../../Tools/dev-loop/README.md). Register explicit named simulator/device destinations, adopt a validated engine, then reuse app products and standalone XCTest runners. Ordinary navigation scripts are JSON: changing a sequence does not rebuild the runner. Capture and AX inspection can run during compilation; control operations serialize with native tests. Busy operations fail promptly rather than silently queueing.

Default engine reuse requires matching accepted source and binary hashes. Explicit scoped `--pin-core` permits current UI against an exact previously accepted engine while concurrent engine work is excluded from acceptance. A changed selected engine binary still rejects reuse. Source, localization, generated project, SDK/signing inputs, build products and actual installed simulator DEV payload guard reuse. Builds reject concurrent Swift/Objective-C/bridge/input edits; expected localization output is treated separately. Test-result summaries reject zero-test selections and distinguish skips.

The existing iOS simulator engine was concurrently rebuilt for locale work. TV checks below use the unchanged accepted TV engine from source `d32c105479`; they do not validate pending locale engine changes. iPhone/iPad runner checks explicitly use `--existing-dev` and make no source/engine freshness claim. All control targets are dedicated simulators; production and physical devices were not controlled.

## Measurements

| Operation | Measured wall time | Evidence |
|---|---:|---|
| Previous warm TV app build, no Swift compilation | 45.687s | `build/dev-loop-benchmark/warm-baseline.json` |
| First TV runner build | 64.477s | run `20261021-152821-367789eb` |
| Cached TV runner preparation | about0.2s | run `20261021-153100-1ce3a79c` |
| First iOS runner build, shared by phone and tablet | 18.754s | run `20261021-153441-1019c940` |
| First app build after changing configuration | 142.583s plus9.531s project generation | run `20261021-153603-34fa7f07`; full Swift recompilation, setup cost |
| Comment-only Swift edit, incremental TV app build | 42.881s Xcode /54.702s total | run `20261021-154013-0a3501bf`; comment subsequently removed with exact original file hash verified |
| Restored-source TV app build | 54.111s total | `build/dev-loop-benchmark/final-checks.json` |
| Verified unchanged app cache hit | 4.943s total | same; no Xcode build phase |
| Simulator DEV install | 9.028s total | same |
| Verified current-app/pinned-engine TV UI check | 25.105s total /17.126s XCTest invocation | run `20261021-153935-f5805fdf`; one passed |
| iPhone native launch/tap/assert/capture | 30.688s total | run `20261021-154119-b3b30876`; one passed; existing DEV freshness unverified |
| iPad native launch/tap/assert/capture | 37.920s total | run `20261021-154214-6943fda7`; one passed; same cached iOS runner, existing DEV freshness unverified |
| Final TV native remote focus/navigation | 30.040s total | run `20261021-154418-70d9b863`; one passed; current app/pinned engine |
| TV screenshot + AX capture | 1.508s phase sum | run `20261021-153517-5be6d106` |

These are observed individual runs on this Mac, not a performance guarantee or matched app performance benchmark. A focused edit/build/install/check cycle is around one to two minutes on the measured TV path; initial cache setup and native engine rebuilds remain separate. A cached app check does not compile changed source: all fingerprints must match first.

## Build-phase changes

Fast Debug omits Sentry symbol upload. Localization regeneration skips only after a successful normal generation whose inputs still match; new PO/storyboard/strings/script inputs invalidate it. Normal Debug and Release still execute their original work. Python setup imports `polib` before invoking pip, avoiding a redundant install check when it is already available. No Release archive/upload guard is removed.

## Verification and limits

Independent review covered stale app/engine reuse, localization changes, project graph drift, malformed action plans, SDK/runner identity, physical controls, zero-test outcomes and concurrent source changes. Swift actions/schema compile for iOS and tvOS; real simulator launch/tap/remote-focus checks run against DEV only. Native suite and final timing counts are recorded in the final result table below.

Physical targets require explicit control opt-in; device launch/test additionally requires `--existing-dev` until installed-device payload verification is available. No physical runtime pass is claimed. Native controller+Siri Remote live input ownership remains a separate Performance feature and hardware acceptance gate. [Reviewed proposed design](../../superpowers/specs/2026-10-21-performance-controls-design.md).

## Final results

| Check | Result | Evidence |
|---|---|---|
| CLI/provenance/schema/phase guards | 45 passed | `build/dev-loop-benchmark/tooling-tests.log` |
| TV native remote navigation | 1 passed | run `20261021-154418-70d9b863` |
| iPhone native actions | 1 passed | run `20261021-154119-b3b30876` |
| iPad native actions | 1 passed | run `20261021-154214-6943fda7` |
| Final capture calls TV / phone / tablet | 2.439 /3.154 /2.820s total | `build/dev-loop-benchmark/final-checks.json` |
| Library metadata host tests | 32 passed | `build/dev-loop-benchmark/library-metadata.log` |
| Library editing host tests | 12 passed | `build/dev-loop-benchmark/library-editing-fixed.log` |
| Nearby mirror scheduler host tests | 12 passed | `build/dev-loop-benchmark/nearby-mirror-fixed.log` |
| Continuity package / controller host tests | 208 /35 passed | `build/dev-loop-benchmark/continuity-controllers.log` |

The initial editing harness failed before tests: PATH selected an old `~/.swiftly/bin/swift` rejecting tools-version5.9. Its failure remains in `library-editing.log`; editing, mirror and continuity harnesses now invoke `xcrun swift test`, respecting DEVELOPER_DIR. The corrected targeted library/continuity host checks total **299 tests, zero failures**. These model/transport fixtures do not prove installed-device pairing, CloudKit convergence or playable state restoration.

## Remaining release acceptance

Automatic nearby foreground ROM mirroring exists and its scheduler is tested. Still verify manual/automatic ROM transfers in both directions on installed iCube and Provenance, relaunch deduplication, cancellation/revocation, actual metadata convergence and playable save restoration. Provenance's current ROM continuity source excludes saves; the title/cover/tag metadata projection/merge adapter remains a proposal. Do not label a successful ROM copy as complete cross-app library/save sync. Physical checks remain deferred.
