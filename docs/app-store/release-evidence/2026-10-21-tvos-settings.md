# tvOS settings and pause HUD follow-up

**Shipped: iOS and tvOS TestFlight 1.0.0 (1792601430), source `d32c105479ce5320ae4317320f01396449f0f800`.** Both are VALID, Beta Review APPROVED, internal/external IN_BETA_TESTING, notifications enabled. [Install TestFlight](https://testflight.apple.com/join/9ZEfnyMP).

The owner reported slow cycling of multi-value settings, a conflict between Left-to-sidebar and Left-to-change-value, intermittent first-Back dismissal from both library and pause entry, unclear disabled rows, and a touch-oriented HUD panel reached from tvOS pause. The owner currently cannot reproduce the intermittent Back behavior and has no known sequence; source safeguards are not proof of its original cause.

## Changes

- tvOS list choices open a scrollable direct-selection panel. Opening/browsing does not commit; Select commits, Back cancels and restores the originating row. Left no longer cycles choices.
- Root Settings closes only with category focus. Content Back transfers focus to the category, with deferred transfer protection against duplicate callbacks. Existing nested-page navigation remains.
- Conditional rows show unavailable/dependency text and dimmed styling while remaining skipped by focus. Meaningful settings get an opt-in changed-from-default dot; language and ambiguous defaults are excluded. [Baseline audit](2026-10-21-settings-default-audit.md) compares core defaults and actual launch/reset overrides.
- Long-pressing Performance HUD on tvOS opens six quick toggles in the existing pause room: FPS, VPS, Speed, VBlank, Perf Graph and Overlay Stats. Back restores the HUD tile. iOS keeps its touch panel.

## Evidence so far

Dedicated tvOS simulator: `2543E4FC-4A46-4884-8483-96A6F2253304`. No physical iPad operations; the owner deferred that window.

Old installed DEV baseline proves Left changed System Language, Select cycled immediately instead of opening options, and disabled Bounding Box Sync lacked a dependency explanation. Two-step Back passed General, GameCube, Wii and Hacks in these runs; intermittent dismissal was not reproduced.

Final iOS `build-for-testing` passed. The full iOS suite passed **2,241 tests, five opt-in skips, zero failures (2,246 total)**; result bundle `settings-full-final.xcresult` and summary `settings-full-summary.json` are in the local evidence directory. Final tvOS SDK builds pass, including the contrast correction after screenshot review found two opacity reductions multiplying together. Independent review caught and corrected an initializer argument-order compile issue and a picker-disappearance callback race. Design-token check passes (442 findings, baseline lowered); localization coverage passes (2,035 static keys, zero missing), with valid English/Japanese catalogs.

Local logs, baseline screenshots/AX and test results are under `build/release-audit/2026-10-21-tvos-settings/`. Native audit source is `Tools/release-audit/TVSettingsInteractionAuditTests.swift`.

Native tvOS acceptance:

- Eight primary tests passed: General/GameCube/Wii Back, Left without mutation, chooser opening/cancellation/focus, disabled reason, HUD long-press plus FPS toggle/restore and Back.
- Explicit German selection and English restoration passed. The first run stopped before mutation because its exact accessibility-value expectation ignored combined child values; the corrected run preserves exact restoration comparison.
- Pause Settings reopen/content/Back/close passed three consecutive cycles.
- Library rail → Settings → content → Back to category → Back to library passed using the demo catalogue fixture; no game was booted.
- Final contrast-build disabled-row test and visual review passed. The reason is fully readable; this is screenshot inspection rather than a measured contrast ratio.

Results and screenshots: local `acceptance1.xcresult` (8/8), `acceptance2.xcresult` (repeated Back pass, initial harness AX assumption failure), `acceptance3.xcresult` (2/2) and `acceptance4.xcresult` (2/2), with attachment manifests. Original intermittent Back was not reproduced, so these checks establish the tested sequences and safeguards, not its original cause.

## Distribution and limits

Both archives and final distribution IPAs pass signature, core UUID/dSYM, optimized SwiftUI compatibility, retired adaptive-resolution content and production iCloud checks. Final IPAs disable debugging and carry Production iCloud entitlements. Sentry has app/core symbols for both platforms. Exact IPA hashes, build IDs, group names and Apple availability are in the [distribution proof](2026-10-21-tvos-settings-distribution.json).

Both builds are assigned to Internal, Patrons, Moderators, Friends and Family, and Public Website; What to Test is updated and normal Beta Review completed. No App Store release submission occurred.

The self-hosted CI unit run [39638371815](https://github.com/Provenance-Emu/iCube/actions/runs/39638371815) failed before tests because CoreSimulator 1171.7.0 is older than the selected Xcode requires (1174.9.2). The existing hosted-runner option was used for [39638918029](https://github.com/Provenance-Emu/iCube/actions/runs/39638918029); it remains queued at final verification. This does not replace or invalidate the fresh local full suite; no CI pass is claimed.

The build formatter removed one blank line before Perf Graph in English/Japanese catalogs. Pinned source, formatted source and each compiled archive catalog were parsed and verified identical. Pinned bytes were restored before each guarded release phase. The final evidence commit normalizes those two blank lines only; catalog entries and shipped content remain identical. Proofs are local ios-localization-format-proof.json / tvos-localization-format-proof.json.

Physical iPad testing remains deferred by the owner. The original intermittent Back trigger remains unknown; both reported entry sequences and repeated pause cycles pass. Cross-device sync/Provenance acceptance, older-device startup, live telemetry and controlled Release performance gates in the release plan remain separate App Store requirements.
