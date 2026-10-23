# iPhone as the Wii Remote on Apple TV — Implementation Plan (Phases 0 and 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One tap on an iPhone makes it a controller (Wii Remote with gyro pointer) for iCube on a nearby Apple TV, with both sides confirming the pairing once and no typing.

**Architecture:** Reuse the existing DSU path end to end: the phone's `DSUServerBridge` advertises an identity TXT and switches to approval-required; the TV's DSU discovery feeds a pure decision core (`PhoneControllerConnector`) that prompts, adds, refreshes and removes only its own `DSUClient.ini` entries; the core's DSU client picks up config changes live; the existing assignment engine seats the device; a new `PointerSource.phoneGyro` labels the pointer.

**Tech Stack:** Swift/SwiftUI app (iOS 17 / tvOS 17), ObjC++ bridges (`DSUServerBridge`, `DOLConfigBridge`), NetService Bonjour, XCTest (`iCubeTests`), Tuist project.

**Spec:** [`docs/superpowers/specs/2026-10-22-iphone-as-wii-remote-design.md`](../specs/2026-10-22-iphone-as-wii-remote-design.md) (owner decisions 2026-10-23 at its top).

## Global Constraints

- Work on branch `feature/iphone-wii-remote` cut from `develop`. No pushes, no changes to `develop` until review.
- No C++ under `Source/Core` (would force core slice rebuilds). Every xcodebuild: `DOL_SKIP_CORE_BUILD=1 ICUBE_FAST_DEV=1`. Run `tuist generate --no-open` (in `Source/iOS/App`) after adding files.
- Never stage `build/xcframework`. Conventional commits, **no Co-Authored-By or LLM attribution trailers**.
- Every new `L("…")` key goes in `Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings` as `"key" = "key";`; `python3 Project/Scripts/check_localized_keys.py --check` and `python3 Project/Scripts/check_design_tokens.py --check` pass (no hard-coded fonts, colours, radii, line widths; no `navigationTitle` in tvOS code).
- Trust model (a): the TV confirms each new phone once per TV launch; a one-tap phone session is approval-required and answers only the TV approved on the phone. Nothing connects silently.
- Phone takes Wii Remote 2 when a pad already holds Wii Remote 1 (existing engine behaviour; pinned by a test).
- Gyro pointer only from the phone in this plan (touch-drag is Phase 3). TV-initiated connect (Phase 2) is out of scope.
- Deferred from the spec's phone entry points: the Control Center control and Lock Screen widget. The app does not embed its widget extension today; the App Intent (Task 7) covers Shortcuts, Spotlight and the Action button.
- Paths below are relative to `Source/iOS/App/`. Test target is `iCubeTests`; tests live in `DolphiniOSTests/`.
- Build/test gates (from `Source/iOS/App`):
  - tvOS: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "platform=tvOS Simulator,id=2543E4FC-4A46-4884-8483-96A6F2253304" -derivedDataPath build-Xcode-tvos CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""`
  - iOS tests: same with `test`, `platform=iOS Simulator,id=5E1E252A-25F3-4CCA-A93E-4912CF37785E`, `-derivedDataPath build-Xcode-ios`, `-only-testing:iCubeTests/<Class>` while iterating, and the full `-only-testing:iCubeTests` with `-resultBundlePath` before each commit (read totals with `xcrun xcresulttool get test-results summary`). Baseline on develop `8fc454c260`: 2,369 total, 7 skipped, 0 failed.

## Review Focus

1. **Phone's IP changes mid-game** (Wi-Fi roam, DHCP): the TV must update its auto entry from the re-resolved advert, keyed by `pid`, not add a second entry. Test in Task 5.
2. **Two phones with the same name**: entries and device qualifiers stay distinct (`"Joe's iPhone"`, `"Joe's iPhone (2)"`). Test in Task 5.
3. **"Not Now" on the TV**: the same phone is not asked again until the TV app relaunches. Test in Task 5.
4. **Manual DSU servers** (a PC, a third-party DSU app): never modified or removed by the connector. Test in Task 5.
5. **Phone backgrounded or locked mid-game**: the server stops cleanly (no silent half-stream), the TV's device disappears and the existing disconnect banner pauses the game; on return to the foreground the server restarts. Tests in Task 3 (lifecycle decision) and Task 5 (removal after 10 s).

---

### Task 1: Declare the DSU Bonjour type on both platforms

**Files:**
- Modify: `DolphiniOS/Info.plist` (the `NSBonjourServices` array, ~line 162)
- Modify: `DolphiniOS/Info-TV.plist` (its `NSBonjourServices` array)
- Test: `DolphiniOSTests/BonjourServicesTests.swift` (create)

**Interfaces:**
- Produces: `_dolphin-dsu._udp` present in the app's `NSBonjourServices` on iOS and tvOS.

- [ ] **Step 1: Write the failing test** — `test_dsuServiceType_isDeclaredForLocalNetworkPolicy()`: read `Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]` and `XCTAssertTrue(services.contains("_dolphin-dsu._udp"))`; also assert `_icube-continuity._tcp` is still present.
- [ ] **Step 2: Run it** — iOS test command with `-only-testing:iCubeTests/BonjourServicesTests`. Expected: FAIL on the DSU assertion.
- [ ] **Step 3: Add `<string>_dolphin-dsu._udp</string>`** to both arrays, with a comment: the phone publishes it (`DSUServerBridge`) and the TV browses it (`DSUDiscovery`); an undeclared type fails silently under local-network policy.
- [ ] **Step 4: Run the test, then the tvOS build.** Expected: PASS; BUILD SUCCEEDED. Confirm with `/usr/libexec/PlistBuddy -c "Print NSBonjourServices" "build-Xcode-tvos/Build/Products/Debug (Non-Jailbroken)-appletvsimulator/iCube.app/Info.plist"`.
- [ ] **Step 5: Commit** — `fix(dsu): declare the DSU Bonjour type so discovery works on device`.

### Task 2: An editable iCube device name

**Files:**
- Create: `Common/Continuity/ICubeDeviceName.swift`
- Modify: `Common/Continuity/ContinuityManager.swift:534` (`deviceName()`), `Common/Bridging/DSUServerBridge.mm:591` (service name), `Common/Continuity/UI/ContinuityBrowseModelBuilder.swift` + `ContinuityBrowseView.swift` (a "Device Name" row and its rename sheet)
- Test: `DolphiniOSTests/ICubeDeviceNameTests.swift` (create), `DolphiniOSTests/ContinuityModelBuildersTests.swift`

**Interfaces:**
- Produces: `enum ICubeDeviceName { static let defaultsKey = "icube_device_name"; static func current(defaults: UserDefaults = .standard, systemName: String = UIDevice.current.name) -> String; static func set(_ name: String?, defaults: UserDefaults = .standard) }`. Empty or whitespace-only stored names fall back to `systemName`; stored names are trimmed and capped at 40 characters.
- Produces: ObjC reads the same key: `DSUServerBridge` publishes with `[[NSUserDefaults standardUserDefaults] stringForKey:@"icube_device_name"]` trimmed, falling back to `UIDevice.currentDevice.name`.
- Produces: `ContinuityBrowseModelBuilder.make(...)` gains a row id `"device-name"` in the `"this-device"` section, badge = current name, opening a rename sheet (Form + TextField, the `RenameStateSheet` pattern in `SaveStateFilmstripView.swift`, because tvOS alerts cannot host text fields).

- [ ] **Step 1: Failing tests** — `test_current_fallsBackToSystemName_whenUnsetOrBlank()` (unset → `"iPhone"`, `"   "` → `"iPhone"`), `test_set_trimsAndCaps()` (`"  Joe's iPhone  "` → `"Joe's iPhone"`; 60 chars → first 40), `test_set_nil_clears()`; builder test `test_browse_hasDeviceNameRow_withTheCurrentNameAsBadge()`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/ICubeDeviceNameTests -only-testing:iCubeTests/ContinuityModelBuildersTests`. Expected: FAIL (type missing).
- [ ] **Step 3: Implement** `ICubeDeviceName`, route `ContinuityManager.deviceName()` through `ICubeDeviceName.current()`, read the key in `DSUServerBridge.publishBonjour`, add the row and sheet. Strings: `"Device Name"`, `"How this device appears to your other devices."`.
- [ ] **Step 4: Run tests + both python checks + tvOS build.** Expected: PASS / OK / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(continuity): an editable device name for nearby devices and DSU`.

### Task 3: Phone controller stays awake and survives the background

**Files:**
- Create: `Common/Swift/DSU/DSUSessionLifecycle.swift`
- Modify: `Common/Swift/Widgets/DSUControllerView.swift` (appear/disappear, `@Environment(\.scenePhase)`)
- Test: `DolphiniOSTests/DSUSessionLifecycleTests.swift` (create)

**Interfaces:**
- Produces: `enum DSUSessionLifecycle { enum Action: Equatable { case start, stop, none }; static func action(for phase: ScenePhase, serverRunning: Bool, sessionOpen: Bool) -> Action }` — `.background` with a running server → `.stop`; `.active` with the session open and the server stopped → `.start`; everything else `.none`.
- Produces: `DSUControllerView` sets `UIApplication.shared.isIdleTimerDisabled = true` on appear and `false` on disappear (iOS only), and applies `DSUSessionLifecycle.action` on scene-phase changes via `DSUServerBridge.start(onPort:)` / `DSUServerBridge.stop()`.

- [ ] **Step 1: Failing tests** — table test over `(phase, serverRunning, sessionOpen)` for all 12 combinations, asserting the three rules above (`test_backgroundStopsARunningServer`, `test_activeRestartsWhileTheSessionIsOpen`, `test_inactiveDoesNothing`).
- [ ] **Step 2: Run** `-only-testing:iCubeTests/DSUSessionLifecycleTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the enum and wire it into `DSUControllerView` (`#if os(iOS)` for the idle timer).
- [ ] **Step 4: Run tests + tvOS build.** Expected: PASS / SUCCEEDED.
- [ ] **Step 5: Commit** — `fix(dsu): keep the phone controller awake and restart it after the background`.

