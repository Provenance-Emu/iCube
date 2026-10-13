# iCube App Store submission 1.0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `Release (AppStore)` build of iCube compliant with App Store Review guideline 4.7 and ready to submit for iPhone, iPad and Apple TV, with a polished store listing.

**Architecture:** Every change is gated on the existing `APPSTORE` compilation condition (`Source/iOS/App/Project/Config/AppStore.xcconfig`). Sideload, TestFlight and dev builds keep every feature. The App Store binary drops the developer-only surfaces, detects JIT at runtime instead of hard-disabling it, ships a privacy manifest and a crash-report opt-out, and uses logo-free art. Work that is not code (iCloud provisioning, store metadata, video, submission) appears as checklist tasks with named outputs.

**Tech Stack:** Swift/SwiftUI and ObjC++ (iOS 17 / tvOS 17), Tuist 4 (`Source/iOS/App/Project.swift`), XCTest (`iCubeTests`, iOS simulator only), Sentry Cocoa SDK, App Store Connect.

**Spec:** `docs/superpowers/specs/2026-10-12-app-store-submission-design.md`

## Global Constraints

- One app record, bundle id `com.joemattiello.iCube`. Only `Release (AppStore)` archives (scheme `iCube (AppStore)`) are ever uploaded to App Store Connect.
- Gate with `#if APPSTORE` in Swift and `#if APPSTORE` in ObjC/C++. Both are already defined by `AppStore.xcconfig` (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` / `GCC_PREPROCESSOR_DEFINITIONS`). Never add a new target or configuration.
- **JIT:** keep it in the App Store binary, detected at runtime, and show every JIT surface only when detection succeeds (spec §1; memory `icube-appstore-jit-detect-hide`). Never strip JIT code.
- **Wii System Update:** compiled out of `APPSTORE` for 1.0. **Cheat downloads stay.**
- **Sentry:** on by default with an opt-out. Under `APPSTORE` no `game_id` leaves the device.
- **Art:** no GameCube, Wii or Nintendo logos or box trade dress anywhere (all configurations).
- **Commits:** conventional commits, no AI or LLM trailers, explicit paths only (never `git add -A` or `git add Source` in the main checkout). Run `git checkout -- build/xcframework` after every local app build, before committing.
- **New source or test files:** run `cd Source/iOS/App && tuist generate --no-open` before building, or they are silently missing.
- **Gates:**
  - A local tvOS and iOS build of the configuration you touched.
  - `make test` for unit tests.
  - `cd Source/iOS/App && make gate-release` before any push that touches `#if` blocks.
  - **Every `APPSTORE` gate is also verified by building `Release (AppStore)`:**
    `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (AppStore)" -configuration "Release (AppStore)" -destination generic/platform=iOS|tvOS -derivedDataPath build-Xcode-appstore CODE_SIGNING_ALLOWED=NO`
- **Strings:**
  - Every new `L("…")` key goes into both `Common/UI/Localization/en.lproj/Core.strings` and `ja.lproj/Core.strings`, as `"key" = "key";`.
  - `python3 Project/Scripts/check_localized_keys.py --check` and `python3 Project/Scripts/check_design_tokens.py --check` must pass.

## Review Focus

1. **A normal App Store install must show no JIT UI**, while a re-signed install of the same IPA must show it and acquire JIT. Task 1 has a device test for each case.
2. **Turning crash reporting off must stop all events at once,** including those already queued for that session and those from extensions. Task 6's unit test plus a device log check.
3. **A user with no NAND** who opens a Wii-only feature on the App Store build must be pointed to the "Install your own Wii system files" help, never to a dead System Update button. Covered by Tasks 3 and 9.
4. **Uploading a file named `nand.bin` that is not a NAND dump** (wrong size, or a renamed ISO) must not start a NAND import or delete anything. Covered by Task 8's classifier tests.
5. **A Debug (AppStore) or Release (AppStore) build must still compile on tvOS** after every gate: the iOS-only `#if os(iOS)` blocks interleave with `APPSTORE`. Every task's verification builds both platforms.

---

## Part A — Compliance code (WS1)

### Task 1: JIT detect-and-hide in the App Store build

The App Store build hard-disables JIT. Replace that with the runtime detection the other builds already use, so a re-signed install of the App Store IPA gets JIT back while a normal install keeps it hidden.

**Files:**
- Modify: `Source/iOS/App/Common/Jit/JitManager.m:65-69`
- Modify: `Source/iOS/App/Common/Jit/JitManager+PTrace.m:13`, `:31-32`

**Interfaces:**
- Produces: unchanged API. `JitManager.shared().jitSupported` is now `checkIfProcessIsJitCapable` (`csops & CS_GET_TASK_ALLOW`, `JitManager+Debugger.m:37-44`) in every configuration.

- [ ] **Step 1: Remove the hard-off in `JitManager.m`**

Replace lines 65-69:
```objc
#if APPSTORE
    self.jitSupported = false;
#else
    self.jitSupported = [self checkIfProcessIsJitCapable];
#endif
```
with:
```objc
    // Every configuration, the App Store one included: the same IPA can be re-signed with get-task-allow
    // (sideload, LiveContainer, Xcode) and must get JIT then. A store install has no get-task-allow, so this is
    // false there and every JIT surface (boot prompt, Debug leaf, StikDebug) stays hidden.
    self.jitSupported = [self checkIfProcessIsJitCapable];
```

- [ ] **Step 2: Let the PTrace path decide at runtime as well**

In `JitManager+PTrace.m`:
- Change line 13 `#if !TARGET_OS_MACCATALYST && !APPSTORE` to `#if !TARGET_OS_MACCATALYST`.
- Delete the `#if APPSTORE` / `return false;` / `#else` at lines 31-32 and its matching `#endif`.

`checkCanAcquireJitByPTrace` already returns true only for a `platform-application` binary (a jailbreak or TrollStore), which a store install never is.

- [ ] **Step 3: Build Release (AppStore) for iOS and tvOS**

Run the `Release (AppStore)` build command from Global Constraints for `generic/platform=iOS` and `generic/platform=tvOS`.
Expected: `** BUILD SUCCEEDED **` twice. `grep ": error:"` on the logs is empty. The `SecTask*` declarations on line 13 now compile for APPSTORE and must not clash.

- [ ] **Step 4: Device verification (owner device)**

a. Install the current TestFlight (App Store-signed) build on the iPhone. Open Settings: the Debug leaf (after Task 2) and any JIT row are absent. Boot a game: no "Waiting for JIT" alert.
b. Export a `Release (AppStore)` IPA and install it with get-task-allow through SideStore, LiveContainer or Xcode. Settings → Debug shows the JIT section. Enabling JIT via StikDebug acquires JIT (the badge reads acquired) and the pause chip reads "JIT ON".
Record both results in `docs/HANDOFF.md`.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Jit/JitManager.m "Source/iOS/App/Common/Jit/JitManager+PTrace.m"
git commit -m "fix(jit): App Store build detects JIT instead of hard-disabling it"
```

### Task 2: Debug leaf and bench server out of the App Store build

The Debug leaf and its developer tools (including the LAN bench server) must not reach App Store users. A re-signed install that has JIT still needs the leaf's JIT section, so that section alone survives under `APPSTORE`.

**Files:**
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/DebugRootModelBuilder.swift:12-17`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift:48`, `:112-114`
- Modify: `Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift:15-18`, `:150-156`
- Modify: `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift:12-15` (comment only)
- Modify: `docs/dev/debug-api.md:19`
- Test: `Source/iOS/App/DolphiniOSTests/DebugRootModelBuilderTests.swift`, `SettingsRootModelBuilderTests.swift`

**Interfaces:**
- Produces:
  - `enum DebugLeafScope { case full, jitOnly }`
  - `DebugRootModelBuilder.make(state:scope:apply:)`, where `scope` defaults to `.full`
  - `SettingsRootModelBuilder.sections(isIOS:achievements:debugLeaf:)`, where `debugLeaf: DebugLeafScope?` defaults to `.full` and nil means no Debug leaf
  - `static var SettingsRootModelBuilder.storeDebugLeaf: DebugLeafScope?`, which the views pass in

- [ ] **Step 1: Write the failing tests**

Append to `DebugRootModelBuilderTests`:
```swift
  func test_jitOnlyScope_keepsOnlyTheEnvironmentSection() {
    let model = DebugRootModelBuilder.make(state: populated, scope: .jitOnly) { _ in }
    XCTAssertEqual(model.sections.map(\.id), ["environment"])
    let ids = model.sections.flatMap(\.items).map(\.id)
    XCTAssertFalse(ids.contains("perf-bench"))
    XCTAssertFalse(ids.contains("console-logging"))
  }
```
These ids are the real ones: section `environment` (line 80), toggles `perf-bench` (line 101) and `console-logging` (line 130).

Append to `SettingsRootModelBuilderTests`:
```swift
  func test_debugLeafNil_omitsTheDebugEntry() {
    let ids = SettingsRootModelBuilder.sections(isIOS: true, achievements: false, debugLeaf: nil).flatMap(\.entries).map(\.id)
    XCTAssertFalse(ids.contains("debug"))
    XCTAssertTrue(ids.contains("performance-tuning"))
  }

  func test_debugLeafJitOnly_keepsTheEntry() {
    let ids = SettingsRootModelBuilder.sections(isIOS: true, achievements: false, debugLeaf: .jitOnly).flatMap(\.entries).map(\.id)
    XCTAssertTrue(ids.contains("debug"))
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Source/iOS/App && make test TEST_ARGS="-only-testing:iCubeTests/DebugRootModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests"`
Expected: compile failure, because `scope:` and `debugLeaf:` don't exist yet.

- [ ] **Step 3: Implement the scope**

In `DebugRootModelBuilder.swift`, above `enum DebugRootModelBuilder`:
```swift
/// How much of the Debug leaf a build shows. The App Store build shows only the JIT section, and only when JIT is
/// possible (a re-signed install); developer tools (bench server, logging, metrics) never reach store users.
enum DebugLeafScope {
  case full, jitOnly
}
```
Replace `make` (lines 12-17):
```swift
  static func make(state: DebugRootState, scope: DebugLeafScope = .full, apply: @escaping Apply) -> MenuModel {
    if scope == .jitOnly {
      return MenuModel(sections: [environment(state, apply)].filter { !$0.items.isEmpty })
    }
    var sections = [cpuMemory(state, apply)]
    if state.isIOS { sections.append(recording(state, apply)) }
    sections += [environment(state, apply), diagnostics(state, apply), rendering(state, apply), logging(state, apply), artwork(state, apply)]
    return MenuModel(sections: sections.filter { !$0.items.isEmpty })
  }
```

In `SettingsRootModelBuilder.swift`, change the signature to `static func sections(isIOS: Bool, achievements: Bool, debugLeaf: DebugLeafScope? = .full) -> [SettingsRootSection]`. Replace the debug entry (lines 112-114) so it is appended only when `debugLeaf` is non-nil, passing `scope: debugLeaf` to `DebugRootModelBuilder.make` and to `DebugRootView`. Read `DebugRootView.swift:8-40`: `DebugRootView` builds its own model, so add `var scope: DebugLeafScope = .full` to it and pass it to its `make` call. Build the performance section's entries as a `var` array, then `if let debugLeaf { entries.append(...) }`.

Add:
```swift
  /// What this build shows: the App Store build hides the leaf unless JIT is detected (a re-signed install).
  static var storeDebugLeaf: DebugLeafScope? {
    #if APPSTORE
    JitManager.shared().jitSupported ? .jitOnly : nil
    #else
    .full
    #endif
  }
```
and pass `debugLeaf: storeDebugLeaf` in `SettingsRootView.makeSections()` (`SettingsRootView.swift`, `makeSections`) and in any other production caller (`grep -rn "SettingsRootModelBuilder.sections(" Common`).

- [ ] **Step 4: Bench server off in APPSTORE**

In `DebugServerManager.swift`, replace `isEnabled` (lines 150-156) with:
```swift
  private var isEnabled: Bool {
    #if APPSTORE
    // The App Store build never runs the bench server; the Debug leaf that toggles it is not shown there.
    return false
    #elseif DEBUG
    return true
    #else
    return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    #endif
  }
```
Rewrite the header comment (lines 15-18):
```swift
// Bench/debug server. DEBUG builds start it on loopback (USB `iproxy 8723 8723`). Release sideload builds start it
// only after the user turns on Settings → Debug → Perf Test Bench, and then accept LAN clients that present the
// bearer token (`allowsNonLoopbackClients`). The App Store build never starts it (`isEnabled`).
```
Make the same correction to `NativeWebServer.swift:12-15` (loopback by default, LAN only on explicit opt-in) and `docs/dev/debug-api.md:19`.

- [ ] **Step 5: Run tests, then build AppStore for both platforms**

Run the Step 2 command. Expected: PASS.
Run the `Release (AppStore)` builds for iOS and tvOS. Expected: SUCCEEDED.
On the Debug (AppStore) simulator build, open Settings: the Debug row is absent unless the simulator process has get-task-allow (it usually does, as an ad-hoc simulator build). Check the device in Task 1 Step 4 instead.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/DebugRootModelBuilder.swift Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/DebugRootView.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift docs/dev/debug-api.md Source/iOS/App/DolphiniOSTests/DebugRootModelBuilderTests.swift Source/iOS/App/DolphiniOSTests/SettingsRootModelBuilderTests.swift
git commit -m "feat(appstore): Debug leaf shows only the JIT section, and only when JIT is detected"
```

### Task 3: Wii System Update out of the App Store build

Downloading Nintendo firmware is the largest 4.7 and IP risk, so the App Store build drops the entry points and replaces them with a help link.

**Files:**
- Modify: `Source/iOS/App/Common/Swift/TVLibraryView.swift:1625-1632` (System menu buttons), `:1960-1964` (region dialog)
- Modify: `Source/iOS/App/Common/UI/SoftwareList/TVLibraryBridge.mm:180-220`

- [ ] **Step 1: Hide the menu entry**

Wrap both the tvOS `Button` (1625-1629) and the iOS `Button` (1630-1632) in `#if !APPSTORE … #endif`. In the `#else` of that new block, add a row that opens the firmware help page (`WikiConstants.Paths.wiiSystemFiles`, created in Task 9):
```swift
#if !APPSTORE
      // (existing tvOS / iOS System Update buttons, unchanged)
#else
      Button(action: { libraryMenuAction { showWiiSystemFilesHelp = true } }) {
        Label(L("Install Wii System Files…"), systemImage: "questionmark.circle")
      }
#endif
```
Add `@State private var showWiiSystemFilesHelp = false` next to `showUpdateRegions`, and a `.sheet(isPresented: $showWiiSystemFilesHelp) { NavigationStack { WikiPageView(path: WikiConstants.Paths.wiiSystemFiles, title: L("Install Wii System Files")) } }` next to the region `confirmationDialog`. If `libraryMenuAction` is tvOS-only, use the same pattern as the line-1630 iOS button for iOS. Read lines 1600-1640 first and match them.

- [ ] **Step 2: Guard the bridge**

In `TVLibraryBridge.mm`, wrap the bodies of `presentUpdateControllerWithRegion:`, `performOnlineSystemUpdate` and `performOnlineSystemUpdateWithRegion:` in `#if !APPSTORE … #endif`, leaving empty bodies under `APPSTORE`. That way no other caller, such as a deep link, can reach the downloader.

- [ ] **Step 3: Strings**

Add `"Install Wii System Files…"` and `"Install Wii System Files"` to en and ja `Core.strings`. Run `check_localized_keys.py --check`.

- [ ] **Step 4: Build both configurations on both platforms**

Run `Debug (Non-Jailbroken)` for tvOS (the System Update entry still present) and `Release (AppStore)` for iOS and tvOS. Expected: SUCCEEDED. Then `strings` the AppStore binary: `strings build-Xcode-appstore/Build/Products/*/iCube.app/iCube | grep -c "Online System Update"` should return 0 for the menu label (the `L` key string may still appear in the strings files, which is fine).

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/TVLibraryView.swift Source/iOS/App/Common/UI/SoftwareList/TVLibraryBridge.mm Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "feat(appstore): no Wii online system update; point to installing your own files"
```

### Task 4: App Store entitlements

Remove the macOS-only and deprecated keys from the App Store entitlements so the shipped binary claims no JIT entitlement.

**Files:**
- Modify: `Source/iOS/App/DolphiniOS/iCube AppStore.entitlements`

- [ ] **Step 1: Remove the keys**

Delete these keys and their `<true/>`:
- `com.apple.security.cs.allow-dyld-environment-variables`
- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-executable-page-protection`
- `com.apple.security.cs.disable-library-validation`
- `inter-app-audio`

Keep all the others. They are sandbox, app group, asset/file read-only, network, device and photos keys, plus `extended-virtual-addressing` and `increased-memory-limit`. Before deleting `inter-app-audio`, run `grep -rn "InterApp\|kAudioUnitType_RemoteGenerator\|AudioOutputUnitPublish" Source/iOS/App/Common Source/iOS/App/DolphiniOS`. It must return nothing, or the key stays and the reason is noted in the commit message.

Camera: none. A 2026-10-12 grep for AVCaptureDevice, AVCaptureSession, VNDocumentCamera, camera image pickers and DataScanner found nothing, so no `NSCameraUsageDescription` is needed.

- [ ] **Step 2: Verify the signed entitlements**

Archive `Release (AppStore)` for iOS in Xcode, or run `Scripts/release.sh --platform ios` against a scratch build number without uploading. Then:
`codesign -d --entitlements - <archive>/Products/Applications/iCube.app | grep -c "cs\.\|inter-app"`
Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add "Source/iOS/App/DolphiniOS/iCube AppStore.entitlements"
git commit -m "fix(appstore): drop macOS cs.* and inter-app-audio entitlements"
```

## Part B — Privacy (WS2)

### Task 5: App privacy manifest

Apple requires the main app to declare its required-reason API usage, which only the extensions do today.

**Files:**
- Create: `Source/iOS/App/DolphiniOS/PrivacyInfo.xcprivacy`
- Modify: `Source/iOS/App/Project.swift:302-331` (app target `resources`)

- [ ] **Step 1: Write the manifest**

These reasons come from the 2026-10-12 grep:
- UserDefaults, including the App Group suite at `Common/SharedDefaults.h:12`.
- File timestamps: `creationDateKey` and `contentModificationDateKey` (date added, save-state lists, sync diffing).
- Disk space: `volumeAvailableCapacityKey` (`TVLibraryView.swift:716`).
- System boot time: `ProcessInfo.systemUptime` (`PlayerScreenViewModel.swift:213`) and `mach_absolute_time` (`StallMetrics.h`).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeCrashData</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<false/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePerformanceData</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<false/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array><string>CA92.1</string><string>1C8F.1</string></array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array><string>C617.1</string><string>3B52.1</string></array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryDiskSpace</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array><string>E174.1</string></array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array><string>35F9.1</string></array>
		</dict>
	</array>
</dict>
</plist>
```
Before committing, check each reason code against Apple's current list ("Describing use of required reason API"). Keep a code only where its definition matches the use:
- `C617.1`: timestamps of files inside the app container.
- `3B52.1`: timestamps of files the user picked.
- `E174.1`: checking for enough space before writing.
- `35F9.1`: measuring elapsed time within the app.
- `1C8F.1`: the App Group UserDefaults.

- [ ] **Step 2: Bundle it**

In `Project.swift`, add `"DolphiniOS/PrivacyInfo.xcprivacy",` to the app target's `resources:` array (after `"Project/Assets/DefaultPreferences.plist",`). Run `tuist generate --no-open`.

- [ ] **Step 3: Verify**

Build `Release (AppStore)` for iOS and tvOS. `ls build-Xcode-appstore/Build/Products/*/iCube.app/PrivacyInfo.xcprivacy` must exist for both. Archive in Xcode and run Organizer → Generate Privacy Report: it lists the four API categories and the two data types, without errors.

- [ ] **Step 4: Commit**

```bash
git add Source/iOS/App/DolphiniOS/PrivacyInfo.xcprivacy Source/iOS/App/Project.swift
git commit -m "feat(privacy): app privacy manifest with required-reason APIs and diagnostics"
```

### Task 6: Crash-report opt-out and App Store scrubbing

Users get a way to turn crash reporting off, and the App Store build stops sending game identifiers and file paths.

**Files:**
- Create: `Source/iOS/App/Common/Services/TelemetryConsent.swift`
- Create: `Source/iOS/App/Common/Services/SentryEventScrubber.swift`
- Modify: `Source/iOS/App/Common/Services/SentryTelemetryService.swift:114-179`, `:206-255`
- Modify: `Source/iOS/App/Common/Services/EmulationPerfSessionRecorder.swift:85-87`
- Test: `Source/iOS/App/DolphiniOSTests/TelemetryConsentTests.swift`, `SentryEventScrubberTests.swift`

**Interfaces:**
- Produces:
  - `enum TelemetryConsent { static let defaultsKey = "icube.telemetry.crashReports"; static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool; static func set(_ on: Bool, defaults: UserDefaults = .standard) }`
  - `enum SentryEventScrubber { static let strippedTags: Set<String>; static func scrubTags(_ tags: [String: String]) -> [String: String]; static func scrubMessage(_ text: String) -> String }`
- Consumed by: Task 7 (the toggle) and `SentryTelemetryService`.

- [ ] **Step 1: Write failing tests**

`TelemetryConsentTests.swift`:
```swift
import XCTest
@testable import iCube

final class TelemetryConsentTests: XCTestCase {
  private var defaults: UserDefaults!
  override func setUp() { defaults = UserDefaults(suiteName: "TelemetryConsentTests")!; defaults.removePersistentDomain(forName: "TelemetryConsentTests") }

  // Sentry starts in AppDelegate before DefaultPreferences.plist is registered, so the default must live in code.
  func testDefaultsToOnWhenNeverSet() { XCTAssertTrue(TelemetryConsent.isEnabled(defaults)) }

  func testRemembersOptOut() {
    TelemetryConsent.set(false, defaults: defaults)
    XCTAssertFalse(TelemetryConsent.isEnabled(defaults))
  }
}
```
`SentryEventScrubberTests.swift`:
```swift
import XCTest
@testable import iCube

final class SentryEventScrubberTests: XCTestCase {
  func testStripsGameIdentity() {
    let out = SentryEventScrubber.scrubTags(["game_id": "GALE01", "jit": "on", "session_id": "abc"])
    XCTAssertNil(out["game_id"])
    XCTAssertEqual(out["jit"], "on")
  }

  // The file name is a game title, so the whole path (name included) becomes <path>.
  func testRedactsContainerPaths() {
    let msg = "Failed to open /var/mobile/Containers/Data/Application/1234-ABCD/Documents/Software/Zelda.rvz"
    XCTAssertEqual(SentryEventScrubber.scrubMessage(msg), "Failed to open <path>")
  }

  func testLeavesPlainTextAlone() {
    XCTAssertEqual(SentryEventScrubber.scrubMessage("Invalid read from 0x80001234"), "Invalid read from 0x80001234")
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run `tuist generate --no-open`, then `make test TEST_ARGS="-only-testing:iCubeTests/TelemetryConsentTests -only-testing:iCubeTests/SentryEventScrubberTests"`. Expected: compile failure, because the types are missing.

- [ ] **Step 3: Implement**

`TelemetryConsent.swift`:
```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The user's "Share crash reports" choice (Settings → Privacy). Read before Sentry starts, which is before
/// DefaultPreferences.plist is registered, so the default (on) lives here, not in the plist.
enum TelemetryConsent {
  static let defaultsKey = "icube.telemetry.crashReports"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: defaultsKey) as? Bool ?? true
  }

  static func set(_ on: Bool, defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: defaultsKey)
  }
}
```
`SentryEventScrubber.swift`:
```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// App Store builds send crash and performance data "not linked to you": no game identity and no file paths
/// (a ROM's file name is a game title). Pure, so the rules are unit-tested.
enum SentryEventScrubber {
  static let strippedTags: Set<String> = ["game_id", "game_title"]
  private static let pathPattern = try! NSRegularExpression(pattern: #"(/private)?/var/mobile/\S+|/Users/\S+"#)

  static func scrubTags(_ tags: [String: String]) -> [String: String] {
    tags.filter { !strippedTags.contains($0.key) }
  }

  static func scrubMessage(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return pathPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
  }
}
```

- [ ] **Step 4: Wire into Sentry**

In `SentryTelemetryService.configure()`:
- Start with `guard TelemetryConsent.isEnabled() else { return }` (after the unit-test-host check at line 117).
- Inside `SentrySDK.start { options in … }` add:
```swift
    #if APPSTORE
    options.enableFileManagerSwizzling = false   // file I/O spans carry container paths
    options.enableCaptureFailedRequests = false  // failed request URLs can carry user source hosts
    options.beforeSend = { event in
      if let tags = event.tags { event.tags = SentryEventScrubber.scrubTags(tags) }
      if let message = event.message?.formatted { event.message = SentryMessage(formatted: SentryEventScrubber.scrubMessage(message)) }
      event.exceptions?.forEach { $0.value = SentryEventScrubber.scrubMessage($0.value) }
      event.breadcrumbs = event.breadcrumbs?.map { crumb in
        crumb.message = crumb.message.map(SentryEventScrubber.scrubMessage)
        crumb.data?.removeValue(forKey: "game_id")
        return crumb
      }
      return event
    }
    options.beforeSendSpan = { span in
      for tag in SentryEventScrubber.strippedTags { span.removeTag(key: tag) }
      return span
    }
    #endif
```
Where the source sets `game_id` (lines 212-223, 228-238, 249, and `EmulationPerfSessionRecorder.swift:85-87`), wrap each `setTag(value:key: "game_id")` in `#if !APPSTORE`. The `beforeSend` and `beforeSendSpan` scrub stays as the backstop.
Check the Sentry SDK version's API names before compiling. Run `grep -rn "beforeSendSpan\|func removeTag" $(find build-Xcode-ios -path "*sentry-cocoa*" -name "*.h" | head -50)`. If `beforeSendSpan` is not available, strip span tags at the set sites only, using the `#if !APPSTORE` wrappers.

Add a runtime switch used by Task 7:
```swift
  /// Settings → Privacy flips this; turning it off closes the SDK so nothing else leaves the device this session.
  static func applyConsent(_ on: Bool) {
    TelemetryConsent.set(on)
    if on { configure() } else { SentrySDK.close() }
  }
```

- [ ] **Step 5: Run tests, then build AppStore for both platforms**

Expected: the 5 new tests pass, and `Release (AppStore)` builds for iOS and tvOS.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Services/TelemetryConsent.swift Source/iOS/App/Common/Services/SentryEventScrubber.swift Source/iOS/App/Common/Services/SentryTelemetryService.swift Source/iOS/App/Common/Services/EmulationPerfSessionRecorder.swift Source/iOS/App/DolphiniOSTests/TelemetryConsentTests.swift Source/iOS/App/DolphiniOSTests/SentryEventScrubberTests.swift
git commit -m "feat(privacy): crash-report consent and App Store scrubbing of game ids and paths"
```

### Task 7: Settings → Privacy leaf

Add the user-facing switch for crash reporting, as a new Privacy section in Settings.

**Files:**
- Create: `Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/ConfigPrivacyModelBuilder.swift`
- Create: `Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/ConfigPrivacyView.swift`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift` (new section before `about`, line 121)
- Test: `Source/iOS/App/DolphiniOSTests/ConfigPrivacyModelBuilderTests.swift`, `SettingsRootModelBuilderTests.swift`

**Interfaces:**
- Consumes: `TelemetryConsent`, `SentryTelemetryService.applyConsent(_:)` (Task 6).
- Produces: leaf id `"privacy"`. `ConfigPrivacyModelBuilder.make(crashReports: Bool, apply: (Bool) -> Void) -> MenuModel`.

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import iCube

final class ConfigPrivacyModelBuilderTests: XCTestCase {
  func testCrashReportToggleReflectsAndWrites() {
    var written: Bool?
    let model = ConfigPrivacyModelBuilder.make(crashReports: true) { written = $0 }
    let item = model.sections.flatMap(\.items).first { $0.id == "crash-reports" }
    guard case .toggle(let binding)? = item?.role else { return XCTFail("no toggle") }
    XCTAssertTrue(binding.wrappedValue)
    binding.wrappedValue = false
    XCTAssertEqual(written, false)
  }
}
```
In `SettingsRootModelBuilderTests.test_sections_inSpecOrder`, insert `"privacy"` before `"about"` in the expected id list.

- [ ] **Step 2: Run them to see them fail** (missing type, and the order test fails).

- [ ] **Step 3: Implement**

`ConfigPrivacyModelBuilder.swift`:
```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings → Privacy. One switch today: crash and performance reports to Sentry (on by default, App Store
/// privacy label: "Diagnostics, not linked to you").
enum ConfigPrivacyModelBuilder {
  static func make(crashReports: Bool, apply: @escaping (Bool) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "diagnostics", header: L("Diagnostics"), items: [
        SettingsRow.toggle("crash-reports", L("Share Crash Reports"), crashReports,
                           L("Sends crash and performance reports to the iCube developers. Reports never include your games, file names or personal data."),
                           set: apply),
      ]),
    ])
  }
}
```
`ConfigPrivacyView.swift`: follow `Leaves/ConfigInterfaceView.swift` exactly (state in `@State`, `SettingsLeafScreen(model:title:sync:)`). The view reads `TelemetryConsent.isEnabled()` and applies through `SentryTelemetryService.applyConsent($0)`.
In `SettingsRootModelBuilder.sections`, before the `about` section:
```swift
      SettingsRootSection(id: "privacy", header: L("Privacy"), entries: [
        SettingsLeafEntry(id: "privacy", title: L("Privacy"), icon: "hand.raised", description: L("Crash reports and diagnostics."),
                          hostsMenuScreen: true,
                          makeModel: { ConfigPrivacyModelBuilder.make(crashReports: TelemetryConsent.isEnabled(), apply: { _ in }) }) { ConfigPrivacyView() },
      ]),
