# iCube App Store submission (1.0) — design

Date: 2026-10-12. Status: draft for owner review.
Source audit: the read-only App Store readiness audit of 2026-10-12, summarised in §2. Paths are relative to `Source/iOS/App` unless they start with `docs/` or `Source/`.

## 1. Goal and decisions

Ship iCube 1.0 on the App Store for iPhone, iPad and Apple TV under one app record (`com.joemattiello.iCube`). It should be compliant with guideline 4.7 (retro game emulators) and launch with a polished store presence. Another developer appears to be preparing a JIT-less Dolphin app built on this work, so time matters. Scope still follows the owner's choice of a compliant **and** polished launch.

Owner decisions (2026-10-12):

| Topic | Decision |
|---|---|
| Scope | Compliant and polished: compliance fixes, finished store presence, iCloud sync provisioned, log clean-up. |
| Mechanism | Gate on the existing `APPSTORE` compilation condition (`Project/Config/AppStore.xcconfig`). Sideload, TestFlight and dev builds keep every feature; there is no separate target. |
| Wii System Update (downloads Nintendo firmware) | Compiled out of `APPSTORE` for 1.0, and may return in an update after review. Users supply their own NAND or system files instead, documented on the website, in the wiki and in in-app help. |
| Cheat downloads (rc24 code database) | Kept. Codes are user-applied text, not game content. |
| Crash reporting (Sentry) | On by default with an opt-out toggle. `game_id` is dropped in `APPSTORE`. Disclosed on the privacy label as crash and performance data, not linked to the user. |
| Box art | No GameCube, Wii or Nintendo logos. The logo-free cover templates exist (`GCCoverTemplate-NoLogo`, `WiiCoverTemplate-NoLogo`). |

## 2. Current state (audit, 2026-10-12)

Already in place:
- `Release (AppStore)` archives through the `iCube (AppStore)` scheme (`Scripts/release.sh:39-40`, `.github/workflows/testflight.yml:263-264`) with `ExportOptions-AppStore.plist`.
- JIT is hard-off under `APPSTORE`:
  - `Common/Jit/JitManager.m:65` sets `jitSupported = false`.
  - ptrace is disabled.
  - The boot path falls back to CachedInterpreter.
  - The StikDebug rows and the boot JIT prompt are hidden.
- No ROMs or BIOS are bundled. `Data/Sys` holds only open-source data.
- `APPSTORE` already selects the `-NoLogo` cover templates (`Common/Swift/LibraryPlatformCategory.swift:158-165`).
- The display name is "iCube". The About screen carries a trademark disclaimer (`AboutView.swift:144`).
- The extensions (Top Shelf, Thumbnail, Quick Look) each have a `PrivacyInfo.xcprivacy`.

Gaps, ranked by how likely they are to block review:
1. The debug HTTP server and the Settings → Debug leaf ship, and the toggle is user-visible:
   - `Common/Swift/Debug/*`, `DebugRootModelBuilder.swift:101-103` and `DebugServerManager.swift:111-154`.
   - Once on, the server accepts LAN clients and can write settings, boot games and load states.
