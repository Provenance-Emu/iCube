# tvOS settings default-indicator audit — 2026-10-21

The indicator compares snapshots only against explicitly opted-in baselines. It does not infer factory defaults from UI `State()` initializers. Factory helpers default to no indicator when no typed `defaultValue` is supplied. Enabled state and disabled reasons are independent from modification state.

Sources (repository-relative; line numbers at audit time):

- **G**: `Source/Core/Core/Config/GraphicsSettings.cpp` compiled defaults.
- **R**: `Source/iOS/App/Common/Bridging/DOLConfigBridge.mm`, `resetGameplayConfigKeys` at 1205; deletion removes Base/current overrides so compiled defaults apply, with explicit seed-equivalent exceptions below. Global reset invokes this at 1587.
- **S**: `Source/iOS/App/Common/Services/DolphinCoreService.mm`, `seedLaunchDefaultsWithFastmemAvailable` at 82. `SetBaseIfUnspecified` preserves existing user values, lines 67–78.
- `Source/iOS/App/Common/Services/DefaultsInitService.swift` only creates folders/backup exclusions and does not establish gameplay config baselines.

| Row | Indicator baseline | G line | R line | S line |
|---|---|---|---|---|
| texture-cache | 0 | 44 (compiled 128) | 1337; 1396 forces 0 | 102 seeds 0 |
| bbox | false | 214 | 1336 | — |
| bbox-sync | 0 / Latched | 260 | 1361 | — |
| efb-access | false | 210 | 1338 | — |
| skip-efb-ram | true | 216 | 1339 | 98 seeds true |
| skip-xfb-ram | true | 217 | 1340 | 99 seeds true |
| immediate-xfb | true | 220 (compiled false) | 1341; 1406 forces true | 100 seeds true |
| copy-efb-scaled | true | 224 | 1342 | — |
| early-xfb | true | 223 | 1357 | — |
| skip-duplicate-xfb | true | 222 | 1358 | — |
| vertex-rounding | false | 227 | 1344 | — |
| force-progressive | true | 215 | 1345 | — |
| defer-efb-copies | true | 219 | 1346 | — |
| vi-skip | Auto | 230–236 (Apple branch) | 1349; 1414–1419 explains Auto | 124 seeds Auto |
| fast-texture-sampling | true | 239–240 | 1352 | — |
| fast-math | true | 265 | 1353 | — |
| compute-efb-xfb | false | 279 | 1354 | — |
| compute-vertex-decode | false | 285–286 | 1355 | — |
| no-mipmapping | false | 242 | 1356 | — |
| vi-decimate-interlace | false | 271–277 | 1351 | — |
| efb-scale | 1 / Native | 93 | 1312 deletes to compiled Native | 146 seeds Native |
| metalfx-upscale | false | 262–263 | 1331 | — |
| msaa | 1 / None | 91 | 1332 | — |
| ssaa | false | 92 | 1333 | — |
| output-resampling | Default | 164–165 | 1330 | — |
| true-color | true | 168–169 | 1324 | — |
| disable-copy-filter | true | 170–171 | 1325 | — |
| widescreen-hack | false | 21 | 1313 | — |
| hdr-output | false | 176 | 1329 | — |
| gpu-texture-decoding | false | 87–88 | 1315 | — |
| disable-fog | false | 99 | 1314 | — |
| arbitrary-mipmap | true | 172–173 | 1327 | — |
| arbitrary-mipmap-threshold | 14 | 174–175 | 1328 | — |

Clock rows `cpu-clock-percent` and `vbi-percent`: baseline 100%, from `Source/Core/Core/Config/MainSettings.cpp:245,247` (1.0f), reset deletions R:1257,1259; bridge percent conversion R:610–615. No launch seed changes these defaults. Enabled override flags are not opted into modification indicators.

Deliberate exclusions:

- `efb-format-changes`: startup S:104 seeds true, compiled G:225–226 is false, and reset R:1343 deletes without restoring the seed. No unambiguous common launch/reset baseline; no indicator added.
- `anisotropy`: compiled Force4x exists at G:162–163, but the UI ladder/bridge enum mapping was not included in this indicator audit. No inferred raw value.
- Language, console identity, folder paths, selected profiles, arbitrary personal preferences, presentation toggles and credentials remain unmarked. Reset R:1420–1427 explicitly preserves identity/input/cosmetic settings.
- CPU-engine default depends on entitlement/runtime effective-engine selection; engine and optimization booleans are not guessed from `PerformanceTuningState()` or the Recommended badge.
- Device-dependent shader compiler counts and fastmem availability do not have a fixed universal baseline in this change.

Dependency reasons distinguish unsupported bounding-box backend from disabled Bounding Box Emulation. Other reasons cover MSAA prerequisite, game/automatic overrides, optimization validation parent, clock enable flags, memory override, audio backend/surround/spatial prerequisites, audio effect parents, Wii Speak mute/enable, custom texture loading, unavailable fastmem, and duplicate/deferred XFB copy conditions.

Verification: factory/bbox/resolution/clock metadata regression cases added; focused Swift frontend parsing and `git diff --check` pass. SDK execution belongs to the coordinating serial build/test run. All 20 added disabled-reason keys have English and Japanese values; both catalogs pass `plutil -lint`; localized-key checker `--check` reports 0 missing keys. No device/runtime or SDK success is implied by parsing.