```
Add the strings "Privacy", "Diagnostics", "Share Crash Reports", the description text, and "Crash reports and diagnostics." to en and ja `Core.strings`. Add `privacy` to the leaf list in `Scripts/tvos_screens.sh`.

- [ ] **Step 4: Tests pass, AppStore builds pass, check strings and tokens.**

- [ ] **Step 5: Device check**

With the toggle off, relaunch the app, then trigger a test event through Console.app with the Sentry debug option (DEBUG build). Confirm nothing is sent (no `sentry` network lines).

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/ConfigPrivacyModelBuilder.swift Source/iOS/App/Common/UI/Settings/SwiftUI/Leaves/ConfigPrivacyView.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift Source/iOS/App/DolphiniOSTests/ConfigPrivacyModelBuilderTests.swift Source/iOS/App/DolphiniOSTests/SettingsRootModelBuilderTests.swift Source/iOS/App/Scripts/tvos_screens.sh Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "feat(settings): Privacy leaf with the crash-report switch"
```

## Part C — Firmware the user owns (WS4)

### Task 8: tvOS NAND import through Web UI upload

tvOS has no file picker, so a BootMii NAND backup uploaded through the Web UI or WebDAV is routed to the existing NAND importer.

**Files:**
- Create: `Source/iOS/App/Common/Services/UploadKind.swift`
- Modify: `Source/iOS/App/Common/Services/WebUploadImportService.swift`
- Modify: `Source/iOS/App/DolphiniOS/UI/Import/NANDImportManager.mm` (see Step 4)
- Test: `Source/iOS/App/DolphiniOSTests/UploadKindTests.swift`

