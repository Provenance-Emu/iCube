# iCube 1.0 App Store submission checklist

Everything the agent could verify without a signed archive or a device is done; the rest is below. Work top to bottom. Texts and decisions live in the linked files; this page does not repeat them.

- [`metadata.md`](metadata.md): ASC text fields, URLs, owner decisions
- [`privacy-label.md`](privacy-label.md): privacy questionnaire answers and the OWNER confirmations
- [`review-notes.md`](review-notes.md): App Review notes (4000-character field)
- Plan and ledger: `docs/superpowers/plans/2026-10-12-app-store-submission.md`

Paths below are relative to the repo root. `ARCHIVE` is the `.xcarchive` of the build you submit; `APP="$ARCHIVE/Products/Applications/iCube.app"`. Run the archive checks for the iOS and the tvOS archive.

## 1. Code decisions (before the build)

- [ ] **iCloud Sync (Task 14).** Either provision it or hide it. Pick one.
  - Provision: create/confirm container `iCloud.com.joemattiello.iCube` and enable iCloud (CloudKit) on `com.joemattiello.iCube` plus the extension ids listed in `docs/cloudkit-entitlements.patch`. Apply the patch to `iCube AppStore.entitlements` and `DolphiniOS.entitlements`, and set `CloudKitAvailability.containerIsProvisioned = true` (`Source/iOS/PVCloudSync/Sources/PVCloudSync/CloudKitAvailability.swift`; the patch header says both are required). In CloudKit Console deploy the Development schema to Production. Two-device sync test (iPhone and Apple TV) on a TestFlight build. Use the iCloud line of the description in `metadata.md` (1855 characters).
  - Fallback if not done by submission day: wrap the `icloud` entry in `SettingsRootModelBuilder.sections` (`Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift:121`) in `#if !APPSTORE`. Commit `feat(appstore): hide iCloud Sync until provisioned`. Use the plain description.
- [ ] **Web UI/WebDAV server.** It starts by itself in the foreground with no switch and no password (`Common/Services/WebServerLifecycleService.swift`, `ROMUploadServer.swift`: "anonymous access"). Review notes say so. Decide: ship as is, or add a toggle/password first (see `review-notes.md` OWNER list).
- [ ] **RetroAchievements** ships in the store build (`USE_RETRO_ACHIEVEMENTS=1` in `Source/iOS/App/Project/Config/AppStore.xcconfig`). Confirm or exclude the Achievements settings from the iCloud file mirror (token is stored in `User/Config/*.ini`, `privacy-label.md`), and decide the User ID question there.
- [ ] **Sentry project setting:** turn on "Prevent Storing of IP Addresses" (`privacy-label.md`, item 2).
- [ ] **Footer wording** in `ConfigPrivacyModelBuilder.swift` ("never include") versus "designed to exclude" on the website: soften or accept (`privacy-label.md`, item 7).
- [ ] Optional small items from the ledger: Debug row text under the re-signed store build still mentions logging and metrics (`SettingsRootModelBuilder`); `DolphinSplashView` preview-only emoji text and the Live Activity preview sample ("Mario Kart Wii"/"Nintendo") are preview-only, not shipped.

## 2. Build

- [ ] The build comes from `Release (AppStore)`, uploaded by `.github/workflows/testflight.yml` (scheme `iCube (AppStore)`, `CURRENT_PROJECT_VERSION` = epoch seconds of the run). iOS and tvOS are separate matrix jobs.
  - Record version and build for each platform: iOS ____ / ____, tvOS ____ / ____ (`1.0.0`, build number from the `build=` job output or TestFlight).
  - From a local archive: `/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist"`.
- [ ] A local archive for the checks below, if the CI one is not at hand (needs signing): `cd Source/iOS/App && xcodebuild archive -workspace iCube.xcworkspace -scheme "iCube (AppStore)" -configuration "Release (AppStore)" -destination generic/platform=iOS -archivePath /tmp/iCube-ios.xcarchive` (and `generic/platform=tvOS`).

## 3. Archive checks (Tasks 1, 3, 4, 5; each needs a signed archive, not run headless)

- [ ] **Entitlements (Task 4).** Expect `0`:
  `codesign -d --entitlements - "$APP" 2>/dev/null | grep -c "cs\.\|inter-app\|get-task-allow"`
  (Source file already verified clean: `grep -c "cs\.\|inter-app" "Source/iOS/App/DolphiniOS/iCube AppStore.entitlements"` = 0.)
