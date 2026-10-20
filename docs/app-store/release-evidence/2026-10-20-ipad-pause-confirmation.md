# iPad pause confirmation — October 20, 2026

Owner report: Pause → Exit displays its confirmation text without usable confirmation/cancel buttons, leaving the pause UI stuck.

## Confirmed physical reproduction

At 6:57 p.m. America/New_York on October 20, the owner opened Pause → Exit in the installed TestFlight on the physical iPad. Direct device screenshot capture confirms a centered Exit Game panel containing the title and unsaved-progress warning, with **no visible Cancel, Quit or Save & Quit controls**. The pause tiles are dimmed behind the modal. The underlying Upscaling tile reads Native. This matches the predicted collapsed action area. No game was quit, saved or reset during capture; the prompt was left untouched.

Local evidence: `build/release-audit/2026-10-20-pause-exit/ipad-physical-exit-reported.png`, 2732 × 2048 pixels, SHA-256 `660fe0e643fc2c14cde120d43d8000b5dc6e2bee64c2af7ce09e614e6d8ef478`. This proves the shipped failure visually; it does not establish fixed-build acceptance or programmatic hit testing.

## Source diagnosis and change

`ICubeConfirmPanel` requested intrinsic vertical size from `MenuScreen(style: .grid)`. That renderer's root is a `GeometryReader`, containing a scroll view and lazy grid. It cannot derive its ideal height from the action rows. The menu model already contains Cancel, Quit and Save & Quit; the problem is in their layout, not missing actions.

The iOS confirmation now uses a one-column `.actions` renderer with eager rows that supply intrinsic height. `ViewThatFits` falls back to scrolling when the action area cannot fit. Existing action handlers and controller navigation/scope ownership are retained. Reset and save-failure confirmations use this same panel. The tvOS renderer is unchanged. The Debug pause preview now selects its actual platform rather than always using `.tvos`.

## Verification status

- Swift frontend parsing of all four changed Swift files and `git diff --check` pass.
- Independent source review found no blocking issue in switch coverage, one-column input navigation, width constraints or touch row sizing.
- Added a hosted intrinsic-height regression to `SettingsSharedComponentsTests`, plus external portrait/landscape UI tests requiring all actions to be onscreen/hittable, Cancel dismissal and Exit reopening. These have **not passed at this checkpoint**.
- The attempted automated baseline test has **not executed**: host saturation stalled simulator launch and UI-test compilation. The app SDK build also stalled during build preparation. A failed infrastructure run is not a failing application assertion. The source fix was made before the physical reproduction above became available; no automated red/green runtime claim is made.
- Initial app build log is named `pause-exit-baseline-build.log`, but source changed while that command was still in build preparation. Its name does not establish that its eventual product is a baseline binary. The dedicated simulator's installed older product was kept separate.
- Final infrastructure inspection found task-owned build/compiler processes in `STAT T` (suspended), in addition to severe host load and earlier CoreSimulator failures. The stalled SDK/UI-test attempts were interrupted; only positively identified task-owned processes were terminated and continued to let termination complete. No unrelated builds or simulator services were stopped. The partial UI result contains no executed tests. Recover host execution and rerun; do not interpret the interruption as an app failure.
- Physical iPad inspection confirmed TestFlight `1.0.0 (1792472425)` and a separate DEV install. Activated the existing TestFlight and captured its library without changing settings, ROMs or saves. Direct screenshot capture works. Device Hub remote touch requires iPadOS 27+, while this device runs 26.6.2; the Xcode interaction tool likewise did not offer it. A read-only physical XCTest harness is prepared, not run. The owner subsequently opened the Exit prompt, enabling the confirmed reproduction above.

Raw logs/screenshots and generated projects are gitignored under `build/release-audit/2026-10-20-pause-exit/`; personal home-screen captures must not be published. See [test recipe](../../../Tools/release-audit/ios-pause-exit.md).

## Remaining acceptance

1. Complete the SDK build and hosted layout regression.
2. Run the rendered portrait/landscape checks against the fixed binary and inspect screenshots; the shipped failure is now visually confirmed on the physical iPad.
3. Check short-screen/large-text scrolling and controller focus visibility, including switching from the fitting branch to overflow.
4. Validate the actual iPad pause/Exit/Cancel path, preserving its installed library and saves. Verify Reset's cancellation as the sibling path.
5. Archive/upload only after the release's independent startup-crash and distribution gates are also addressed. This source checkpoint is not a verified TestFlight fix.