### Task 4: The phone advertises who it is

**Files:**
- Create: `Common/Swift/DSU/DSUAdvert.swift`
- Modify: `Common/Bridging/DSUServerBridge.{h,mm}` (merge an identity dictionary into the TXT and republish)
- Test: `DolphiniOSTests/DSUAdvertTests.swift` (create)

**Interfaces:**
- Produces: `struct DSUAdvert: Equatable { static let version = "1"; let pid: String; let name: String; let deviceType: String; let isController: Bool; func txtRecord() -> [String: String]; static func parse(_ txt: [String: Data]) -> DSUAdvert? }`. Keys: `v`, `pid`, `name`, `dt`, `role` (`"controller"` when `isController`). `parse` returns nil when `v` is missing or not `"1"`, or `pid`/`name` is empty.
- Produces: `+ (void)setIdentity:(NSDictionary<NSString *, NSString *> *)identity;` on `DSUServerBridge`, merged with the existing `layout`/`ext`/`sideways` keys and pushed with `setTXTRecordData:` (publishing the TXT immediately, not only after a layout is chosen).

- [ ] **Step 1: Failing tests** — `test_roundTrip()` (`txtRecord` → UTF-8 `Data` → `parse` equals the original), `test_parse_rejectsUnknownVersionOrMissingIdentity()`, `test_nonController_hasNoRole()`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/DSUAdvertTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `DSUAdvert` and `setIdentity:`.
- [ ] **Step 4: Run tests + tvOS build.** Expected: PASS / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(dsu): advertise the phone's identity in the DSU Bonjour record`.