**Interfaces:**
- Produces: `enum UploadKind: Equatable { case nandBackup, other; static func classify(fileName: String, size: Int64) -> UploadKind }`.

Accepted sizes (`Source/Core/DiscIO/NANDImporter.cpp:53-58`): `NAND_BIN_SIZE = 0x21000000` (553,648,128 bytes, BootMii dump without keys) and `NAND_BIN_SIZE + NAND_KEYS_SIZE` (553,649,152, with the 0x400-byte keys appended).

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import iCube

final class UploadKindTests: XCTestCase {
  func testBootMiiDumpIsANandBackup() {
    for size in UploadKind.acceptedSizes {
      XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: size), .nandBackup)
      XCTAssertEqual(UploadKind.classify(fileName: "NAND.BIN", size: size), .nandBackup)
    }
  }

  func testWrongSizeIsNotANandBackup() {
    XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: 1_459_978_240), .other) // a renamed GameCube ISO
    XCTAssertEqual(UploadKind.classify(fileName: "nand.bin", size: 0), .other)
  }

  func testOtherNamesAreOther() {
    XCTAssertEqual(UploadKind.classify(fileName: "game.rvz", size: UploadKind.acceptedSizes.first!), .other)
  }
}
```

- [ ] **Step 2: Implement `UploadKind.swift`**

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a Web UI / WebDAV upload is. tvOS has no file picker, so a BootMii NAND backup uploaded from a computer
/// is how an Apple TV gets the user's own Wii system files (the App Store build has no online System Update).
enum UploadKind: Equatable {
  case nandBackup, other

  /// DiscIO/NANDImporter.cpp:53-58: a BootMii dump (0x21000000) and the same with its 0x400-byte keys appended.
  static let acceptedSizes: Set<Int64> = [0x2100_0000, 0x2100_0000 + 0x400]

  static func classify(fileName: String, size: Int64) -> UploadKind {
    fileName.lowercased() == "nand.bin" && acceptedSizes.contains(size) ? .nandBackup : .other
  }
}
```

