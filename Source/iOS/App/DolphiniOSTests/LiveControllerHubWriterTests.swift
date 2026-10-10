// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `LiveControllerHubWriter` itself, against an injected `PlayerScreenIO` and hub reader: what
/// `assign` reports, what `clear` writes, and the gyro-pointer re-enable. The IO fake follows a
/// device write into the reader, as the real config does.
final class LiveControllerHubWriterTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dualSense = "MFi/1/DualSense Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"

  private func pad(_ qualifier: String, gyro: Bool = false) -> ConnectedPadState {
    ConnectedPadState(qualifier: qualifier, name: qualifier, batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: gyro)
  }

  /// The reader reflects what the IO bound; `connected` is the set of pads `setDevice` can bind
  /// (a DSU device or a disconnected pad binds nothing, as `PlayerScreenIO.setDevice` returns early).
  /// A Touchscreen binds the instance of the slot's kind: GameCube 0-3, Wii 4-7.
  @MainActor
  private func make(connected: Set<String> = []) -> (LiveControllerHubWriter, FakePlayerHubReader, FakePlayerScreenIO) {
    let reader = FakePlayerHubReader()
    let io = FakePlayerScreenIO()
    io.onSetDeviceForSlot = { choice, slot in
      var bound: String?
      switch choice {
      case .noDevice: bound = ""
      case .touchscreen: bound = slot.kind == .gameCube ? "iOS/\(slot.port - 1)/Touchscreen" : "iOS/\(slot.port + 3)/Touchscreen"
      case .pad(let qualifier): bound = connected.contains(qualifier) ? qualifier : nil
      case .automatic: bound = nil
      }
      guard let bound else { return }
      if slot.kind == .gameCube { reader.gameCube[slot.port] = bound } else { reader.wii[slot.port] = bound }
    }
    return (LiveControllerHubWriter(io: io, reader: reader), reader, io)
  }

  // MARK: assign

  @MainActor
  func test_assign_aConnectedPad_bindsAndReportsSuccess() {
    let (writer, reader, io) = make(connected: [Self.xbox])
    XCTAssertTrue(writer.assign(qualifier: Self.xbox, slot: PlayerSlot(kind: .gameCube, port: 2)))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.xbox)\")"])
    XCTAssertEqual(reader.gameCube[2], Self.xbox)
  }

  @MainActor
  func test_assign_aDisconnectedPadOrADSUDevice_bindsNothingAndReportsFailure() {
    let (writer, reader, _) = make(connected: [Self.xbox])
    XCTAssertFalse(writer.assign(qualifier: Self.dualSense, slot: PlayerSlot(kind: .wiiRemote, port: 1)), "not connected")
    XCTAssertFalse(writer.assign(qualifier: Self.dsu, slot: PlayerSlot(kind: .gameCube, port: 1)), "DSU cannot be bound")
    XCTAssertEqual(reader.wii[1] ?? "", "")
    XCTAssertEqual(reader.gameCube[1] ?? "", "")
  }

  @MainActor
  func test_assign_aPadWhoseSlotKeepsADifferentDevice_reportsFailure() {
    let (writer, reader, _) = make(connected: [])
    reader.gameCube[1] = Self.xbox
    XCTAssertFalse(writer.assign(qualifier: Self.dualSense, slot: PlayerSlot(kind: .gameCube, port: 1)), "the slot still reads the old pad")
  }

  /// A Touchscreen qualifier is re-resolved for the DESTINATION's kind: the request is `.touchscreen`
  /// whatever instance id it carries, and the instance read back may differ from the request.
  @MainActor
  func test_assign_touchscreenAcrossKinds_requestsTheTouchscreenAndAcceptsTheDestinationInstance() {
    let (writer, reader, io) = make()
    XCTAssertTrue(writer.assign(qualifier: "iOS/4/Touchscreen", slot: PlayerSlot(kind: .gameCube, port: 1)))
    XCTAssertEqual(reader.gameCube[1], "iOS/0/Touchscreen", "GameCube instance")
    XCTAssertTrue(writer.assign(qualifier: "iOS/1/Touchscreen", slot: PlayerSlot(kind: .wiiRemote, port: 2)))
    XCTAssertEqual(reader.wii[2], "iOS/5/Touchscreen", "Wii instance")
    XCTAssertEqual(io.writes, ["device:touchscreen", "device:touchscreen"])
  }

  // MARK: clear

  @MainActor
  func test_clear_unbindsAndUnpinsTheSlot() {
    let (writer, reader, io) = make(connected: [Self.xbox])
    reader.wii[3] = Self.xbox
    io.pinned = true
    writer.clear(slot: PlayerSlot(kind: .wiiRemote, port: 3))
    XCTAssertEqual(io.writes, ["device:noDevice"])
    XCTAssertEqual(reader.wii[3], "")
    XCTAssertFalse(io.pinned)
  }

  // MARK: Gyro pointer (decision 12)

  @MainActor
  func test_setDevice_aGyroPadOnAWiiRemote_turnsTheMotionPointerOn() {
    let (writer, reader, io) = make(connected: [Self.dualSense])
    reader.pads = [pad(Self.dualSense, gyro: true)]
    writer.setDevice(.pad(Self.dualSense), slot: PlayerSlot(kind: .wiiRemote, port: 2))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.dualSense)\")", "motion-pointer:true"])
  }

  @MainActor
  func test_setDevice_noGyro_orNotAWiiRemote_leavesTheMotionPointerAlone() {
    let (writer, reader, io) = make(connected: [Self.xbox, Self.dualSense])
    reader.pads = [pad(Self.xbox), pad(Self.dualSense, gyro: true)]
    writer.setDevice(.pad(Self.xbox), slot: PlayerSlot(kind: .wiiRemote, port: 1))
    writer.setDevice(.pad(Self.dualSense), slot: PlayerSlot(kind: .gameCube, port: 1))
    writer.setDevice(.touchscreen, slot: PlayerSlot(kind: .wiiRemote, port: 1))
    XCTAssertFalse(io.writes.contains("motion-pointer:true"))
  }

  /// `assign` goes through `setDevice`, so a Plays as move of a gyro pad onto a Wii Remote re-enables
  /// the pointer too.
  @MainActor
  func test_assign_aGyroPadOntoAWiiRemote_turnsTheMotionPointerOn() {
    let (writer, reader, io) = make(connected: [Self.dualSense])
    reader.pads = [pad(Self.dualSense, gyro: true)]
    XCTAssertTrue(writer.assign(qualifier: Self.dualSense, slot: PlayerSlot(kind: .wiiRemote, port: 1)))
    XCTAssertTrue(io.writes.contains("motion-pointer:true"))
  }

  // MARK: Passthrough

  @MainActor
  func test_wiimoteAndPointerSettings_goThroughTheIO() {
    let (writer, _, io) = make()
    writer.setExtension(2, wiimote: 1)
    writer.setSideways(true, wiimote: 1)
    writer.setPointerMode(.gyro)
    writer.setMotionPointer(false, wiimote: 3)
    XCTAssertEqual(io.writes, ["extension:2", "sideways:true", "pointer:gyro", "motion-pointer:false"])
  }
}