### Task 5: The TV's connection decisions (pure core)

**Files:**
- Create: `Common/Swift/DSU/PhoneControllerConnector.swift`
- Modify: `Common/UI/Settings/SwiftUI/DSUDiscovery.swift` (`DSUDiscoveredServer` gains `advert: DSUAdvert?` from the resolved TXT via `NetService.txtRecordData()` → `NetService.dictionary(fromTXTRecord:)`; equality also compares `advert?.pid`)
- Test: `DolphiniOSTests/PhoneControllerConnectorTests.swift` (create)

**Interfaces:**
- Consumes: `DSUAdvert`, `DSUDiscoveredServer`.
- Produces: 
  ```swift
  struct DSUEntry: Equatable { let description: String; let address: String; let port: Int }
  enum PhoneConnectorAction: Equatable {
    case prompt(pid: String, name: String)
    case add(pid: String, entry: DSUEntry)
    case update(pid: String, index: Int, entry: DSUEntry)
    case remove(pid: String, index: Int)
  }
  struct PhoneConnectorState: Equatable {
    var confirmed: Set<String> = []      // pids allowed this TV launch
    var declined: Set<String> = []       // pids answered "Not Now" this launch
    var owned: [String: String] = [:]    // pid -> entry description we added (persisted)
    var lastSeen: [String: Date] = [:]
  }
  enum PhoneControllerConnector {
    static let departureGrace: TimeInterval = 10
    static func actions(servers: [DSUDiscoveredServer], entries: [DSUEntry],
                        state: PhoneConnectorState, now: Date) -> [PhoneConnectorAction]
    static func uniqueDescription(for name: String, taken: [String]) -> String  // "Joe's iPhone", then "Joe's iPhone (2)", "(3)"…
  }
  ```
  Rules: only servers whose `advert?.isController == true` count; an unconfirmed, undeclined pid → `.prompt` once; a confirmed pid with no owned entry → `.add` with `uniqueDescription`; a confirmed pid whose owned entry's address or port differs → `.update`; an owned pid not advertised for `departureGrace` → `.remove`; entries not in `owned` are never touched.

