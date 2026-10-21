import XCTest
#if !PERFORMANCE_HOST_TESTS
@testable import iCube
#endif

final class PerformanceControlsTests: XCTestCase {
  func testRefreshReadsEveryOpenAndDoesNotWriteBase() {
    var read = PerformanceControlsState()
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { read }, apply: { writes.append($0) }, scheduleRefresh: { _ in })
    read.cpuPercent = 73
    read.viPercent = 84
    read.cpuOverride = .game
    read.viOverride = .auto
    read.adaptiveClock = true
    read.viSkipMode = .auto
    read.hud.vblank = true
    controller.refresh()
    XCTAssertEqual(controller.state.cpuPercent, 73)
    XCTAssertEqual(controller.state.viPercent, 84)
    XCTAssertEqual(controller.state.cpuOverride, .auto)
    XCTAssertTrue(controller.state.adaptiveClock)
    XCTAssertEqual(controller.state.viSkipMode, .auto)
    XCTAssertTrue(controller.state.hud.vblank)
    XCTAssertTrue(writes.isEmpty)
  }

  func testManualChangesCannotWriteGameOrAutomaticOwnedValues() {
    var read = PerformanceControlsState()
    read.cpuOverride = .game
    read.viOverride = .auto
    read.scalingOverride = .game
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { read }, apply: { writes.append($0) })
    for change: PerformanceControlChange in [.cpuEnabled(true), .cpuPercent(10), .viEnabled(true), .viPercent(10), .resolutionScale(3)] {
      controller.apply(change)
    }
    XCTAssertTrue(writes.isEmpty)
    XCTAssertNotNil(controller.state.cpuDisabledReason)
    XCTAssertNotNil(controller.state.viDisabledReason)
    XCTAssertNotNil(controller.state.scalingDisabledReason)
  }

  func testManualPercentBoundsAndEnableReappliesBasePercent() {
    var read = PerformanceControlsState()
    read.cpuPercent = 67
    read.viPercent = 83
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { read }, apply: { writes.append($0) })
    controller.apply(.cpuEnabled(true))
    controller.apply(.viEnabled(true))
    controller.apply(.cpuPercent(0))
    controller.apply(.viPercent(900))
    XCTAssertEqual(writes, [.cpuEnabled(true), .cpuPercent(67), .viEnabled(true), .viPercent(83), .cpuPercent(1), .viPercent(400)])
  }

  func testAdaptiveClockLocksBothControlsBeforeBackendAndUntilRefresh() {
    var read = PerformanceControlsState()
    var deferred: (() -> Void)?
    var writes: [PerformanceControlChange] = []
    var controller: PerformanceControlsController!
    controller = PerformanceControlsController(read: { read }, apply: {
      XCTAssertEqual(controller.state.cpuOverride, .auto)
      XCTAssertEqual(controller.state.viOverride, .auto)
      writes.append($0)
    }, scheduleRefresh: { deferred = $0 })
    controller.apply(.adaptiveClock(true))
    controller.apply(.cpuPercent(90))
    controller.apply(.viPercent(90))
    XCTAssertEqual(writes, [.adaptiveClock(true)])
    XCTAssertNotNil(deferred)
    read.adaptiveClock = true
    deferred?()
    XCTAssertTrue(controller.state.adaptiveClock)
    XCTAssertEqual(controller.state.cpuOverride, .auto)
  }

  func testTurningAdaptiveOffKeepsManualControlsLockedUntilAsyncReconciliation() {
    var read = PerformanceControlsState()
    read.adaptiveClock = true
    read.cpuOverride = .auto
    read.viOverride = .auto
    var deferred: (() -> Void)?
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { read }, apply: { writes.append($0) }, scheduleRefresh: { deferred = $0 })
    controller.apply(.adaptiveClock(false))
    controller.apply(.cpuEnabled(true))
    XCTAssertEqual(writes, [.adaptiveClock(false)])
    read.adaptiveClock = false
    read.cpuOverride = .game
    read.viOverride = .none
    deferred?()
    XCTAssertEqual(controller.state.cpuOverride, .game)
    XCTAssertEqual(controller.state.viOverride, .none)
  }

  func testAdaptiveOffReconcilesAgainWhenFirstReadStillHasAutomaticOwnership() {
    var read = PerformanceControlsState()
    read.adaptiveClock = true
    read.cpuOverride = .auto
    read.viOverride = .auto
    var queued: [() -> Void] = []
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { read }, apply: { writes.append($0) }, scheduleRefresh: { queued.append($0) })
    controller.apply(.adaptiveClock(false))
    read.adaptiveClock = false
    queued.removeFirst()()
    XCTAssertEqual(controller.state.viOverride, .auto)
    guard !queued.isEmpty else { return XCTFail("A delayed native clear needs another reconciliation") }
    read.cpuOverride = .game
    read.viOverride = .none
    queued.removeFirst()()
    XCTAssertEqual(controller.state.cpuOverride, .game)
    XCTAssertEqual(controller.state.viOverride, .none)
    XCTAssertTrue(queued.isEmpty)
    XCTAssertEqual(writes, [.adaptiveClock(false)])
  }

  func testNewToggleSupersedesOlderRefreshCallbacks() {
    var read = PerformanceControlsState()
    var queued: [() -> Void] = []
    var readCount = 0
    let controller = PerformanceControlsController(read: { readCount += 1; return read }, apply: { _ in }, scheduleRefresh: { queued.append($0) })
    controller.apply(.adaptiveClock(true))
    controller.apply(.adaptiveClock(false))
    let countBeforeStaleCallback = readCount
    queued.removeFirst()()
    XCTAssertEqual(readCount, countBeforeStaleCallback)
    read.cpuOverride = .game
    queued.removeFirst()()
    XCTAssertFalse(controller.state.adaptiveClock)
    XCTAssertEqual(controller.state.cpuOverride, .game)
    XCTAssertTrue(queued.isEmpty)
  }

  func testClosingSurfaceInvalidatesQueuedReconciliationAndReopenRestartsIt() {
    var read = PerformanceControlsState()
    read.adaptiveClock = true
    read.cpuOverride = .auto
    read.viOverride = .auto
    var queued: [() -> Void] = []
    var readCount = 0
    let controller = PerformanceControlsController(read: { readCount += 1; return read }, apply: { _ in }, scheduleRefresh: { queued.append($0) })
    controller.apply(.adaptiveClock(false))
    controller.stopRefreshing()
    let countBeforeCloseCallback = readCount
    queued.removeFirst()()
    XCTAssertEqual(readCount, countBeforeCloseCallback)
    XCTAssertTrue(queued.isEmpty)
    read.adaptiveClock = false
    controller.refresh()
    guard !queued.isEmpty else { return XCTFail("Reopening must resume delayed ownership reconciliation") }
    read.cpuOverride = .none
    read.viOverride = .game
    queued.removeFirst()()
    XCTAssertEqual(controller.state.cpuOverride, .none)
    XCTAssertEqual(controller.state.viOverride, .game)
  }

  func testReconciliationStopsAtNewSessionAndDisposedController() {
    var session: UInt64 = 11
    var queued: [() -> Void] = []
    var readCount = 0
    var controller: PerformanceControlsController? = PerformanceControlsController(
      read: { readCount += 1; return PerformanceControlsState() }, apply: { _ in },
      sessionIdentifier: { session }, scheduleRefresh: { queued.append($0) })
    controller?.apply(.adaptiveClock(true))
    session = 12
    let countBeforeNewSession = readCount
    queued.removeFirst()()
    XCTAssertEqual(readCount, countBeforeNewSession)
    XCTAssertTrue(queued.isEmpty)
    controller?.refresh()
    controller?.apply(.adaptiveClock(true))
    weak var weakController = controller
    controller = nil
    XCTAssertNil(weakController)
    let countBeforeDisposal = readCount
    queued.removeFirst()()
    XCTAssertEqual(readCount, countBeforeDisposal)
    XCTAssertTrue(queued.isEmpty)
  }

  func testManualWritesFromOldSessionAreRejectedUntilExplicitRefresh() {
    var session: UInt64 = 5
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { PerformanceControlsState() }, apply: { writes.append($0) }, sessionIdentifier: { session })
    session = 6
    controller.apply(.cpuEnabled(true))
    controller.apply(.adaptiveClock(true))
    XCTAssertTrue(writes.isEmpty)
    controller.refresh()
    controller.apply(.cpuEnabled(true))
    XCTAssertEqual(writes, [.cpuEnabled(true), .cpuPercent(100)])
  }

  func testHUDMasterAndPerStatisticChangesUseTypedWriters() {
    var writes: [PerformanceControlChange] = []
    let controller = PerformanceControlsController(read: { PerformanceControlsState() }, apply: { writes.append($0) })
    controller.apply(.hudEnabled(true))
    for statistic in PerformanceHUDStatistic.allCases { controller.apply(.hudStatistic(statistic, true)) }
    XCTAssertEqual(writes.count, 7)
    XCTAssertEqual(writes.first, .hudEnabled(true))
    XCTAssertEqual(writes.last, .hudStatistic(.overlayStats, true))
  }

  func testResolutionAndVISkipAreExplicitChoicesAndClockPercentUsesBoundedControl() {
    var read = PerformanceControlsState()
    read.maxResolutionScale = 3
    var changes: [PerformanceControlChange] = []
    let model = PerformanceControlsModelBuilder.build(state: read) { changes.append($0) }
    guard case .picker(let options, let selection)? = model.item(id: "performance-resolution")?.role else { return XCTFail("Resolution must offer direct choices") }
    XCTAssertEqual(options.map(\.0), ["Fit Window", "1x (Native)", "2x", "3x"])
    selection.wrappedValue = AnyHashable(0)
    XCTAssertEqual(changes, [.resolutionScale(0)])
    guard case .picker(let skipOptions, let skipSelection)? = model.item(id: "performance-vi-skip")?.role else { return XCTFail("VI Skip must offer direct choices") }
    XCTAssertEqual(skipOptions.map(\.0), ["Off", "On", "Auto"])
    skipSelection.wrappedValue = AnyHashable(PerformanceVISkipMode.auto)
    XCTAssertEqual(changes.last, .viSkipMode(.auto))
    guard case .stepper(let percent)? = model.item(id: "performance-cpu-percent")?.role else { return XCTFail("CPU needs a bounded adjustment") }
    XCTAssertEqual(percent.range, 1...400)
    XCTAssertFalse(model.item(id: "performance-cpu-percent")!.isEnabled)
    XCTAssertEqual(model.allItems.filter { $0.id.hasPrefix("performance-hud-") }.count, 7)
  }

  func testAnisotropyChoicesOfferOnlyValuesTheBackendCanRepresent() {
    var changes: [PerformanceControlChange] = []
    let model = PerformanceControlsModelBuilder.build(state: PerformanceControlsState()) { changes.append($0) }
    guard case .picker(let options, let selection)? = model.item(id: "performance-anisotropy")?.role else { return XCTFail("Missing anisotropy choices") }
    XCTAssertEqual(options.map(\.0), ["1x", "2x", "4x", "8x", "16x"])
    selection.wrappedValue = AnyHashable(8)
    XCTAssertEqual(changes, [.anisotropy(8)])
  }

  func testGameProvenanceDisablesRowsAndExplainsWhy() {
    var read = PerformanceControlsState()
    read.cpuOverride = .game
    read.viOverride = .auto
    read.scalingOverride = .game
    let model = PerformanceControlsModelBuilder.build(state: read) { _ in XCTFail("Disabled activation wrote") }
    for id in ["performance-cpu-enabled", "performance-cpu-percent", "performance-vi-enabled", "performance-vi-percent", "performance-resolution"] {
      guard let item = model.item(id: id) else { return XCTFail("Missing control: \(id)") }
      XCTAssertFalse(item.isEnabled)
      XCTAssertNotNil(item.disabledReason)
      _ = item.activateInPlace()
    }
    XCTAssertEqual(model.item(id: "performance-cpu-enabled")?.badge, "Game")
    XCTAssertEqual(model.item(id: "performance-vi-enabled")?.badge, "Auto")
  }
}