- [ ] **Step 3: Route it**

In `WebUploadImportService.swift`, before the archive or ROM handling of a finished upload, read the file size (`FileManager.default.attributesOfItem(atPath:)[.size]`). If `UploadKind.classify(...) == .nandBackup`, call `NANDImportManagerBridge.importNAND(from: url)` (`Common/Swift/Bridging/NANDImportManagerBridge.swift:5-6`) on the main actor, post the snackbar `L("Importing Wii NAND backup…")`, and return without moving the file into Software.
`NANDImportManager.mm:20-39` starts security-scoped access and presents a UIAlert from the top view controller. Read it: tvOS can present UIAlertController, but if the manager is compiled for iOS only (check `Project.swift` source globs and any `#if` in the file), drop the iOS-only guard so it compiles on tvOS. Keep the security-scoped calls, which are harmless on a plain path.

- [ ] **Step 4: Tests pass; device test**

Upload a real `nand.bin` from a Mac browser to the Apple TV's Web UI. The import alert shows progress, and afterwards a Wii Menu or channel title that needs system files boots. Record the result in `docs/HANDOFF.md`.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Services/UploadKind.swift Source/iOS/App/Common/Services/WebUploadImportService.swift Source/iOS/App/DolphiniOS/UI/Import/NANDImportManager.mm Source/iOS/App/DolphiniOSTests/UploadKindTests.swift Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "feat(tvos): import a BootMii NAND backup uploaded through the Web UI"
```

### Task 9: "Install your own Wii system files" help, everywhere

Write the firmware how-to once and publish it in the wiki, in-app help and the website.

**Files:**
- Create: `docs/wiki-seed/guide/wii-system-files.md`, and the same file at `Source/iOS/PVHelp/Sources/PVHelp/WikiContent/guide/wii-system-files.md`
- Modify: `docs/wiki-seed/SUMMARY.md` and the bundled copy
- Modify: `Source/iOS/PVHelp/Sources/PVHelp/WikiConstants.swift:50-58` (add `public static let wiiSystemFiles = "guide/wii-system-files.md"`)
- Website: create `~/Workspace/Provenance/iCube/icube-emu.github.io/src/app/guide/wii-system-files/page.tsx` and add it to `src/app/guide/guideNav.ts`

- [ ] **Step 1: Write the guide**

Sections:
1. **Why:** iCube does not download Nintendo software. Wii titles that need system menus or channels use files from your own console.
2. **Dump your NAND with BootMii:** what you need, and that `nand.bin` and `keys.bin` come from your own Wii.
3. **iPhone and iPad:** Library → Import → "Import BootMii NAND Backup…".
4. **Apple TV:** Settings → Web UI & WebDAV. Open the address on a computer and upload `nand.bin`; the import starts by itself.
5. **Check it worked.**
6. **Troubleshooting:** wrong size, missing keys.

Follow the voice and format of `docs/wiki-seed/guide/dumping-discs.md`. Copy the file byte-for-byte into the PVHelp `WikiContent` tree.

- [ ] **Step 2: Website page**

Mirror `src/app/guide/dumping-discs/page.tsx`'s structure and add a nav entry. Run `npm run build` in the website repo; it must succeed.

- [ ] **Step 3: Verify**

Build any iOS config. The Task 3 "Install Wii System Files…" row opens the page from the bundle (airplane mode works, through the bundled fallback).

- [ ] **Step 4: Commit (two repos)**

```bash
git add docs/wiki-seed/guide/wii-system-files.md docs/wiki-seed/SUMMARY.md Source/iOS/PVHelp/Sources/PVHelp/WikiContent/guide/wii-system-files.md Source/iOS/PVHelp/Sources/PVHelp/WikiContent/SUMMARY.md Source/iOS/PVHelp/Sources/PVHelp/WikiConstants.swift
git commit -m "docs(help): install your own Wii system files"
```
Then commit in the website repo: `git add src/app/guide/wii-system-files src/app/guide/guideNav.ts && git commit -m "docs: install your own Wii system files"`.

## Part D — Branding (WS3)

### Task 10: Logo-free art everywhere and trade-dress clean-up

Every configuration uses the logo-free templates, and the remaining GameCube trade dress is painted out.

**Files:**
- Modify: `Source/iOS/App/Common/Swift/LibraryPlatformCategory.swift:156-170`
- Delete: `Source/iOS/App/Common/Assets.xcassets/GCCoverTemplate.imageset`, `WiiCoverTemplate.imageset`
- Modify: `Source/iOS/App/Common/Assets.xcassets/GCCoverTemplate-NoLogo.imageset/GCCoverTemplate-NoLogo.png` (paint out the "ONLY FOR" tab)
- Modify: `Source/iOS/App/DolphiniOS/en.lproj/LaunchScreen.strings` (and any other `*.lproj/LaunchScreen.strings`)
- Modify: `Common/UI/Localization/{en,ja}.lproj/Core.strings` (the N64 skin strings at en:4821-4822)
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/SkinStoreView.swift:158-182`

