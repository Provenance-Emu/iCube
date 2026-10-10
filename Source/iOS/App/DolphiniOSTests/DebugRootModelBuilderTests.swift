// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class DebugRootModelBuilderTests: XCTestCase {
  private var changes: [DebugRootChange] = []
  private func model(_ state: DebugRootState = DebugRootState()) -> MenuModel {
    DebugRootModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout DebugRootState) -> Void) -> DebugRootState {
    var s = DebugRootState()
    edit(&s)
    return s
  }
  private func isOn(_ item: MenuItem?) -> Bool? {
    guard case .toggle(let binding)? = item?.role else { return nil }
    return binding.wrappedValue
  }
  private func run(_ item: MenuItem?) {
    switch item?.role {
    case .action(let run)?, .destructive(let run)?: run()
    default: XCTFail("\(item?.id ?? "nil") is not an action")
    }
  }

  /// A device with everything switched on: a blocked handshake, a TXM device with StikDebug and no broker, a token and approved devices.
  private var populated: DebugRootState {
    state {
      $0.benchToken = "abc123"
      $0.hydrated = DebugHydratedState(userFolder: "/var/mobile/iCube", fastmemAvailable: true, jitAcquired: false, jitError: "denied",
                                       debuggerAttached: false, txmAuthorized: false, txmHandshakeBlocked: true, deviceHasTxm: true,
                                       jitSupported: true, stikDebugInstalled: true, approvedClients: ["10.0.0.2", "10.0.0.3"])
    }
  }

  /// Rows that only exist in a DEBUG build, in screen order.
  private var debugOnlyDiagnostics: [String] {
    var ids: [String] = []
    #if DEBUG && canImport(CoreMotion)
    ids.append("motion-debug")
    #endif
    #if os(iOS) && DEBUG
    ids.append("gallery")
    #endif
    return ids
  }

  // MARK: Structure

  func test_sections_inOrder_withHeaders() {
    let m = model()
    XCTAssertEqual(m.sections.map(\.id), ["cpu-memory", "recording", "environment", "diagnostics", "rendering", "logging", "screenshots-artwork"])
    XCTAssertEqual(m.sections.map(\.header), ["CPU / Memory", "Recording", "Environment", "Diagnostics", "Rendering", "Logging", "Screenshots / Artwork"])
  }

  func test_rowOrder_defaultState() {
    let expected = ["fastmem", "instant-replay",
                    "user-folder", "jit-status", "debugger-status", "jit-error", "jit-guide", "fastmem-available",
                    "launch-times", "reset-launch-times"] + debugOnlyDiagnostics + ["stall-metrics", "perf-bench",
                    "wireframe", "console-logging", "logging-verbosity", "input-debug", "template-covers"]
    XCTAssertEqual(model().allItems.map(\.id), expected)
  }

  func test_rowOrder_populatedState() {
    let expected = ["fastmem", "instant-replay",
                    "user-folder", "jit-status", "debugger-status", "txm-region", "jit-error", "retry-jit-authorization",
                    "enable-jit-stikdebug", "stikdebug-help", "jit-guide", "fastmem-available",
                    "launch-times", "reset-launch-times"] + debugOnlyDiagnostics + ["stall-metrics", "perf-bench", "bench-token", "forget-approved-devices",
                    "wireframe", "console-logging", "logging-verbosity", "input-debug", "template-covers"]
    XCTAssertEqual(model(populated).allItems.map(\.id), expected)
  }

  func test_everyRow_hasADescription() {
    for s in [DebugRootState(), populated, state { $0.isIOS = false }] {
      for item in model(s).allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
    }
  }

  func test_rowIDs_areUnique_andFastmemRowsAreDistinct() {
    let ids = model(populated).allItems.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count)
    XCTAssertEqual(model().item(id: "fastmem")?.title, model().item(id: "fastmem-available")?.title, "the old view had two rows titled Fastmem")
  }

  func test_recordingSection_isAbsentOffIOS() {
    let m = model(state { $0.isIOS = false })
    XCTAssertFalse(m.sections.contains { $0.id == "recording" })
    XCTAssertNil(m.item(id: "instant-replay"))
  }

  // MARK: Toggles

  func test_everyToggleRow_readsAndEmitsItsOwnChange() {
    let rows: [(String, WritableKeyPath<DebugRootState, Bool>, (Bool) -> DebugRootChange)] = [
      ("instant-replay", \.instantReplay, { .instantReplay($0) }),
      ("stall-metrics", \.stallMetrics, { .stallMetrics($0) }),
      ("perf-bench", \.benchEnabled, { .perfBench($0) }),
      ("wireframe", \.wireframe, { .wireframe($0) }),
      ("console-logging", \.loggingEnabled, { .consoleLogging($0) }),
      ("input-debug", \.inputDebug, { .inputDebug($0) }),
      ("template-covers", \.disableArtwork, { .templateCovers($0) }),
    ]
    let all = rows.map { $0.1 }
    for (id, keyPath, change) in rows {
      for value in [true, false] {
        // Only this field differs, so the row reads it and nothing else.
        var s = DebugRootState()
        for other in all { s[keyPath: other] = !value }
        s[keyPath: keyPath] = value
        guard case .toggle(let binding)? = model(s).item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
        XCTAssertEqual(binding.wrappedValue, value, id)
        for other in rows where other.0 != id { XCTAssertEqual(isOn(model(s).item(id: other.0)), !value, "\(other.0) must not read \(id)") }
        changes = []
        binding.wrappedValue = !value
        XCTAssertEqual(changes, [change(!value)], id)
      }
    }
  }

  func test_fastmem_readsAndEmits() {
    for value in [true, false] {
      guard case .toggle(let binding)? = model(state { $0.fastmem = value }).item(id: "fastmem")?.role else { return XCTFail("toggle") }
      XCTAssertEqual(binding.wrappedValue, value)
      changes = []
      binding.wrappedValue = !value
      XCTAssertEqual(changes, [.fastmem(!value)])
    }
  }

  func test_fastmem_isEnabledOnlyWhenAvailable() {
    XCTAssertEqual(model(state { $0.hydrated.fastmemAvailable = false }).item(id: "fastmem")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.hydrated.fastmemAvailable = true }).item(id: "fastmem")?.isEnabled, true)
  }

  // MARK: Verbosity

  func test_loggingVerbosity_offersOneToFive_andEmits() {
    guard case .cycle(let options, let selection)? = model(state { $0.loggingVerbosity = 4 }).item(id: "logging-verbosity")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["1", "2", "3", "4", "5"])
    XCTAssertEqual(options.map { $0.1 }, [1, 2, 3, 4, 5].map { AnyHashable($0) })
    XCTAssertEqual(selection.wrappedValue, AnyHashable(4))
    changes = []
    selection.wrappedValue = AnyHashable(5)
    XCTAssertEqual(changes, [.loggingVerbosity(5)])
  }

  func test_loggingVerbosity_wrapsFiveToOne_likeTheOldButton() {
    let next = MenuItemRole.cycled(options: DebugRootState.verbosityLevels.map { ("\($0)", AnyHashable($0)) }, current: AnyHashable(5), step: 1)
    XCTAssertEqual(next, AnyHashable(1))
  }

  func test_normalizedVerbosity() {
    let fallback = LoggerIniMigration.defaultVerbosity
    let rows: [(Int, Int)] = [(0, fallback), (-1, fallback), (6, fallback), (99, fallback), (1, 1), (3, 3), (5, 5)]
    for (stored, expected) in rows { XCTAssertEqual(DebugRootState.normalizedVerbosity(stored), expected, "\(stored)") }
    XCTAssertEqual(DebugRootState().loggingVerbosity, fallback)
  }

  // MARK: Actions

  func test_actionRows_emitTheirChange() {
    let rows: [(String, DebugRootChange)] = [
      ("retry-jit-authorization", .retryJitAuthorization),
      ("reset-launch-times", .resetLaunchTimes),
      ("enable-jit-stikdebug", .enableJitViaStikDebug),
      ("forget-approved-devices", .forgetApprovedDevices),
    ]
    let m = model(populated)
    for (id, change) in rows {
      changes = []
      run(m.item(id: id))
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_forgetApprovedDevices_isDestructive_andNamesTheDevices() {
    let item = model(populated).item(id: "forget-approved-devices")
    guard case .destructive? = item?.role else { return XCTFail("destructive") }
    XCTAssertEqual(item?.title, "Forget 2 Approved Device(s)")
    XCTAssertEqual(item?.description, "Currently allowed without prompting: 10.0.0.2, 10.0.0.3")
  }

  func test_forgetApprovedDevices_isAbsentForAnEmptyList() {
    XCTAssertNil(model().item(id: "forget-approved-devices"))
  }

  func test_retryJitAuthorization_onlyWhenTheHandshakeIsBlocked() {
    XCTAssertNil(model(state { $0.hydrated.txmHandshakeBlocked = false }).item(id: "retry-jit-authorization"))
    XCTAssertNotNil(model(state { $0.hydrated.txmHandshakeBlocked = true }).item(id: "retry-jit-authorization"))
  }

  // MARK: Status rows

  func test_statusRows_areDisabledAndShowTheirValue() {
    let off = model(state { $0.launchTimes = 7 })
    let on = model(populated)
    let rows: [(String, String, String)] = [
      ("jit-status", "Not Acquired", "Acquired"),
      ("debugger-status", "Not Attached", "Attached"),
      ("txm-region", "Not Authorized", "Authorized"),
      ("fastmem-available", "Not Available", "Available"),
    ]
    for (id, offBadge, onBadge) in rows {
      var s = populated
      s.hydrated.jitAcquired = true; s.hydrated.debuggerAttached = true; s.hydrated.txmAuthorized = true; s.hydrated.fastmemAvailable = true
      XCTAssertEqual(on.item(id: id)?.isEnabled, false, id)
      XCTAssertEqual(model(s).item(id: id)?.badge, onBadge, id)
      var d = populated
      d.hydrated.jitAcquired = false; d.hydrated.debuggerAttached = false; d.hydrated.txmAuthorized = false; d.hydrated.fastmemAvailable = false
      XCTAssertEqual(model(d).item(id: id)?.badge, offBadge, id)
    }
    XCTAssertEqual(off.item(id: "launch-times")?.badge, "7")
    XCTAssertEqual(off.item(id: "launch-times")?.isEnabled, false)
  }

  func test_txmRegion_onlyOnATxmDevice() {
    XCTAssertNil(model(state { $0.hydrated.deviceHasTxm = false }).item(id: "txm-region"))
    XCTAssertNotNil(model(state { $0.hydrated.deviceHasTxm = true }).item(id: "txm-region"))
  }

  func test_userFolderAndJitError_carryTheirValueInTheDescription() {
    let m = model(populated)
    XCTAssertTrue(m.item(id: "user-folder")?.description?.contains("/var/mobile/iCube") == true)
    XCTAssertNil(m.item(id: "user-folder")?.badge)
    XCTAssertTrue(m.item(id: "jit-error")?.description?.hasSuffix("denied") == true)
    XCTAssertTrue(model().item(id: "jit-error")?.description?.hasSuffix("(none)") == true)
  }

  // MARK: Bench token

  func test_benchToken_isShownOnlyWhenPresent() {
    XCTAssertNil(model(state { $0.benchToken = "" }).item(id: "bench-token"))
    guard case .custom? = model(state { $0.benchToken = "tok" }).item(id: "bench-token")?.role else { return XCTFail("custom") }
  }

  // MARK: StikDebug

  func test_showsStikDebugEnable_truthTable() {
    // (isIOS, jitSupported, deviceHasTxm, stikDebugInstalled, jitAcquired, txmAuthorized, debuggerAttached) -> shown
    let rows: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, String)] = [
      (true, true, true, true, false, false, false, true, "not acquired"),
      (true, true, true, true, true, false, false, true, "acquired on TXM with no broker and no region"),
      (true, true, true, true, true, true, false, false, "acquired and authorized"),
      (true, true, true, true, true, false, true, false, "acquired with a debugger attached"),
      (true, true, true, true, false, true, true, true, "not acquired, whatever else is true"),
      (true, false, true, true, false, false, false, false, "JIT unsupported"),
      (true, true, false, true, false, false, false, false, "no TXM"),
      (true, true, true, false, false, false, false, false, "StikDebug missing"),
      (false, true, true, true, false, false, false, false, "not iOS"),
    ]
    for (ios, supported, txm, installed, acquired, authorized, attached, shown, why) in rows {
      let s = state {
        $0.isIOS = ios
        $0.hydrated.jitSupported = supported; $0.hydrated.deviceHasTxm = txm; $0.hydrated.stikDebugInstalled = installed
        $0.hydrated.jitAcquired = acquired; $0.hydrated.txmAuthorized = authorized; $0.hydrated.debuggerAttached = attached
      }
      XCTAssertEqual(s.showsStikDebugEnable, shown, why)
      XCTAssertEqual(model(s).item(id: "enable-jit-stikdebug") != nil, shown, why)
    }
  }

  func test_stikDebugHelp_needsTheEnableRow_andNoAttachment() {
    let rows: [(Bool, Bool, Bool, Bool, String)] = [
      // (jitAcquired, debuggerAttached, txmAuthorized) -> help shown
      (false, false, false, true, "asked and did not attach"),
      (false, true, false, false, "debugger attached"),
      (false, false, true, false, "region authorized"),
      (true, false, false, true, "acquired on TXM, still no broker"),
    ]
    for (acquired, attached, authorized, shown, why) in rows {
      let s = state {
        $0.hydrated.jitSupported = true; $0.hydrated.deviceHasTxm = true; $0.hydrated.stikDebugInstalled = true
        $0.hydrated.jitAcquired = acquired; $0.hydrated.debuggerAttached = attached; $0.hydrated.txmAuthorized = authorized
      }
      XCTAssertEqual(model(s).item(id: "stikdebug-help") != nil, shown, why)
    }
    // The help follows the enable row: with StikDebug missing neither shows, even with nothing attached.
    let missing = state { $0.hydrated.jitSupported = true; $0.hydrated.deviceHasTxm = true; $0.hydrated.stikDebugInstalled = false }
    XCTAssertNil(model(missing).item(id: "stikdebug-help"))
  }

  func test_stikDebugHelp_isAReadOnlyCaption() {
    let item = model(populated).item(id: "stikdebug-help")
    XCTAssertEqual(item?.isEnabled, false)
    XCTAssertTrue(item?.title.contains("Reset Developer Disk Image") == true)
  }

  // MARK: Destinations

  func test_jitGuide_isADestination() {
    guard case .destination? = model().item(id: "jit-guide")?.role else { return XCTFail("destination") }
  }

  #if DEBUG && canImport(CoreMotion)
  func test_motionDebug_isADestinationWithItsIcon() {
    let item = model().item(id: "motion-debug")
    guard case .destination? = item?.role else { return XCTFail("destination") }
    XCTAssertEqual(item?.icon, "sensor.tag.radiowaves.forward")
  }
  #endif

  #if os(iOS) && DEBUG
  func test_gallery_isADestination() {
    let item = model().item(id: "gallery")
    guard case .destination? = item?.role else { return XCTFail("destination") }
    XCTAssertEqual(item?.title, "Gallery")
  }
  #endif

  // MARK: State

  func test_defaults_matchTheOldView() {
    let s = DebugRootState()
    XCTAssertEqual(s.isIOS, true)
    XCTAssertEqual([s.fastmem, s.stallMetrics, s.benchEnabled, s.wireframe, s.loggingEnabled, s.inputDebug, s.instantReplay, s.disableArtwork], Array(repeating: false, count: 8))
    XCTAssertEqual(s.launchTimes, 0)
    XCTAssertEqual(s.benchToken, "")
    XCTAssertEqual(s.hydrated, DebugHydratedState())
  }

  func test_defaultsKeys_areTheOnesTheOldViewWrote() {
    XCTAssertEqual(DebugDefaultsKey.instantReplay, "replaykit_instant_replay_enabled")
    XCTAssertEqual(DebugDefaultsKey.launchTimes, "launch_times")
    XCTAssertEqual(DebugDefaultsKey.benchEnabled, "ICubeBenchServerEnabled")
    XCTAssertEqual(DebugDefaultsKey.benchToken, "ICubeBenchServerToken")
    XCTAssertEqual(DebugDefaultsKey.loggingEnabled, "logger_console_enabled")
    XCTAssertEqual(DebugDefaultsKey.loggingVerbosity, "logger_console_verbosity")
    XCTAssertEqual(DebugDefaultsKey.inputDebug, "input_debug")
    XCTAssertEqual(DebugDefaultsKey.disableArtwork, "library_disable_artwork")
  }
}
