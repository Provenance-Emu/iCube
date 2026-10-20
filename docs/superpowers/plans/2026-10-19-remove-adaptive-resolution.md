# Remove adaptive internal resolution

Owner decision: remove performance-driven resolution changes during emulation. Preserve normal manual scales and Auto (Fit Window), which responds to window sizing rather than frame rate. Native1x remains the conservative release default in response to the A14 TestFlight report.

1. Reproduce currently exposed adaptive controls with XCUIRemote. Red test fails for enable, OSD, target FPS and min/max scales.
2. Remove AutoIRController and CMake entries, seven core config declarations/definitions, app bridge methods, Video state/actions/UI, unused bound enums and obsolete enhancement side effects. Saved legacy enable=true must have no reader capable of reactivating the feature.
3. Remove independent thermal EFB writes and their baseline/restore helper. Retain other thermal tuning and adaptive CPU/VI logic. Make bottleneck classification unconditional rather than gated by the removed resolution preference.
4. Update model/writeback tests, preserving fixed/fit-window selections, Native reset, per-game overrides and SSAA independence. Keep benchmark/manual resolution APIs usable.
5. Rebuild core slices; an app-only build with the old xcframework cannot prove removal because the old controller bootstraps itself. Check rebuilt binary symbols and package provenance. Rebuild app and run settings tests plus tvOS UI red→green.
6. Run shipping configuration/device gates and a legacy-config gameplay probe across load/thermal changes. Verify no adaptive EFB writes, fit-window/manual options work, CPU/VI classification updates. Document anything not actually exercised; no release pass from previews alone.

Related: settings blocker #53, performance #56, tvOS audit evidence and TestFlight user-report triage. Default ISO #60 and manual Change Disc #61 remain separate feature gaps. Functional tvOS menu checks pass, but captured focus-chrome clipping still needs polish before closing R1.

Adaptive-resolution removal is tracked in [#62](https://github.com/Provenance-Emu/iCube/issues/62). Use `Tools/release-audit/check_resolution_core.py` on the completed package and embedded app frameworks to reject stale cores.


Local execution result: all four iOS/tvOS device/simulator shipping core variants rebuilt and packaged successfully. The package, embedded NJB Debug simulator frameworks and installed app frameworks all pass the retired-content check. A missing sibling OS64 framework was recreated from its completed fresh dylib before packaging; every supplied slice was checked. Catalyst is outside this release scope. Core logs: `core-without-auto-ir.log`, `core-without-auto-ir-shipping.log`.

The iOS fresh-core app passes 97 targeted settings tests. The updated tvOS UI passes 25 tests (19 page captures plus six behavioral regressions), followed by three passing fresh-core tests for Video control absence, CPU persistence/restoration and rail-menu focus/cancellation. All have zero failures/skips. The UI red test and old-core rejection were demonstrated before removal. [Verification hashes/counts](../../app-store/release-evidence/2026-10-19-resolution-verification.json).

Still open: Release (AppStore) build/artifact/screen acceptance, physical legacy-config/load/thermal gameplay and a matched A14 performance comparison. Other reproduced UI/settings defects remain in the audit and #52/#53; Default ISO #60 and manual Change Disc #61 are not implemented by this removal. No TestFlight publication or overall release-readiness claim.