- [ ] **Step 1: One template name per platform**

```swift
  var templateImageName: String {
    switch self {
    // Logo-free in every build: no GameCube, Wii or Nintendo marks, and screenshots match what ships.
    case .gameCube: return "GCCoverTemplate-NoLogo"
    case .wii: return "WiiCoverTemplate-NoLogo"
    }
  }
```
Delete the two logo imagesets with `git rm -r`, then run `grep -rn '"GCCoverTemplate"\|"WiiCoverTemplate"' Source` to confirm nothing references them.

- [ ] **Step 2: Paint out the GameCube "ONLY FOR" corner tab**

The purple triangle sits in the top-left of `GCCoverTemplate-NoLogo.png`, over the black top band. Script it in the scratchpad and run it with `python3 -I`. The script fills that corner with the band's own black, sampled from a pixel just right of the tab inside the band:
```python
from PIL import Image, ImageDraw
p = "Source/iOS/App/Common/Assets.xcassets/GCCoverTemplate-NoLogo.imageset/GCCoverTemplate-NoLogo.png"
im = Image.open(p).convert("RGBA"); w, h = im.size
band = im.getpixel((int(w * 0.30), int(h * 0.02)))          # the black top band
tab = int(w * 0.18)                                          # the tab spans ~16 % of the width (verify on the image)
ImageDraw.Draw(im).polygon([(0, 0), (tab, 0), (0, tab)], fill=band)
im.save(p)
```
Open the before and after images with the Read tool and adjust `tab` until no purple remains, the band edge is clean, and transparency outside the band is untouched. Send both versions to the owner with SendUserFile for approval before committing.

