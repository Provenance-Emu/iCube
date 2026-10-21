# Play controls and save history — verification in progress

The owner approved the [design](../../superpowers/specs/2026-10-20-play-toolbar-save-history-design.md) and [plan](../../superpowers/plans/2026-10-20-play-toolbar-save-history.md), including compact iPhone/iPad portrait layouts and subagent execution. This document records the current wave; it is not an App Store readiness or upload claim.

## Behavior

- Labeled toolbar with direct Pause, Save, Load and Saves. Standard portrait height is 72 points excluding safe area; targets are at least 44 points. Controller contains on-screen controls and the explicit Wii pointer options. Shaders has a text label.
- History is the default. Quick Save creates a unique state; ten unkept history states per game are retained. Classic slots, kept states and automatic resume are protected. The browser shows selection, occupancy, compatibility, timestamps and available thumbnails; selection alone never loads.
- Quick Load chooses the newest manual state, then automatic resume if no manual state exists. An incompatible newest state is surfaced rather than silently loading an older one. Modded sessions require explicit classic selection.
- Classic/modded Quick Save opens the browser retaining the selected slot, including empty slots. Explicit overwrite consent follows the captured session/path into the serialized save queue and the guarded bridge call. This intentionally adds a browser step for classic users.
- Mute applies actual runtime audio gain, replays after startup and restores the configured volume after fast-forward muting.

## Accepted simulator evidence

The accepted source checkpoint `a0fbc29b80` is pushed. The final iOS SDK build (`play-controls-selection-final-build.log`) and tvOS SDK build (`play-controls-tvos-accepted-build.log`) pass. The full iOS suite reports **2,229 passed, five opt-in skips, zero failures (2,234 total)** in `play-controls-full-accepted.xcresult`. The final focused layout/cache run reports **38 passed, zero skips/failures** in `play-controls-selection-focused.xcresult`.

Native simulator UI checks pass **7/7 on iPhone 17 Pro, 7/7 on iPad Pro 12.9-inch, and 2/2 on Apple TV**, using iOS/tvOS 27. The accepted result bundles are `play-controls-ui-phone-accepted.xcresult`, `play-controls-ui-ipad-accepted.xcresult` and `play-controls-ui-tv-accepted.xcresult`. These establish portrait height/targets, direct Pause, readable initial landscape metadata, accessibility scrolling, single save-browser heading, tvOS focus and Back. Final phone/iPad screenshots were inspected; the compact selection indicator has a reserved column and a strict measured nonintersection regression. All artifacts are under ignored `build/release-audit/2026-10-20-testflight-final/`.

Hosted CI [39535150389](https://github.com/Provenance-Emu/iCube/actions/runs/39535150389) passed on `0964b2aba9`. The exact-source manual hosted run [39538314157](https://github.com/Provenance-Emu/iCube/actions/runs/39538314157) also passed on final product checkpoint `a0fbc29b80`. The manual override defaults false and preserves normal runner configuration and fork security. It avoids the verified remote Studio CoreSimulator/Xcode mismatch without global service or repository-variable changes.

The final source review is clean, including queued overwrite consent and stale-session checks. Four native queue race cases and nine actual production menu/facade cases passed in targeted validation. The fourteen live backend/mute regressions passed, including startup and fast-forward volume restoration. Hardware-free DSP and slider checks do not establish audible output on the owner's iPad.

## Remaining gates

1. Signed DEV build `1792552677` built, passed signature/SwiftUI/core guards and was installed as a data-preserving update. Fresh preflight confirmed ConfirmStop enabled, positive volume, default history mode and zero history payloads among the six existing files. Rerun real-game Exit/Cancel, audible mute and a new immutable history save/load on the physical iPad. The previous [physical Exit pass](2026-10-20-ipad-pause-confirmation.md) predates this toolbar. Production TestFlight and its paused game remain untouched.
2. Freeze the accepted source, allocate one fresh build number for iOS/tvOS, archive both, validate optimized SwiftUI/core/signature/UUID guards, upload matching Sentry symbols, then complete the authorized TestFlight uploads, processing, groups and Beta App Review submission. Superseded archives `1792538716` must not be uploaded. Existing live TestFlight is `1792472425`; no new upload is claimed.
3. Cross-device metadata/save/ROM convergence, older-device startup and a controlled Release performance comparison remain separate release gates. This UI wave does not establish those results or App Store readiness.

The first new-build physical run stopped at the no-JIT button hittability assertion before Exit was reached; this does not establish an Exit regression or acceptance. The narrow harness correction sets landscape explicitly and waits for hittability without coordinate fallback; its SDK build passes. Physical rerun is waiting for a coordinated device window. No new mute/history physical pass is claimed.