2. There is no app-level `PrivacyInfo.xcprivacy`, although the app uses required-reason APIs (file timestamps, UserDefaults, probably disk space).
3. Sentry is always on, with no opt-out, and tags `game_id` (`Common/Services/SentryTelemetryService.swift:98-174`).
4. Wii System Update downloads Nintendo firmware (`WiiSystemUpdateViewController.mm:82-87`, `TVWiiSystemUpdateViewController.mm:161-164`).
5. `iCube AppStore.entitlements` carries the macOS `cs.*` keys (`allow-jit`, `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `disable-library-validation`, `allow-dyld-environment-variables`) and the deprecated `inter-app-audio`.
6. Camera use is unverified, and there is no `NSCameraUsageDescription`.
7. Dead JIT surface:
   - `acquireJitByAltServer` (`JitAcquisitionService.swift:15`);
   - `_altserver._tcp` in `NSBonjourServices`;
   - `stikdebug` and `stikjit` in `LSApplicationQueriesSchemes`;
   - bundled `Project/Assets/icube.js`.
8. The iCloud Sync UI ships, but the CloudKit entitlements are not applied (`docs/cloudkit-entitlements.patch`, staged) and the Production schema is not deployed.
9. Branding:
   - the launch screen says "GameCube & Wii emulator" (`en.lproj/LaunchScreen.strings:11`);
   - "Made for Nintendo 64" (`SkinStoreView.swift:165-173`);
   - the GameCube NoLogo template still has the purple "ONLY FOR" corner tab, which is GameCube box trade dress.
10. There are no review notes, store metadata or privacy-label answers.
11. About 198 `NSLog` and 121 `print(` calls are ungated.
12. The AppStore and Non-Jailbroken Release configs share one bundle ID.

## 3. Workstreams

Each workstream lists its outcome, the changes, and how it is verified. Code changes land on `develop` as reviewed commits (owner process: no PRs, no AI trailers). Every `APPSTORE` gate is checked with an archive of `Release (AppStore)` for iOS and tvOS, not only with Debug builds.

### WS1 — Compliance gates

Outcome: the App Store binary contains no debug server, no firmware downloader, no JIT plumbing, and no entitlement that claims JIT.
- Compile `Common/Swift/Debug/*` (server, routes, benchmark manager) and the Settings → Debug leaf out of `APPSTORE`. If the Debug leaf holds anything an App Store user needs (such as log export), that control moves to an App Store-safe leaf first.
  - Fix the stale "loopback-only" claims in `DebugServerManager` and `docs/dev/debug-api.md:19`.
- Compile Wii System Update (iOS and tvOS view controllers and their menu entries) out of `APPSTORE`.
- JIT leftovers in `APPSTORE`:
  - Remove the `acquireJitByAltServer` call path.
  - Remove `_altserver._tcp` and the `stikdebug`/`stikjit` query schemes, through an App Store Info.plist variant or build-setting substitution.
  - Exclude `icube.js` from the App Store resources.
  - Decide whether AltKit can be unlinked in `APPSTORE`. If not, leave it, since it is inert.
- `iCube AppStore.entitlements`: remove the `cs.*` keys and `inter-app-audio`. Keep `increased-memory-limit` and `extended-virtual-addressing` (both allowed on iOS). Re-check every remaining key against Apple's iOS/tvOS entitlement list.
- Camera: grep for `AVCaptureDevice`, `AVCaptureSession` and `VNDocumentCamera`. Add a usage string or remove the use.
- Bundle IDs: confirm App Store Connect only ever receives `Release (AppStore)` builds. Document that a sideload build signed with `com.joemattiello.iCube` must never be uploaded.

Verification:
- An `APPSTORE` archive builds for iOS and tvOS.
- `nm`/`strings` on the binary show no `DebugAPIRoutes` symbols and no `nus.cdn.shop.wii.com`-style firmware hosts.
- `codesign -d --entitlements -` on the exported `.ipa` shows the cleaned set.
- The Debug leaf is absent in a Release (AppStore) run on the simulator.

### WS2 — Privacy

Outcome: a privacy manifest Apple accepts, a user-facing opt-out, and written privacy-label answers.
- Add `DolphiniOS/PrivacyInfo.xcprivacy` (app target) declaring the required-reason APIs with their reason codes:
  - UserDefaults `CA92.1`;
  - file timestamps `C617.1`/`3B52.1` as applicable;
  - disk space `E174.1` if used;
  - system boot time `35F9.1` if used.

  Each one gets verified by grep before it is declared. No tracking, no tracking domains.
- Settings → Privacy → "Share crash reports", on by default. Sentry starts only when it is on. Turning it off at runtime closes the SDK, and turning it back on restarts it.
- Under `APPSTORE`, drop the `game_id` tag and any game title from Sentry events and breadcrumbs. Audit breadcrumbs for file paths that contain game names.
- `docs/app-store/privacy-label.md` records the App Store Connect answers. Data collected: crash data and performance data (diagnostics), not linked to identity and not used for tracking. List anything else WS2 finds, such as the iCloud data the user owns.

Verification:
- Xcode's privacy report (Organizer → Generate Privacy Report) on the archive.
- A unit test that the Sentry start gate honours the setting.
- A manual check that no event leaves the device with the toggle off (Sentry debug logging).

### WS3 — Branding and trade dress

Outcome: no Nintendo, GameCube or Wii marks or trade dress in the app's own artwork. Platform names appear only descriptively.
- Use the NoLogo templates in **every** configuration, so that website, store and debug screenshots match what ships. Delete the logo templates from the asset catalog.
- Repaint the GameCube NoLogo template's purple "ONLY FOR" corner tab.
- Reword:
  - the launch screen string (e.g. "iCube");
  - the "Made for Nintendo 64" skin copy;
  - the "Authentic Nintendo branding" code path at `GameGridItem.swift:309`, if it draws anything.
- Review every user-visible "Nintendo", "GameCube" and "Wii" string. Descriptive use ("GameCube games", document-type names) stays; anything implying endorsement goes.
- Keep the About trademark disclaimer and make sure it appears on the store description too.

Verification:
- A grep sweep, with the remaining hits listed and justified in the PR notes.
- A screenshot pass with `tvos_screens.sh` plus the iOS equivalent (WS6).

### WS4 — User-supplied firmware

Outcome: a user can install their own Wii NAND or system files on iPhone, iPad and Apple TV, and every help surface explains how.
- Verify the existing iOS NAND import (`showImportNANDPicker` in `TVLibraryView`). Find or build the tvOS path, most likely an upload through the Web UI and WebDAV server into the user folder, since tvOS has no document picker.
- Write the how-to once and publish it three times:
  - the website (`~/Workspace/Provenance/iCube/icube-emu.github.io`);
  - the wiki (`docs/wiki-seed/`);
  - in-app help.

  It covers dumping your own console's NAND, where files go, and how to verify.
- The App Store build's empty-state copy for Wii-only features points to that help page instead of the removed System Update.

Verification:
- On a device, import a NAND dump on iOS and on tvOS, then boot a title that needs it.
- Help links resolve.

### WS5 — iCloud sync for launch

Outcome: the shipping iCloud Sync works in the App Store build.
- Provision `iCloud.com.joemattiello.iCube` and apply `docs/cloudkit-entitlements.patch` to the AppStore entitlements and the extension entitlements as needed.
- Deploy the CloudKit schema to Production, then run a two-device sync test (iPhone and Apple TV) on a TestFlight build signed like the store build.
- If provisioning slips, the fallback is to hide the iCloud Sync leaf under `APPSTORE`; `CloudKitAvailability` already fails safe. WS5, WS7 and the preview video are the scope that can be cut late without blocking 1.0.

Verification: the device sync checklist from the CloudKit work, run on the store-signed build.

### WS6 — Store presence

Outcome: a complete App Store Connect listing for iOS and tvOS.
- **Screenshots:** iPhone 6.9", iPad 13", Apple TV 4K. Show only the app's own UI and the logo-free placeholder art: library, pause grid, Save States, controller hub, settings, shaders. No Nintendo game art or footage.
  - This set is separate from the website set, which may use real game IDs and covers (`docs/HANDOFF.md`).
  - Add iPhone and iPad capture scripts next to `Scripts/tvos_screens.sh`, using the `-ICube*` and `SCREENSHOT_MODE` hooks.
- **App preview video:** a UI walkthrough, plus gameplay only from homebrew or freely licensed titles, captured on the owner's devices.
- **Text:**
  - name, subtitle, description, keywords and promotional text;
  - the "user provides their own games" statement;
  - the trademark disclaimer;
  - support and privacy-policy URLs, hosted on the website.
- **Age rating questionnaire.**
- **Review notes** (`docs/app-store/review-notes.md`, pasted into App Store Connect):
  - guideline 4.7 compliance;
  - how a reviewer can test with a freely distributable homebrew title;
  - no JIT and no executable code download;
  - cheat codes are user-applied text;
  - the open-source licence (GPLv2) and source availability.

Verification: an App Store Connect completeness check, plus the owner's review of every screenshot and string.

### WS7 — Release-build polish

Outcome: release builds don't flood the console or leak game paths into logs.
- Route the ungated `NSLog` and `print(` calls through the existing logging (ICLog / `os_log`) with appropriate levels, or gate them on `DEBUG`. Start with the noisiest files (`GameFileCacheManager.mm`, `EmulationScreen`, `EmuEventVC`).

Verification: count calls before and after; run a Release log stream during boot.

### WS8 — Submission mechanics

Outcome: a repeatable path from `develop` to "Submitted for Review".
- Versioning: 1.0 (marketing) with monotonic builds, and how the TestFlight nightly and App Store builds share build numbers.
- Add an App Store channel to `Scripts/release.sh` and `testflight.yml`, or document a manual Xcode Organizer upload of a `Release (AppStore)` archive.
- Submission checklist (`docs/app-store/submission-checklist.md`): metadata frozen, privacy label, review notes, export compliance (standard encryption only), phased release, a rejection-response playbook.

## 4. Order and dependencies

1. WS1 and WS2 first. They are pure code, independent, and gate everything else, since every later screenshot and build must come from a compliant binary.
2. WS3 runs alongside them.
3. WS4 code can run alongside WS1–3. Its docs come after WS3's wording pass.
4. WS5 needs owner access to the Apple Developer portal and CloudKit Console; start provisioning immediately, because it has external lead time.
5. WS6 screenshots come after WS1–3, since they must show the compliant UI. The video needs owner device time.
6. WS7 can happen at any time and is the first to drop.
7. WS8 comes last.

Critical path: WS1 → WS3 → WS6 screenshots → WS8.

## 5. Out of scope

- JIT in any App Store build (impossible: no `get-task-allow`).
- Firmware download, until after 1.0 review.
- A separate App Store target or bundle ID.
- macOS and visionOS listings.
- Website screenshot refresh with real artwork (tracked in `docs/HANDOFF.md`, separate from the store set).

## 6. Risks

- **4.7 interpretation.** A reviewer may still question any network fetch. Cheats and skins stay, and are explained in the review notes; be ready to gate them in a resubmission.
- **Trademark.** Descriptive platform names are standard for approved emulators, but a reviewer can flag them. WS3 keeps them minimal.
- **Timeline vs polish.** WS5 and the video are the slowest. WS5 has the fallback in §3; the video can follow in a metadata-only update, since previews can be added without a new binary.
- **Shared bundle ID.** A sideload-signed upload by mistake would carry the wrong entitlements. WS8's checklist guards against it.
