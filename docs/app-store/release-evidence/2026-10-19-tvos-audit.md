# tvOS UI and settings release audit — 2026-10-19

Status: in progress. See also [TestFlight user report triage](2026-10-19-testflight-user-report.md). Release workstreams: [R1 #52](https://github.com/Provenance-Emu/iCube/issues/52), [R2 #53](https://github.com/Provenance-Emu/iCube/issues/53).

Baseline source: `8bad720220`. Runtime target: Apple TV 4K (3rd generation, 1080p), tvOS 26.5 simulator `59214C60-C1D5-460F-91DC-BA425B4868C4`. Xcode 27.1 toolchain, tvOS 27 SDK. NJB Debug evidence does not establish APPSTORE visibility, physical-remote behavior or production sync.

## Environment

- Generated workspace initially referenced the removed local `Source/iOS/PVPatchEngine`; first baseline build could not resolve it. `tuist generate --no-open` regenerated it from current Project.swift successfully. No product source fix was needed.
- Fresh tvOS simulator app build uses `DOL_SKIP_CORE_BUILD=1` and the existing simulator xcframework slice. The older October 16 app is not being counted as current baseline evidence.
- Build/runtime logs and full-resolution captures are under `/tmp/icube-tvos-audit-2026-10-19/`; selected evidence should be copied into durable artifacts when findings are verified.

## Settings coverage

Reach/render records the manually inspected initial viewport from the 19-page sweep; it does not imply a clean page or functional settings. Known visual issues are listed below. Preview launch checks cannot establish exiting Settings because the preview makes it the root screen; that case needs the real library → Settings route.

| Leaf | Reach/render | Focus and Back | Change and persistence | Notes |
|---|---|---|---|---|
| `console-gamecube` | pass (initial viewport) | pending | pending |  |
| `console-wii` | pass (initial viewport) | pending | pending |  |
| `achievements` | pending | pending | pending | build/service availability applies |
| `performance-tuning` | pass (NJB simulator) | CPU Left/Right retains focus; Menu returns to sidebar | pass: change, relaunch, restore original | Remote XCTest; rerun on migrated head also passes |
| `debug` | pass (initial viewport) | full-path details: Menu/Done return pass; other actions pending | pending | build/service availability applies |
| `web-ui` | pass (initial viewport) | pending | pending |  |
| `icloud` | pass (initial viewport) | pending | pending | build/service availability applies |
| `nearby` | pass (initial viewport) | pending | pending |  |
| `connected-apps` | pending | pending | pending | iOS only; excluded from tvOS |
| `general` | pass (NJB simulator) | real entry → pane → Menu → sidebar → Menu → library passes | pending | Remote XCTest baseline |
| `interface` | pass (initial viewport) | pending | pending |  |
| `advanced` | pass (initial viewport) | pending | pending |  |
| `graphics-video` | pass (initial viewport) | pending | pending |  |
| `graphics-enhancements` | pass (initial viewport) | pending | pending |  |
| `graphics-hacks` | pass (initial viewport) | pending | pending |  |
| `graphics-advanced` | pass (initial viewport) | pending | pending |  |
| `shaders` | pass (initial viewport) | pending | pending |  |
| `audio` | pass (initial viewport) | named backend option focus and Menu to sidebar pass | pending | picker names/help restored |
| `controllers` | pass (initial viewport) | pane Menu to sidebar passes | pending | shared header/inset restored |
| `privacy` | pass (initial viewport) | pending | pending |  |
| `about` | pass (initial viewport) | pending | pending |  |

## Library and pause coverage

Pending: empty/demo library; rail All/GameCube/Wii; search; scroll/index; context actions; settings entry/exit; pause grid; quick menu; saves; cheats; shaders; reset/exit confirmations. Demo/preview screenshots are UI evidence only and cannot prove real game/save behavior.

## Findings

### Reproduced: library rail loses accessible control names

Steps: launch the demo library, remote down to Wii and Select, up to GameCube and Select, up to All Games and Select, then Right into the content. Platform headers correctly update and content regains focus, but the collapsed rail's buttons lose their names. The baseline accessibility tree reports Settings as `gearshape.fill`, while Import/View menu wrappers have no button label even with their visible text. `app.buttons["All Games"]` no longer resolves after collapse.

Root cause: `TVLibraryRail.rowLabel` only includes `Text(title)` when expanded, and the control itself has no stable accessibility label. Fix: assign the supplied title to each rail Button. The baseline remote regression failed; the fixed build passes platform switching, content focus, and all eleven collapsed control names.

### Verified baseline behaviors

- Wii/GameCube/All Games rail selection updates the platform/count header.
- Right from the rail transfers focus to a game card and re-enables the content.
- Normal library → Settings → General pane → Menu to sidebar → Menu to library works.
- Performance CPU-engine Left and Right keep focus on the row; Menu returns to the selected sidebar page.
- These passing checks do not establish the complete screen, input, service or persistence matrix.

### Build slowdown fixed

`.bartycrouch.toml` used `path` instead of the supported `paths`. The baseline scanned at least 150 storyboards from dependency build folders. With `paths = ["DolphiniOS"]`, the actual tool scanned only the app's launch storyboard and finished in 2.871 seconds. Reference: [upstream configuration](https://github.com/FlineDev/BartyCrouch#configuration).

### Test infrastructure and limits

The native simulator keyboard route did not deliver reliable input in this session; that was not counted as an app failure. The standalone `Tools/tvos-ui-audit/` runner sends `XCUIRemote` events and saves screenshots/accessibility trees. Its menu and collapsed-label checks intentionally expose missing accessibility names on the baseline. The initial three-test baseline had one missing-label failure and two passing navigation tests; it is not a green suite.

During the audit, another session landed `34a95701c1`, moving shared packages to remote dependencies. The original runtime baseline predates that migration. Workspace regeneration produced a generic stat error with stale package state; resolution into `/tmp/icube-tvos-audit-2026-10-19/packages` succeeded. The migrated-head NJB Debug tvOS build succeeds; remote regression verification is in progress. Unrelated tracked iOS framework deletions were observed and are not part of this change.

### Reproduced: singleton iOS stepper crashes during rendering

Shader compiler-thread settings produce `1...1` on a reported processor count ≤2. `ValueStepper` constructed a SwiftUI Slider from that range. The new hosting-controller regression reproduces `SwiftUI/Slider.swift:638: Fatal error: max stride must be positive`; xcodebuild reports the test failed. This confirms the singleton-range lead associated with #50. It is an iOS control path; tvOS uses stepped buttons.

Local fix renders the formatted fixed value without constructing a Slider when the bounds are equal. The test also checks rendering does not write the binding. The same hosting/layout regression passes after the guard (direct xcresult confirms Passed); the broader fixed-source run passes80 targeted settings tests, exit 0 (`settings-direct-green.log`).

### Reproduced: Import, View and Sort cannot be reached by the remote

From the library, repeatedly press Down through the rail. Focus skips Import, View and Sort and lands on Settings. All three fail the remote focus regression. The controls were SwiftUI Menu instances, despite the existing tvOS toolbar fallback documenting that Menu has no usable presentation.

Local fix uses normal rail Buttons and the existing sheet route, adds Sort to that route, and styles the sheet with the app's tokens. Regressions cover opening each menu, focusing a real option, Menu dismissal with focus return, Done dismissal, and Import → Add Games. The migrated-head fixed build passes library/platform/content navigation and CPU persistence. The additional handoff test failed and showed the library after selection; its first expected label was also an iOS-only fixture. The old 0.35-second handoff is replaced locally by the sheet onDismiss callback and the tvOS fixture now checks “Upload over Wi-Fi”. This rerun remains pending. The run was interrupted before the complete menu suite finished; do not count it as green.

### Additional checks requiring triage

The existing design ratchet reports two hard-coded styles in `PauseCardFace.swift`; localization coverage reports eleven missing keys in pause/settings sources. Neither comes from these audit edits. Button ID mappings pass with the existing infrared-recenter warning.

The settings-wiring checker reports forty reset gaps, but its regex does not understand the existing `DeleteCirKeys` helper that resets CIR-prefixed settings. Do not treat all forty as product bugs. The remaining non-CIR keys (`GFX_HACK_BBOX_ENABLE`, `GFX_SAFE_TEXTURE_CACHE_COLOR_SAMPLES`, `MAIN_SLOT_B`) need a reset-policy/runtime check before filing confirmed defects.

A separate core/config read-path review confirms two exposed settings need follow-up under R2/#53: `GFX_HACK_GPU_EFB_PEEK_RESOLVE` has a bridge and a Graphics Hacks row promising GPU resolve/stall reduction, but no renderer consumer; `MAIN_CONFIRM_ON_STOP` has an Interface row, while the pause UI opens its confirmation unconditionally. These are source-confirmed wiring gaps; runtime correction/verification is pending. `MAIN_FP_FAST` is unused bridge/config residue with no visible row. Other lint findings include false positives: SYSCONF reads use a variant visitor, touch opacity/IR mode are frontend consumers, and the cheats consumer uses a qualified config name the regex misses. Missing bridge hooks and UserDefaults mismatches after adaptive-resolution removal: zero.

The initial combined settings-capture sweep stopped while terminating the shader screen. This does not establish a shader app crash. Captures are split into one test per leaf; correct sidebar title for graphics-advanced is “Graphics Advanced”, not the first fixture's “Advanced”.


## Earlier targeted rerun (before adaptive-resolution removal)

Latest NJB Debug source builds for iOS and tvOS. The rebuilt iOS bundle passes 80 targeted settings tests. The fresh installed tvOS app passes all three final remote tests: Import/View/Sort option focus and cancellation with original rail focus; Done and Import → Add Games secondary presentation/dismissal; real Settings pane/back/library return. Exit 0, `menu-final/results.xcresult` and `menu-final-console.log` under the session artifact root. The pending action now runs from sheet `onDismiss`, rather than a guessed 0.35-second delay.

Manually inspected captures: [Import](2026-10-19-tvos/import.png), [Sort](2026-10-19-tvos/sort.png), [Add Games](2026-10-19-tvos/add-games.png). The token styles render and Add Games displays its upload URL/QR and Running status; this does not verify actual file transfer. A remaining visual issue is visible in the menu captures: the focused row chrome reaches/clips against the ScrollView edges. Give the menu content room for the 1.04 focus scale/ring/glow and retest scrolled first/last rows. Functional remote passes do not close this visual polish gate.

Not run: complete per-leaf adjustment/persistence/reset matrix, final APPSTORE screen checks, physical remote/controller/VoiceOver coverage, real multi-device sync/sharing, saves and gameplay performance. No TestFlight publication or overall release-readiness claim.

## Post-removal UI sweep and visual review

The updated tvOS app passes all 25 standalone remote tests: 19 individual page captures and six library/menu/settings/persistence regressions, including absence of all five adaptive-resolution controls. Zero failures/skips, exit 0; `post-removal-ui/results.xcresult` and `post-removal-ui-summary.json`. This app build still embeds the prior tvOS core: these are UI results, not proof of backend removal. The final core/app artifact checks remain separate.

All 19 initial viewports were manually inspected; raw captures are in [settings/](2026-10-19-tvos/settings/). They show the expected detail panes, including Shaders. This does not cover each pane's full scroll extent or change/reset behavior; those table entries remain open. The refreshed Import and Sort captures show room around the focused row's scale/ring/glow, resolving the previously observed clipping at those positions. Sort's unfocused first row is partially outside the scrolled viewport; its focused Newest First row is fully visible.

Additional UI issues reproduced in the initial sweep (local follow-up fixes below):

- **User Folder remains unreadable in full on tvOS:** the Debug capture truncates the sandbox path before the complete installation UUID. Its disabled status row cannot gain focus for the help shelf and offers no detail/copy action. Restoring store visibility alone does not resolve this support-information UX. [Capture](2026-10-19-tvos/settings/settings-debug.png).
- **Audio loses picker context:** Audio Backend choices appear as separate rows without the Audio Backend title/help; Decoder Quality appears as unexplained Lowest/Low/High/Highest rows. `MenuScreen.tvRow` expands noncompact pickers into option-only rows, dropping the item's title/description. Preserve named, understandable choices and disabled-state behavior, then check selection/persistence. [Capture](2026-10-19-tvos/settings/settings-audio.png).
- **Controllers title has poor contrast:** the centered dark heading differs from the readable token headers on neighboring leaves. Correct and recheck the embedded controller hub's header in light/dark and with real input. [Capture](2026-10-19-tvos/settings/settings-controllers.png).

The iCloud capture correctly reports this ad-hoc simulator build is not signed for iCloud; it is not a Production-sync failure or acceptance result. Nearby discovery and stopped Web UI captures likewise do not establish actual transfers.

## Rebuilt core artifacts

All four packaged device/simulator variants pass the retired-content check. Fresh NJB Debug iOS and tvOS apps build successfully; their embedded and installed simulator cores also pass. [Verification hashes and test counts](2026-10-19-resolution-verification.json) preserve those results separately from pending shipping/device gates. The iOS fresh-core bundle passes 97 targeted settings tests. The final tvOS fresh-core rerun passes all three tests: Video has no adaptive-resolution controls, CPU-engine persistence/restoration, and Import/View/Sort option focus/cancellation. Zero failures/skips, exit 0; `tvos-fresh-core-rerun.xcresult`. The first direct rerun attempt had no reusable xctestrun metadata and executed no tests; it is not a product failure or a passing run.

## Settings context and support-details follow-up

Three new remote regressions fail against the installed baseline: Audio Backend/Decoder Quality names are absent, Controllers lacks the shared Settings subtitle/header, and User Folder cannot open because its row is disabled. The local fixes preserve picker title/help above the existing option buttons, use the shared Controllers header/inset with native navigation title limited to iOS, and turn a hydrated User Folder into a read-only details destination. Empty/unavailable paths remain disabled. Details show the complete path, with Copy on iOS and Done on tvOS; store environment-only scope still excludes recovery/developer actions.

The final targeted tvOS run passes all three tests, zero failures/skips, exit 0 (`settings-context-rerun.xcresult`): named Audio options and remote focus/Back; Controllers header and sidebar return; complete path visibility, Menu return to the invoking row, reopen and Done dismissal. The first post-fix run exposed two harness assumptions (directional focus starting below Audio's target, exact Done label despite its accessibility help); the corrected fixture targets the backend row and matches Done's full label. No additional product fix was needed for those two test failures.

Manually inspected fresh captures: [Audio](2026-10-19-tvos/settings-context/audio-named-choices.png), [Controllers](2026-10-19-tvos/settings-context/controllers-settings-header.png), [User Folder](2026-10-19-tvos/settings-context/user-folder-details.png). The full sandbox path is visible without truncation. Independent static review reports no actionable findings. NJB Debug iOS/tvOS builds pass. The full iOS unit suite passes 1,970 tests with zero failures and six opt-in snapshot tests skipped; [verification record](2026-10-19-settings-context-verification.json). The skipped cases are ICubeDesignSnapshotTests/testRenderPieces, PauseMenuSnapshotTests/testRenderPauseMenu, TopBarSnapshotTests/testRenderTopBar, and TouchOverlaySnapshotTests/testRenderArtStates, testRenderDefaultLayouts, testRenderFixtureSkin. They require explicit snapshot output-directory environment variables. Both rebuilt apps' embedded cores still pass the retired-resolution-content check. APPSTORE runtime, iOS clipboard interaction, device/physical-input and complete field persistence/reset gates remain open. The design-token checker still fails on the existing two PauseCardFace styles; localization coverage still reports eleven existing missing keys. No new findings from these edits.
