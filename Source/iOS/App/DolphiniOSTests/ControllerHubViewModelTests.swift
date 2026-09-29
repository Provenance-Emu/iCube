// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `ControllerHubViewModel` against a fake reader: which ports it reads in which order, and that
/// it reloads on assignment changes only while started. Observers deliver on the main queue, so
/// the notification tests wait on expectations instead of assuming inline delivery.
final class ControllerHubViewModelTests: XCTestCase {

  @MainActor
  private final class FakeReader: ControllerHubReading {
    var gameCube: [Int: String] = [:]
    var wii: [Int: String] = [:]
    var extensions: [Int: Int] = [:]
    var sideways: Set<Int> = []
    var pads: [ConnectedPadState] = []
    /// Counts snapshots: `reload()` asks for the pads exactly once.
    var padReads = 0
    var onPadRead: (() -> Void)?

    func boundQualifier(forGCPort port: Int) -> String { gameCube[port] ?? "" }
    func boundQualifier(forWiimote index: Int) -> String { wii[index] ?? "" }
    func wiiExtension(forWiimote index: Int) -> Int { extensions[index] ?? 0 }
    func isSideways(forWiimote index: Int) -> Bool { sideways.contains(index) }
    func connectedPads() -> [ConnectedPadState] {
      padReads += 1
      onPadRead?()
      return pads
    }
    func isGameRunning() -> Bool { true }
    func overlayVisible() -> Bool { true }
    func overlayMode() -> ControllerManager.OverlayMode { .wii }
    func overlayOpacity() -> Float { 0.62 }
    func continuousScanning() -> Bool { false }
    func dsuClientEnabled() -> Bool { true }
    func dsuServerCount() -> Int { 3 }
  }

  @MainActor
  func test_reload_readsEveryPortInTheSystemsOrder() {
    let reader = FakeReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    reader.extensions[1] = 1
    reader.sideways = [2]
    reader.gameCube[2] = "MFi/0/Xbox Wireless Controller"
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, notificationCenter: NotificationCenter())

    model.reload()

    XCTAssertEqual(model.state.players.map(\.id), ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"])
    XCTAssertEqual(model.state.players[0].deviceQualifier, "iOS/4/Touchscreen")
    XCTAssertEqual(model.state.players[0].wiiExtension, 1)
    XCTAssertTrue(model.state.players[1].isSideways)
    XCTAssertEqual(model.state.players[5].deviceQualifier, "MFi/0/Xbox Wireless Controller")
    XCTAssertEqual(model.state.players[5].wiiExtension, 0, "GameCube ports carry no extension")
  }

  @MainActor
  func test_reload_snapshotsTheOverlayAndDevices() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    XCTAssertTrue(model.state.isGameRunning)
    XCTAssertEqual(model.state.overlayMode, .wii)
    XCTAssertEqual(model.state.overlayOpacityPercent, 50, "0.62 snaps to 50 %")
    XCTAssertTrue(model.state.dsuClientEnabled)
    XCTAssertEqual(model.state.dsuServerCount, 3)
  }

  @MainActor
  func test_showAllPorts_survivesAReload() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    model.actions.toggleShowAllPorts()
    model.reload()
    XCTAssertTrue(model.state.showAllPorts)
  }

  @MainActor
  func test_start_reloadsWhenAssignmentsChange() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    XCTAssertEqual(reader.padReads, 1, "start() takes the first snapshot")

    let reloaded = expectation(description: "reloaded on assignmentsChanged")
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 1)
    model.stop()
  }

  @MainActor
  func test_stop_removesTheObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.stop()

    let reloaded = expectation(description: "no reload after stop()")
    reloaded.isInverted = true
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 0.3)
  }

  @MainActor
  func test_start_twice_installsOneSetOfObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.start()
    reader.padReads = 0

    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    // Drain the main queue: delivery may be deferred, and a second observer would add a read.
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(reader.padReads, 1, "exactly one reload per notice")
    model.stop()
  }
}