- [ ] **Step 1: Failing tests** — `test_newPhone_isPromptedOnce()`, `test_confirmedPhone_isAdded_withAUniqueDescription()`, `test_declinedPhone_isNotAskedAgainThisLaunch()` (Review Focus 3), `test_ipChange_updatesTheSameEntry()` (Review Focus 1), `test_twoPhonesSameName_getDistinctDescriptions()` (Review Focus 2), `test_departedPhone_isRemovedOnlyAfterTheGrace()` (9 s → nothing, 11 s → `.remove`; Review Focus 5), `test_manualEntries_areNeverTouched()` (Review Focus 4), `test_nonControllerAdverts_areIgnored()`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/PhoneControllerConnectorTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the connector and the TXT read in `DSUDiscovery`.
- [ ] **Step 4: Run tests + tvOS build.** Expected: PASS / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(dsu): decide when the TV adds, refreshes and removes a phone controller`.

### Task 6: The TV prompts, connects and seats the phone

**Files:**
- Create: `Common/Swift/DSU/PhoneControllerService.swift` (live `@MainActor` owner of a `DSUDiscoveryBrowser`, the `PhoneConnectorState`, and the action executor), `Common/Swift/DSU/PhoneControllerPrompt.swift` (view modifier)
- Modify: `Common/Swift/TVRootView.swift` (attach `.phoneControllerPrompt()` beside `.continuityPairingPrompt()` ~line 78; start/stop the service with scene phase, tvOS only)
- Test: `DolphiniOSTests/PhoneControllerServiceTests.swift` (create), `DolphiniOSTests/AssignmentEngineTests.swift` (one test)

**Interfaces:**
- Consumes: `PhoneControllerConnector.actions`, `DOLConfigBridge.addDsuServer(_:address:port:)`, `removeDsuServer(at:)`, `dsuServersParsed()`, `setDsuClientEnabled(_:)`, `EmulationToast.post(_:)`.
- Produces: `final class PhoneControllerService: ObservableObject { static let shared; @Published private(set) var pendingPrompt: (pid: String, name: String)?; @Published private(set) var advertisingPhones: [DSUDiscoveredServer]; func respond(pid: String, allow: Bool); func connect(pid: String) }` with an injectable `DSUConfigWriting` protocol (`entries() -> [DSUEntry]`, `add(_:)`, `update(at:to:)`, `remove(at:)`, `setEnabled(_:)`) so tests run without the core. The owned map persists in UserDefaults key `dsu_phone_controller_entries`.
- Produces: `.phoneControllerPrompt()` — an `ICubeConfirmPanel`-style confirm (tvOS) / `.alert` (iOS host) titled `"Use %@ as a controller?"`, message `"It will play as the next free player. Your iPhone asks you to confirm too."`, buttons `"Allow"` / `"Not Now"`; on add, a toast `"%@ is connected as a controller"`.

- [ ] **Step 1: Failing tests** — `test_allow_addsEntryEnablesClientAndToasts()`, `test_notNow_marksDeclined_andAddsNothing()`, `test_executor_appliesUpdateAndRemove_toOwnedEntriesOnly()` (fake writer); `AssignmentEngineTests.test_dsuPhone_takesWiiRemote2_whenAPadHoldsWiiRemote1()` (state with a pad on Wii Remote 1 and `DSUClient/0/Joe's iPhone` connected → phone on Wii Remote 2).
- [ ] **Step 2: Run** those classes. Expected: FAIL (service missing; the engine test may already pass — if so, keep it as a pin).
- [ ] **Step 3: Implement** the service, executor, prompt modifier and `TVRootView` wiring.
- [ ] **Step 4: Run tests + tvOS build.** Expected: PASS / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(tvos): confirm and connect a nearby iPhone as a controller`.

### Task 7: One tap on the phone

**Files:**
- Create: `Common/Swift/DSU/PhoneControllerSession.swift` (iOS), `Common/AppIntents/UseAsWiiRemoteIntent.swift`
- Modify: `Common/Services/URLRouterService.swift` (route `dolphinios://dsu/controller`), `Common/Swift/TVLibraryView.swift` (iOS library: a visible "Play on Apple TV" toolbar button, `#if os(iOS)`), `Common/AppIntents/` shortcuts provider if one exists, the phone's existing `DSUNewClientApproval` handling (`TVLibraryView.swift` ~2500 and `DSUSessionView`)
- Test: `DolphiniOSTests/PhoneControllerSessionTests.swift` (create), `DolphiniOSTests/URLRouterServiceTests.swift` if present (else add the routing case to the new test file)