- [ ] **Private SecTask symbols not linked (Task 1).** Expect `0`, then `2` (the two `dlsym` name literals):
  `nm -u "$APP/iCube" | grep -ci sectask` and `strings -a "$APP/iCube" | grep -c SecTask`
- [ ] **Wii System Update absent (Task 3).** Expect `0` for each:
  `strings -a "$APP/iCube" | grep -c "Online System Update"`
  `strings -a "$APP/iCube" | grep -c "TVWiiSystemUpdate\|WiiSystemUpdateViewController"`
  `strings -a "$APP/iCube" | grep -c "Select Region"`
  Positive control, expect at least `1`: `strings -a "$APP/iCube" | grep -c "Install Wii System Files"`.
- [ ] **Privacy manifests present (Task 5).**
  `ls -l "$APP/PrivacyInfo.xcprivacy" "$APP/Frameworks/Sentry.framework/PrivacyInfo.xcprivacy"`
  `plutil -lint "$APP/PrivacyInfo.xcprivacy"`
- [ ] **Privacy report (Task 5).** Xcode > Window > Organizer > Archives > select the archive > right-click > **Generate Privacy Report**. Compare with `privacy-label.md`: collected types CrashData, PerformanceData, OtherDiagnosticData, all not linked, no tracking, no tracking domains.
- [ ] **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false` in the two app Info.plists (verified 2026-10-13 with PlistBuddy):
  `Source/iOS/App/DolphiniOS/Info.plist` (iOS) and `Source/iOS/App/DolphiniOS/Info-TV.plist` (tvOS; selected by `INFOPLIST_FILE[sdk=appletv*]` in `Source/iOS/App/Project.swift:399`).
  Re-check: `/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$APP/Info.plist"` prints `false`. With the key set, ASC does not ask the encryption question; if it does, answer "standard encryption only / exempt" (HTTPS and system crypto).

## 4. Device verification (owner; none of this is device-verified yet)

Use the App Store-config build on an iPhone and an Apple TV (TestFlight install = the "store" case).

- [ ] **JIT hidden (Task 1/2).** On a store/TestFlight install: Settings has no JIT/CPU-core options; the Debug row shows only the limited leaf; games run on the interpreter.
- [ ] **JIT present when re-signed.** A re-signed install, or an Xcode run of the `iCube (AppStore)` scheme (gets `get-task-allow`): JIT is detected and the settings appear. The old comment warned of a LuckTXM handshake crash when attached; confirm none.
- [ ] **Crash-report toggle (Tasks 6, 7).** Settings > Privacy > Share Crash Reports. Off: no traffic to `*.sentry.io` (Proxyman/mitmproxy or Network Link, relaunch included) and the footer text is the App Store version. On: reports flow again.
- [ ] **NAND upload on Apple TV (Task 8).** Web UI/WebDAV from a computer: (a) `keys.bin` (1024 bytes) first, snackbar "Wii keys received"; then `nand.bin` (0x21000000 bytes) imports. (b) `nand.bin` without keys is rejected up front and deleted. (c) Upload while a game runs is refused with "quit the game", file removed. (d) A dump with keys appended (553,649,152 bytes) imports alone. Also check the success heuristic on a real dump (certs written), and the alert shows on tvOS.
- [ ] **NAND-missing alert (Task 9).** Launch a Wii title on a library without a NAND: the alert offers the help button and it opens the "Install Wii System Files" page.
- [ ] **System menu row (Task 3).** Library > System > "Install Wii System Files..." opens the guide sheet on iOS and tvOS (Menu/Close dismisses); there is no "Online System Update" row.
- [ ] **Local Network prompt** at first launch (Web UI starts on foreground): acceptable text, app still usable if denied.
- [ ] **Homebrew test title** chosen for `review-notes.md` boots from a clean install with no Wii system files.
- [ ] **iPhone/iPad pause screenshots** (the simulator has no iOS pause hook): capture on device if you want them in the iOS set (Task 12).
- [ ] If iCloud ships: the two-device sync test from section 1.

## 5. Website and art (owner)

