# Performance controls and Quick Save/Load handoff — October 21, 2026

**Status:** approved design implemented; final iOS/tvOS Simulator SDK builds and full iOS native suite pass. Rendered tvOS navigation, preference and live-layout checks pass. Physical-device acceptance remains deferred by the owner. These are Debug simulator results, not a new distribution build or TestFlight upload.

## Behavior

Quick Save/Load claims separate operation and awaiting-input pause holds before dismissing Pause. The admitted operation survives intentional dismissal but remains bound to its original game/session. Checked native loading returns actual deserialization success after its CPU guard restores the prior paused state. Completion releases the operation hold; a complete neutral sample followed by fresh gameplay input releases only the awaiting-input hold. Held/early input, navigation controls, other presentations and foreign pause holders cannot resume it. Classic-slot replacement still requires destination-specific consent. Closing Back/Menu presses retain their press origin through release, preventing duplicate GCController/UIKit delivery from reopening Pause.

Actual touch contacts on the common legacy/hosted/skinned control ancestor participate in the hold. Begin/end/cancel and subtree teardown are scoped to the affected contacts. Skin app actions and motion-axis updates cannot activate resume. Simultaneous contacts are all registered before one activation notification, so a gameplay finger cannot race a skin-menu finger. Physical-profile-only controllers use the existing normalized controller adapter for activation and navigation; raw physical profiles remain the source of full neutrality.

**Performance** occupies the primary Pause position beside Resume. Save States follows Quick Save and Quick Load. The full paused pane, existing iOS popover and optional tvOS Live Performance panel share one state/controller/action backend: CPU/VI override and 1–400% values, Adaptive Clock, VI Skip, resolution, anisotropy and HUD statistics. Base values remain separate from Game/Auto ownership, with disabled explanations and guarded writes. Adaptive ownership reconciles delayed clears. Resolution zero reads **Fit Window**; no continuously changing internal-resolution controller returns. CPU Engine remains next-launch.

The installation-local Siri Remote preference defaults to **Pause Menu**. **Live Performance** is opt-in and requires a gameplay pad; otherwise it falls back to Pause. The transparent live panel takes no pause claim or native focus, polls only its exact remote, and suppresses that remote's native buttons/axes/motion through a lease. A gameplay pad continues operating the game. Closing retains suppression until neutral; disconnect retires the exact identity. Live-to-Pause and last-pad recovery acquire/adopt pause ownership before closing Live. Real simultaneous hardware behavior remains an acceptance gate.

## Verification

| Check | Final result / local evidence |
| --- | --- |
| iOS Simulator build-for-testing | Pass, Xcode 27.1; `build/dev-loop/performance-ios-build-6.json` |
| tvOS Simulator app build | Pass; `build/dev-loop/performance-tvos-build-3.json` |
| Full native iOS suite | **2,289 passed, seven opt-in skips, zero failures**; 2,296 total; `performance-full-173326.json` / `.xcresult` |
| Actual native controller wrappers / lease bridge | Five tests pass, including motion, physical fallback, refresh, nested release and stale-lease disconnect protection |
| Native fresh-input regressions | Five tests pass: profile-only normalized input/navigation, legacy/hosted contact ownership, both mixed-begin orders, scoped removal and non-gameplay/motion exclusion |
| Focused native suite before final touch additions | 114/114 pass; `performance-focused-170722.json` |
| Host production seams | Navigation 6, shared Performance 14, Live ownership 7 pass; frozen pre-fix handoff traps as expected and updated handoff passes; final contact-scope compile/run passes (`handoff-final-green.json`) |
| Embedded engines | Both rebuilt simulator slices export the required APIs; each app has the same UUID and all **29 file-backed sections** byte-identical to its corresponding rebuilt slice |
| Installed tvOS DEV payload | All **3,531 files** match the built product; `performance-tv-installed-proof.json` |
| Rendered / native tvOS follow-up | Pass: main tile/open pane, explicit choice cancellation/Back/reopen, preference persistence/default restore, and final live rendering |