**Interfaces:**
- Consumes: `DSUAdvert`, `ICubeDeviceName.current()`, `DSUServerBridge.setIdentity:`, `setApprovalRequired:`, `setClient:allowed:`, `setRestrictToClient:`, `start(onPort:)`.
- Produces: `enum PhoneControllerSession { struct Configuration: Equatable { let layout: String; let pointerMode: PointerMode; let approvalRequired: Bool; let advert: DSUAdvert }; static func configuration(pid: String, name: String) -> Configuration; @MainActor static func begin() }` — layout `"wiiRemote"` (`DSUControllerLayout.wiiRemote.rawValue`), pointer `.gyro`, approval required, `advert.isController == true`, `dt` from the platform (`"ip"`/`"pd"`). `begin()` applies it, starts the server, and presents `DSUControllerView`. Approving the TV on the phone's prompt calls `setClient(ip, allowed: true)` and `setRestrictToClient(ip)`.
- Produces: `struct UseAsWiiRemoteIntent: AppIntent` (`title: "Use iPhone as Wii Remote"`, `openAppWhenRun = true`) whose `perform()` opens `dolphinios://dsu/controller`.

- [ ] **Step 1: Failing tests** — `test_configuration_isWiiRemoteGyroApprovalRequiredController()`, `test_router_opensTheControllerSession_forTheDSUControllerURL()`.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** the session, intent, route, library button (strings `"Play on Apple TV"`, `"Use iPhone as Wii Remote"`) and the approval → restrict wiring.
- [ ] **Step 4: Run tests + tvOS build + iOS build.** Expected: PASS / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(ios): one tap turns the iPhone into a controller for Apple TV`.

### Task 8: The pointer is labelled with the phone

**Files:**
- Modify: `Common/Swift/Controllers/PointerSource.swift` (new cases), `Common/Swift/Controllers/PointerSourceLive.swift` (capabilities for DSU devices)
- Test: `DolphiniOSTests/PointerSourceResolverTests.swift`

**Interfaces:**
- Consumes: `PointerPlayer1.from(qualifier:pads:)`, `PointerSourceResolver.resolve(...)`, `sources(player1:remoteHasMotion:platform:)`.
- Produces: `PointerPlayer1.phone(name: String)` for any `DSUClient/` qualifier (name = last path component); `PointerSource.phoneGyro(phoneName: String)` with `Kind.phoneGyro` (raw `"phoneGyro"`; existing raw values unchanged), label `String(format: L("%@ gyro"), phoneName)`, systemImage `"iphone.radiowaves.left.and.right"`. tvOS order: override → pad gyro → pad touchpad → phone gyro → remote gyro → none; `sources` lists it. The tvOS "No pointer" explanation becomes `"Connect a controller with motion, or use your iPhone as the Wii Remote."`. `RemotePointerBinding` needs no change (it binds only for `.remoteGyro`).

- [ ] **Step 1: Failing tests** — `test_tvOS_dsuPhoneAsPlayer1_resolvesToPhoneGyro_labelledWithItsName()`, `test_tvOS_phoneRanksBelowAPadGyroAndAboveTheRemote()`, `test_kindRawValues_areUnchanged_andPhoneGyroIsNew()`, `test_tvOS_noPointerExplanation_mentionsTheIPhone()`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/PointerSourceResolverTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the cases, resolver branch and labels.
- [ ] **Step 4: Run tests + full iOS suite + tvOS build.** Expected: PASS (2,369 + new, 0 failed) / SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(controllers): label the Wii pointer with the phone driving it`.