- [ ] **Step 3: Wording**

- `LaunchScreen.strings`: `"SUB-ti-tle.text" = "Play your own GameCube and Wii discs";` (descriptive, no emoji). Update the matching default text in `LaunchScreen.storyboard`, if it carries one.
- The N64 skin strings: "Made for Nintendo 64" becomes "N64-style layout". The note becomes "Built for N64-style layouts. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels." Update the `L(...)` keys in `SkinStoreView.swift` and both `Core.strings`, removing the old keys.
- Sweep: `grep -rn "Nintendo" Source/iOS/App/Common Source/iOS/App/DolphiniOS --include=*.swift --include=*.m --include=*.mm --include=*.strings --include=*.storyboard`. Keep the trademark disclaimers (Core.strings en:784, 5115), protocol and peripheral names (Switch controllers, XLink Kai), and WiiLink. List any other hit in the commit message, with keep or change and the reason.

- [ ] **Step 4: Verify**

Build Debug (Non-Jailbroken) for tvOS, then `Scripts/tvos_screens.sh <scratch>/branding --dark`. In `library-*` and `pause-grid`, no logo or purple tab is visible. Run the `Release (AppStore)` builds for iOS and tvOS.

- [ ] **Step 5: Commit**

```bash
git rm -r Source/iOS/App/Common/Assets.xcassets/GCCoverTemplate.imageset Source/iOS/App/Common/Assets.xcassets/WiiCoverTemplate.imageset
git add Source/iOS/App/Common/Swift/LibraryPlatformCategory.swift Source/iOS/App/Common/Assets.xcassets/GCCoverTemplate-NoLogo.imageset Source/iOS/App/DolphiniOS/en.lproj/LaunchScreen.strings Source/iOS/App/Common/UI/Settings/SwiftUI/SkinStoreView.swift Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "feat(branding): logo-free cover templates in every build, no GameCube trade dress"
```