- [ ] Deploy website branches before submitting (`~/Workspace/Provenance/iCube/icube-emu.github.io`, unpushed): `docs/privacy-crash-reports` (privacy policy) and `docs/wii-system-files` (guide cited in review notes). Then `curl -sI https://icube-emu.com/privacy/` and `.../guide/wii-system-files/` return 200 with the new content.
- [ ] Marketing and Support URLs land on sideload/JIT pages: add an App Store landing page or edit the lines listed in `metadata.md` ("OWNER: the marketing and support URLs...").
- [ ] Stale website copy: `DownloadSection.tsx:80` "Plus purchases apply to the App Store build"; `Features.tsx:114` "JIT Recompiler on iOS 26" tile. `UpdateRequiredNoticeViewController` links `dolphinios.oatmealdome.me`: check it is unreachable or harmless in the store build.
- [ ] Approve the art: Task 10 NoLogo icon/splash (before/after was sent; the GC template's black curved band may read as trade dress) and the Task 12 screenshot set in `docs/app-store/screenshots/` (untracked: iphone-6.9, ipad-13, appletv). A Release-config shader shot is optional (the briefed Shaders page shows a DEBUG-only section in Debug).
- [ ] Preview video (Task 15, owner): 15 to 30 s UI walkthrough per platform, gameplay only from a homebrew or freely licensed title, in `docs/app-store/video/` (untracked).

## 6. App Store Connect

- [ ] **Metadata pasted** (Task 13): name, subtitle, promo text, keywords, description, URLs, copyright, category from `metadata.md`. Counts verified: 5/22/155/95/1764 (1855 with iCloud line).
- [ ] **App Review notes** pasted from `review-notes.md`, with the test-title line filled and the total under 4000 characters (3935 with the placeholder). Review contact filled (name, phone, `git@joemattiello.com`).
- [ ] **Privacy label** answered per `privacy-label.md` (Diagnostics: Crash Data, Performance Data, Other Diagnostic Data; not linked; no tracking; purpose App Functionality). Resolve its OWNER confirmations first (not linked despite Sentry's per-install ID, breadcrumbs, RetroAchievements). Privacy Policy URL set.
- [ ] **Age rating** questionnaire answered (expect 4+; the app ships no content, user-generated content: none; keep answers consistent with the review notes).
- [ ] **Export compliance** as in section 3 (`ITSAppUsesNonExemptEncryption` = false in both Info.plists).
- [ ] Price, category (Entertainment suggested), copyright holder confirmed.
- [ ] **Phased release on.**
- [ ] Select the build for the iOS and the tvOS versions, attach screenshots and video, submit for review.
- [ ] Log the submission date and build numbers in `docs/HANDOFF.md`.

## 7. Rejection playbook: what to gate first if asked

Everything is `#if APPSTORE` (Swift and ObjC) via `Source/iOS/App/Project/Config/AppStore.xcconfig`; sideload builds keep it. Gate, commit `fix(appstore): ...`, push a new build through TestFlight, reply in Resolution Center.

1. **Cheats (Gecko codes fetch).** `Source/iOS/App/Common/Swift/CheatsMenuView.swift` fetches from `codes.rc24.xyz` when the pane opens (`downloadCheats()` via the auto-fetch guard near line 208; fetch code in `Source/Core/Core/GeckoCodeConfig.cpp:21`). Gate the auto-fetch first, or hide the pane entry in `PauseMenuView.swift:136` and `TVLibraryView.swift:2018`.
2. **Skins.** The Skin Store downloads skin archives from `provenance-emu.com`: `Common/UI/Settings/SwiftUI/SkinStoreView.swift`, opened from `SkinPickerView.swift:89`, backed by `DolphiniOS/UI/Emulation/Skins/Store/SkinCatalogService.swift`. Gate the store entry (keep local import of skins).
3. **Web UI/WebDAV server.** Starts unprompted in the foreground, no password. Gate it behind a user toggle or password: `Common/Services/WebServerLifecycleService.swift`, `Source/iOS/PVWebServer/Sources/PVWebServer/WebServerLifecyclePolicy.swift`, settings page `WebUISettingsView` (row id `web-ui`, `SettingsRootModelBuilder.swift:120`). Note tvOS NAND import depends on it (Task 8); iOS has the file picker.
4. **RetroAchievements.** Remove `USE_RETRO_ACHIEVEMENTS=1` from `Source/iOS/App/Project/Config/AppStore.xcconfig` (store builds only), and hide the Achievements settings.
5. **Crash reporting.** If the privacy answers draw questions: set the default consent to off for `APPSTORE` in `Common/Services/TelemetryConsent.swift` (Settings > Privacy toggle stays).
6. **If the reviewer sees JIT code in a `strings` scan.** Answer with the review-notes wording (inactive, hidden unless re-signed). Do not claim "no JIT code".
