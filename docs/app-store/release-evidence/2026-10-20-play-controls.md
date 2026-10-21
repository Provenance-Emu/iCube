# Play controls and save history — verification in progress

The owner approved the [design](../../superpowers/specs/2026-10-20-play-toolbar-save-history-design.md) and [plan](../../superpowers/plans/2026-10-20-play-toolbar-save-history.md), including compact iPhone/iPad portrait layouts and subagent execution. This document records the current wave; it is not an App Store readiness or upload claim.

## Behavior

- Labeled toolbar with direct Pause, Save, Load and Saves. Standard portrait height is 72 points excluding safe area; targets are at least 44 points. Controller contains on-screen controls and the explicit Wii pointer options. Shaders has a text label.
- History is the default. Quick Save creates a unique state; ten unkept history states per game are retained. Classic slots, kept states and automatic resume are protected. The browser shows selection, occupancy, compatibility, timestamps and available thumbnails; selection alone never loads.
- Quick Load chooses the newest manual state, then automatic resume if no manual state exists. An incompatible newest state is surfaced rather than silently loading an older one. Modded sessions require explicit classic selection.
- Classic/modded Quick Save opens the browser retaining the selected slot, including empty slots. Explicit overwrite consent follows the captured session/path into the serialized save queue and the guarded bridge call. This intentionally adds a browser step for classic users.
- Mute applies actual runtime audio gain, replays after startup and restores the configured volume after fast-forward muting.

## Evidence so far

Latest follow-up: compact-height phone cards place thumbnails beside metadata, reduce redundant section chrome and retain readable standard fonts and 44-point mode targets. iOS uses one custom principal heading. The exact previously failing geometry assertions now pass: **38 focused layout/cache tests, zero failures/skips**. This follow-up also splits the library-cache cost expression into typed values for Xcode 26.3; source review and local SDK checks pass. Fresh native/full/hosted reruns remain pending for this revision.

The final full iOS suite passes **2,227 tests**, with five opt-in tests skipped and zero failures (2,232 total, 76.5 seconds). Both iOS and tvOS Debug Simulator builds pass. Source checkpoint `fba1b270ab` is pushed. Final targeted result: `play-controls-targeted-final.xcresult`; full result: `play-controls-full-final.xcresult`, under the ignored `build/release-audit/2026-10-20-testflight-final/` directory.

Reviewed backend and mute sources are pushed in `bba7d06a3d`; localization completion is pushed in `22eda26730`. The final UI/routing/consent source review is clean, including the queued-save race and stale-session checks. Native queue tests cover pending saves, explicit consent, session/path drift and fail-closed filesystem errors; production menu tests cover history/classic/modded and stale completions.

The final iOS Simulator SDK build passes, followed by **127 targeted tests, zero failures/skips**, including actual footer lifecycle measurement and accessibility reflow. Source review of the structural SwiftUI body extraction and typed Pause-menu handoff factory is clean. The earlier initial SDK run passed 71 of 73 tests; the next passed 89 of 91. In both, the failing methods were actual picker-footer measurement tests. Their assertions were retained while the observation seam was repaired; the final 127-case run now passes those checks. All fourteen live-audio/mute tests, nine surface-action cases and nine tvOS pane cases passed in the second run. These counts do not establish final candidate acceptance.

Standard iPhone iOS 27 native UI checks passed three landscape/large-text/menu-handoff cases. Earlier Duo simulator orientation did not actually rotate and is excluded from landscape acceptance. Earlier landscape app screenshots also exhibited a toolchain crop/orientation issue; audit captures now use device screenshots. Final native screenshots on both phone and iPad remain required.

The prior real-game physical iPad Exit/Cancel regression passed with the older toolbar; see [physical evidence](2026-10-20-ipad-pause-confirmation.md). The new toolbar requires a fresh signed DEV install and rerun. Production TestFlight and its paused game must remain untouched.

## Outstanding gates

1. Complete native runtime gates below; both Debug SDK builds, all 127 targeted cases and the full iOS suite pass after semantics-preserving view decomposition exposed and corrected the Pause initializer handoff.
2. Final native phone/iPad portrait, landscape and accessibility captures; tvOS focus/Back acceptance.
3. Fresh DEV physical Exit/Cancel, audible mute and non-destructive save-history smoke checks.
4. Accepted source commit, fresh matching iOS/tvOS build number, signed archives, optimized SwiftUI/core/signature/UUID guards, Sentry symbols and both TestFlight uploads/processing/group assignment/Beta Review submission.

The remote self-hosted unit CI currently fails from a CoreSimulator/Xcode version mismatch, separately from source acceptance. A reviewed, actionlint-checked manual `force_hosted` input selects the existing macOS 26/Xcode 26.3 path for one run; the normal runner setting and fork-PR security remain unchanged. The 36-case routing matrix passes; hosted execution remains pending. The existing archives `1792538716` are superseded and must not be uploaded. Current live TestFlight is `1792472425` on both platforms. Cross-device metadata/save/ROM convergence, older-device startup and a controlled Release performance comparison remain separate release gates; this UI wave does not establish them.