## Part E — Release polish (WS7)

### Task 11: Quiet release logs

Release builds stop writing debug noise and game paths to the console.

**Files:**
- Create: `Source/iOS/App/Common/Swift/ICubeLog.swift`
- Create: `Source/iOS/App/Common/ICubeLog.h` (ObjC macro)
- Modify, one file per commit, noisiest first:
  - `Common/Swift/RemoteSourcesCoordinator.swift` (44)
  - `Common/Swift/EmulationScreen.swift` (17)
  - `Common/UI/SoftwareList/GameFileCacheManager.mm` (17)
  - `Common/Swift/EmulationScreen+TouchAndMotion.swift` (15)
  - `Common/UI/Emulation/EmuEventVC.m` (14)
  - `Common/Swift/RemoteSourcesStore.swift` (11)

- [ ] **Step 1: The two helpers**

`ICubeLog.swift`:
```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import os

/// Unified-logging categories for app code. `.debug` is dropped in release builds by the system, and
/// interpolated values are private by default, so paths and game names stay out of a sysdiagnose.
enum ICubeLog {
  static let subsystem = "com.joemattiello.iCube"
  static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}
```
`ICubeLog.h`:
```objc
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#import <Foundation/Foundation.h>
/// NSLog in DEBUG builds only. Release builds keep the console quiet (and free of paths and game names).
#ifdef DEBUG
#define DOLDebugLog(...) NSLog(__VA_ARGS__)
#else
#define DOLDebugLog(...) do {} while (0)
#endif
```

- [ ] **Step 2: Convert one file at a time**

- Swift: add `private static let log = ICubeLog.logger("<FileTopic>")`. Then:
  - `print(...)` and `NSLog(...)` that trace flow become `Self.log.debug("…")`.
  - Real failures become `Self.log.error("…")`.
  - Interpolated paths and titles become `\(value, privacy: .private)`.
- ObjC: `#import "ICubeLog.h"`. `NSLog` becomes `DOLDebugLog`, except error paths, which stay `NSLog` with no file paths in the format.

Build iOS and tvOS Debug after each file, and commit each file separately (`refactor(logging): <file> uses ICubeLog`).

- [ ] **Step 3: Measure**

