# Play controls and save history — TestFlight release

On October 21, 2026, **1.0.0 (1792554707)** was uploaded for both platforms, assigned to Internal, Patrons, Moderators, Friends and Family, and Public Website, and approved for Beta App Review. A fresh ASC read confirms internal and external `IN_BETA_TESTING`, with automatic notifications enabled. [TestFlight](https://testflight.apple.com/join/9ZEfnyMP).

App: `6752685822`, bundle `com.joemattiello.iCube`. Archived source: [`76d443d03dcc9af6a61ae9153a922fa2eb611c5a`](https://github.com/Provenance-Emu/iCube/commit/76d443d03dcc9af6a61ae9153a922fa2eb611c5a). No App Store release submission was made. Superseded archives `1792538716` were not uploaded.

| Platform | ASC build ID | Processing | Beta Review | External state |
|---|---|---|---|---|
| iOS | `2420879b-d848-4c8f-a798-e88576d992eb` | VALID | APPROVED | IN_BETA_TESTING |
| tvOS | `534f19e6-a1f4-47be-a8aa-f19951a7ebad` | VALID | APPROVED | IN_BETA_TESTING |

## Behavior

- Labeled toolbar with direct Pause, Save, Load and Saves. Standard portrait height is 72 points excluding safe area; targets are at least 44 points. Controller contains on-screen controls and the explicit Wii pointer options. Shaders has a text label.
- History is the default. Quick Save creates a unique state; ten unkept history states per game are retained. Classic slots, kept states and automatic resume are protected. The browser shows selection, occupancy, compatibility, timestamps and available thumbnails; selection alone never loads.
- Quick Load chooses the newest manual state, then automatic resume if no manual state exists. An incompatible newest state is surfaced rather than silently loading an older one. Modded sessions require explicit classic selection.
- Classic/modded Quick Save opens the browser retaining the selected slot, including empty slots. Explicit overwrite consent follows the captured session/path into the serialized save queue and the guarded bridge call. This intentionally adds a browser step for classic users.
- Mute applies actual runtime audio gain, replays after startup and restores the configured volume after fast-forward muting.

## Validation

Both Release (AppStore) archives and locally exported distribution IPAs pass version, platform, arm64, signature/team, app/core dSYM UUID, optimized SwiftUI compatibility and retired adaptive-resolution guards. Final apps and extensions have debugging disabled; final apps use Production CloudKit and the expected containers. Matching app and core symbols are present on Sentry (`provenance-emu/icube`).

Xcode initially signs archives for development; distribution signing occurs during export. The reviewed release runner exports with `destination=export`, `method=app-store-connect` and Production CloudKit, validates both final IPAs, then uploads those exact SHA256-pinned files using the installed altool's `--upload-package` interface. Provisioning profiles may authorize multiple environments; the signed app must still select Production. tvOS requires CloudKit and its expected containers while Xcode strips unsupported CloudDocuments. See Apple's [cloud-managed signing](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/), [upload tools](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and [tvOS cloud storage](https://developer-mdn.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/iCloudStorage.html) documentation.

| Package | SHA256 |
|---|---|
| ios | `b9d4cb4a108b1bac0aed5610a9bb3cb277db2309766ce4d2d52eb8df5ed9cdcf` |
| tvos | `7ad55647832c67943979cfbb4b198661f923e203de8177f026f1626003a018cb` |

The final full iOS suite reports **2,229 passed, five opt-in skips, zero failures (2,234 total)**. The final focused layout/cache run passes **38/38**. Native simulator checks pass **7/7 on iPhone 17 Pro, 7/7 on iPad Pro 12.9-inch, and 2/2 on Apple TV**, using iOS/tvOS 27. Standard portrait toolbar height is 72pt with primary targets at least 44pt. Final screenshots were inspected, including short landscape metadata, separate selection indicator, single save-browser heading and pinned actions. Native tvOS focus and Back pass.

Hosted XCTest [39538314157](https://github.com/Provenance-Emu/iCube/actions/runs/39538314157) ends with TEST SUCCEEDED on final product checkpoint `a0fbc29b80`; the later archived source commit changes only audit harness/docs. Source reviews are clean, including serialized overwrite consent, session drift, save failure/retention and live backend audio behavior. The manual hosted-runner override defaults false and preserves normal configuration and fork security.

Raw evidence remains under ignored `build/release-audit/2026-10-20-testflight-final/`: accepted xcresults, signed archives, final IPA guards/hashes, Sentry logs, upload acknowledgements, distribution logs, manifest and fresh ASC/build-beta-detail snapshots. The accepted result bundles use the `play-controls-*-accepted` names; focused results are `play-controls-selection-focused.xcresult`.

## Deferred physical checks and remaining release gates

The owner explicitly chose **“Test it later”** when asked for a physical device window. No further iPad automation was performed after that answer. DEV `1792552677` is installed as a data-preserving update and passed signature/SwiftUI/core checks. Fresh preflight confirmed enabled Exit confirmation, nonzero volume, default history mode and the six existing save files with zero history payloads. The first new-build physical run stopped at no-JIT button hittability before Exit was reached. A landscape/presentation-wait harness correction builds and preserves mandatory hittability; its runtime rerun is pending. This is not an Exit, audible mute or history save/load acceptance claim.

The prior [physical Exit/Cancel pass](2026-10-20-ipad-pause-confirmation.md) predates this toolbar. New-build Exit/Cancel, owner audible mute/unmute, and one disposable immutable-history save/load remain deferred. Production TestFlight and its paused game were not activated, terminated or modified by the audit. No existing save was deliberately overwritten or deleted.

This TestFlight release does not establish App Store readiness. Cross-device metadata/save/ROM convergence and Provenance receiver acceptance, older-device startup, live telemetry delivery and a matched Release performance comparison remain separate gates. The owner reports improved DEV performance; no measured FPS improvement is claimed.

A final-review Minor remains tracked: a late screenshot can recreate an orphan PNG after a history payload is pruned. This does not restore/delete a save payload or breach the ten-state retention count; thumbnail storage/transfer overhead needs later cleanup.

## Implementation rulings and costs

| Decision | Cost/tradeoff |
|---|---|
| Prepare independent toolbar work alongside history policy, serialize integration/SDK | Possible UI integration rework |
| Reuse the owner-authorized develop checkout | Less Git isolation; owned commits protect unrelated work |
| Require explicit classic selection for modded loads | Less quick-history convenience for mods |
| Use unique `.s01` history filenames accepted by current sync rules | Older clients may display the basename oddly |
| Open the browser for every implicit classic/modded Save | Extra browser step, including empty slots |
| Add a manual hosted CI override, default false | Hosted runner usage and workflow maintenance |
| Use compact thumbnail/metadata rows in short landscape | Denser layout than the large-card mockup |
| Defer nonblocking orphan-thumbnail cleanup | Possible thumbnail storage/transfer overhead |
| Validate local distribution exports and upload exact pinned IPAs | Extra export/validation time, disk use and helper maintenance |