### Task 9: Find it from the TV — notice row and hub section

**Files:**
- Modify: `Common/Swift/Controllers/NoControllerNotice.swift` (`model(onContinue:onControllers:)` → `model(phoneName: String?, onContinue:onControllers:onUsePhone:)`), `Common/Swift/EmulationScreen.swift` (~549, pass the advertising phone and the handler), `Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift` + `ControllerHubViewModel.swift` (a `"phones"` section from `PhoneControllerService.advertisingPhones`)
- Test: `DolphiniOSTests/NoControllerNoticeTests.swift`, `DolphiniOSTests/ControllerHubModelBuilderTests.swift`

**Interfaces:**
- Consumes: `PhoneControllerService.shared.advertisingPhones`, `connect(pid:)`.
- Produces: notice row id `"use-phone"`: title `"Use %@"` with the advertising phone's name and action `connect(pid:)`, or `"Use Your iPhone"` opening a panel with `"Open iCube on your iPhone and tap Play on Apple TV."` when none is advertising. Hub section `"phones"` (header `"Phones"`, tvOS and iOS host): one row per advertising phone, `"Connect"` / `"Connected"` badge.

- [ ] **Step 1: Failing tests** — `test_notice_offersTheAdvertisingPhoneByName()`, `test_notice_explainsHowWhenNoPhoneIsAdvertising()`, `test_hub_listsAdvertisingPhones_withTheirState()`.
- [ ] **Step 2: Run** those classes. Expected: FAIL.
- [ ] **Step 3: Implement** the rows, panel and wiring.
- [ ] **Step 4: Run tests + full iOS suite + tvOS build + both python checks.** Expected: all pass.
- [ ] **Step 5: Commit** — `feat(tvos): offer the iPhone from the no-controller notice and the hub`.

### Task 10: Device acceptance (owner)

No code. Record results in `docs/app-store/release-evidence/2026-10-23-iphone-wii-remote.md`.

- [ ] Phone: Library → "Play on Apple TV"; Shortcuts/Spotlight → "Use iPhone as Wii Remote". Both open the Wii Remote controller with Gyro.
- [ ] TV: confirm panel names the phone (the iCube device name, not "iPhone"); phone shows its own approval; after both, the TV toasts and the phone is Wii Remote 1 (Wii Remote 2 with a pad on 1).
- [ ] Pointer row reads "Pointer: <phone name> gyro"; the cursor follows the phone in a Wii game with acceptable lag.
- [ ] Lock the phone mid-game: the TV pauses with the disconnect banner; unlock: it reconnects.
- [ ] A PC or third-party DSU server added by hand still works and is untouched.