Rerun the counting grep from the plan research (NSLog plus `print(` per file outside `#if DEBUG`). Record before and after in the final commit message.

## Part F — Store presence and submission (WS5, WS6, WS8)

### Task 12: Store screenshots from the App Store configuration

Store screenshots must come from a compliant build and show no Nintendo game art.

**Files:**
- Modify: `Source/iOS/App/Scripts/tvos_screens.sh` (add `--config appstore`)
- Modify: `Source/iOS/App/tools/screenshots/capture.py` and `shots.json` (iPhone and iPad), per its `README.md`
- Output: `docs/app-store/screenshots/{iphone-6.9,ipad-13,appletv}/*.png` (untracked; listed in `.gitignore`, uploaded to App Store Connect by hand)

- [ ] **Step 1: tvOS script config switch**

`--config appstore` builds `Debug (AppStore)` (DEBUG, so the `-ICube*` and `SCREENSHOT_MODE` hooks work, and `APPSTORE`, so the gates and NoLogo art apply), with bundle id `com.joemattiello.iCube`:
```sh
CONFIG="Debug (Non-Jailbroken)"; BID=com.joemattiello.iCube-debug; SCHEME="iCube (NJB)"
for a in "$@"; do case "$a" in --config) ;; appstore) CONFIG="Debug (AppStore)"; BID=com.joemattiello.iCube; SCHEME="iCube (AppStore)";; esac; done
```
Pass `-scheme "$SCHEME" -configuration "$CONFIG"` to `xcodebuild`. Change the install glob to match the product name.

- [ ] **Step 2: Shot list**

- tvOS:
  - `library-all`, `library-gameCube` (demo catalogue; NoLogo placeholders only)
  - `pause-grid`, `pause-saves-slot-focus`, `pause-exit`
  - `settings-graphics-enhancements`, `settings-controllers`, `settings-shaders`
- iPhone 6.9" (`iPhone 17 Pro Max`, UDID `71886517-8BC0-41BE-A791-99DC0CE18F8F`) and iPad 13": create an `iPad Pro 13-inch (M5)` simulator with `xcrun simctl create`. Capture the same set with `tools/screenshots/capture.py --device iphone|ipad`, using the AppStore build.

No real covers: `SCREENSHOT_MODE` demo titles only. The real-ID website set from `docs/HANDOFF.md` is a separate run and never goes to App Store Connect.

- [ ] **Step 3: Owner review**

Send the set with SendUserFile and get approval before uploading.

### Task 13: App Store Connect texts and review notes

Write every piece of text App Store Connect asks for, ready to paste.

**Files:**
- Create: `docs/app-store/metadata.md`
  - name: iCube
  - subtitle (≤30 characters)
  - promotional text (≤170 characters)
  - description: features; "Play GameCube and Wii games you own"; "iCube does not include any games or system software"; the trademark disclaimer from About
  - keywords (≤100 characters, comma-separated, no trademarks of others)
  - support URL `https://icube-emu.com/support`, marketing URL, privacy URL `https://icube-emu.com/privacy`
  - What's New for 1.0
- Create: `docs/app-store/privacy-label.md`. Data types: Crash Data and Performance Data, "App Functionality", not linked, not tracking. Plus "Other diagnostic data" if MetricKit payloads count. Everything else: not collected. iCloud sync data is stored in the user's own iCloud container and is not collected by the developer.
- Create: `docs/app-store/review-notes.md`, covering:
  - 4.7: emulates GameCube and Wii; ships no games, BIOS or firmware; the user imports their own discs.
  - How to test: a freely distributable homebrew title (name it and give a public download URL; the owner picks one), importing through Files on iPhone and the Web UI on Apple TV.
  - No JIT and no downloaded executable code; the interpreter runs in the sandbox.
  - Cheats are user-applied memory patches from a public code database.
  - Skins are images.
  - GPLv2 and the source URL.
- Modify: the website `src/app/privacy/page.tsx`, so the policy matches `privacy-label.md` (crash reports, the opt-out, no other collection).

- [ ] **Step 1: Write the four files.** Character limits are checked with `wc -m` on each field.
- [ ] **Step 2: Owner review** of the texts, then commit:
  `git add docs/app-store/*.md && git commit -m "docs(appstore): metadata, privacy label and review notes"`. Commit the website change in its own repo.

### Task 14 (owner): iCloud for the store build

iCloud Sync ships at launch only if provisioning is finished; otherwise it is hidden in the App Store build.

- [ ] Create or confirm the container `iCloud.com.joemattiello.iCube` in the Apple Developer portal, and enable iCloud (CloudKit) on `com.joemattiello.iCube` and on any extension ids listed in `docs/cloudkit-entitlements.patch`.
- [ ] Apply `docs/cloudkit-entitlements.patch` to `iCube AppStore.entitlements` and `DolphiniOS.entitlements`. Build `Release (AppStore)` for iOS and tvOS.
- [ ] CloudKit Console: deploy the Development schema to Production.
- [ ] Two-device sync test (iPhone and Apple TV) on a TestFlight build, using the device checklist in `docs/` from the CloudKit work.
- [ ] **Fallback, if this is not done by the submission date:** wrap the `icloud` entry in `SettingsRootModelBuilder.sections` (line 116) in `#if !APPSTORE`, then commit `feat(appstore): hide iCloud Sync until provisioned`.

### Task 15 (owner + agent): Preview video, submission checklist, submit

The final step: the video, a submission checklist, and the review submission itself.

- [ ] **Video:** a 15–30 s UI walkthrough per platform, plus gameplay only from a homebrew or freely licensed title, recorded on device (Record tile or QuickTime). Saved under `docs/app-store/video/` (untracked).
- [ ] **Checklist:** create `docs/app-store/submission-checklist.md`:
  - The build comes from `Release (AppStore)`, uploaded by the TestFlight workflow. Record its build number.
  - `codesign` entitlement check (Task 4 Step 2).
  - Privacy report (Task 5 Step 3).
  - Metadata pasted (Task 13).
  - Privacy label answered.
  - Age rating questionnaire answered (expect 4+, or 9+ for user-generated content: none).
  - Export compliance: `ITSAppUsesNonExemptEncryption` is already `false` in both Info.plists.
  - Phased release on.
  - Rejection playbook: what to gate first if asked (cheats, skins, the Web UI server).
- [ ] **Submit:** select the build for the iOS and tvOS versions in App Store Connect and submit for review. Log the date and build in `docs/HANDOFF.md`.