The final typography-only change is guarded by `#if os(tvOS)`; tvOS was rebuilt and captured again, with iOS compiled behavior unchanged.

The full suite's first run found only an obsolete test expectation that Performance opened no page. That two-line expectation now matches the approved full-pane behavior; the final entire suite passes. Source review found and corrected touch-subtree coverage, normalized controller sampling and atomic mixed-contact admission. Final scoped review is clear.

Engine proof: iOS UUID `3773FA08-01BD-3470-8672-B989F22EA049`; tvOS UUID `F0F8A1D1-95AF-3664-823B-9C388B8CE6D2`. Exports include `LoadAsAndWait`, `GetInputGate`, `DisconnectInputGate` and `AreControlsNeutral`. Embedding strips/signs binaries, so whole-file hashes differ; UUID and all file-backed-section comparisons establish the copied code/data identity. See `performance-{ios,tvos}-embedded-proof.json`. Raw engine hashes and exports are in `performance-engine-proof.json`.

Native UI tests use the reusable actions runner with `--existing-dev`, which explicitly disclaims its own freshness verification. The separate full installed-payload comparison above supplies that evidence. No accepted-engine guard was silently bypassed. The SDK products and simulator engines include the workspace's concurrent locale work; those files and generated frameworks remain outside this change's owned commit. This does not establish a clean distribution-artifact provenance. Device engine slices still require rebuilding before device/distribution packaging.

## Rendered acceptance

Native remote checks pass: Resume → Right → Performance opens the full pane; VI Skip and resolution choices open explicitly, browsing/cancelling preserves values, Back restores the Performance tile, and reopening works. The Siri Remote preference selects Live Performance, survives relaunch, then restores Pause Menu and survives another relaunch. Final source review is clear.

Local run records: main pane `runs/20261021-173553-1ee2ca51`; choice/Back `runs/20261021-173825-e0835eb1`; preference `runs/20261021-174233-986534dd`; final Live rendering `runs/20261021-174354-0c3a6776`. All are under `build/dev-loop/`. An initial choice assertion matched both a heading and a scroll view sharing the propagated SwiftUI identifier; selecting the heading type removed that harness ambiguity and the flow then passed.

Visual inspection confirms readable disabled reasons and choice rows. The initial live capture looked too small for TV; the final panel uses 24pt rows, 28pt heading, larger hints and an 820pt width while keeping six rows and transparency. That TV-only app rebuild took **25.742 seconds**. Final capture: `runs/20261021-174441-fede1267/screen.png`; paused capture: `runs/20261021-173620-886a2c85/screen.png`. [Local live preview](http://127.0.0.1:4996/?token=54208555a6b848978ad7c81d1accf130). The live fixture is labeled **Rendering preview — no game or controller running** and uses injected read-only values: it verifies layout only, never gameplay or controller routing.

## Remaining release gates

- With a disposable real game/session, verify successful load/state contents, no advancing frames while held, fresh input resumption and no Back-release reopen. Preserve real saves.
- On real tvOS, verify remote tuning while gameplay advances and the pad still plays, held-input release, disconnect/recovery, background/external Pause and Live-to-Pause transfer.
- Physical iPad Exit/Cancel, audible mute, real touch delivery and disposable history checks remain deferred under the owner's “Test it later” instruction.
- Complete installed ROM/metadata/save convergence across iCube installs and Provenance receiver acceptance; ROM copy alone is insufficient.
- Finish both-platform non-default indicators, per-setting/group reset and safe recovery/undo or profiles; retain the audited distinctions for arbitrary locale defaults.
- Matched optimized Release performance, older-OS startup and live telemetry delivery remain tracked separately.
- Rebuild device engine slices and perform optimized distribution acceptance before a new TestFlight package. No App Store submission is implied.

## Review ruling

One additional narrow correction/review was taken after the planned final fix wave because its new simultaneous-touch ordering race could violate the fresh-input guarantee. Leaving that load-bearing race was unacceptable; the cost was another scoped review and cached SDK pass. Both contact orders now have a passing native regression.
