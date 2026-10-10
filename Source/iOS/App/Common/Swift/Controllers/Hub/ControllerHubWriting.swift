// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Everything the hub writes, behind one seam (the mirror of `ControllerHubReading`).
@MainActor
protocol ControllerHubWriting {
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
  /// True only when the slot is now bound to the same device as `qualifier`, read back after the
  /// write (any Touchscreen instance counts as the Touchscreen: its id depends on the slot's kind). A
  /// DSU device or a disconnected pad cannot be bound by `PlayerScreenIO.setDevice` (it returns
  /// without binding), and a Plays as move must not clear the old slot then.
  func assign(qualifier: String, slot: PlayerSlot) -> Bool
  /// Unbinds the slot's device and unpins the slot.
  func clear(slot: PlayerSlot)
  func setExtension(_ value: Int, wiimote: Int)
  func setSideways(_ enabled: Bool, wiimote: Int)
  func setPointerMode(_ mode: PointerMode)
  func setMotionPointer(_ enabled: Bool, wiimote: Int)
  func setOverlayMode(_ mode: ControllerManager.OverlayMode)
  func setBackgroundInput(_ enabled: Bool)
  func setRumbleDestination(_ value: RumbleDestination)
  func setConnectTakesPlayer1(_ enabled: Bool)
  func testRumble()
  func resetOverlayLayouts()
  func setTouchOverlayProgrammatic(_ enabled: Bool)
}

struct LiveControllerHubWriter: ControllerHubWriting {
  private let io: any PlayerScreenIO
  private let reader: any ControllerHubReading

  /// The production seam: the live player-screen IO and hub reader. Explicit and `nonisolated`, as
  /// its siblings' are, so it can be a default argument of the main-actor view model's `init`.
  nonisolated init() {
    io = LivePlayerScreenIO()
    reader = LiveControllerHubReader()
  }

  /// Tests inject fakes for both.
  init(io: any PlayerScreenIO, reader: any ControllerHubReading) {
    self.io = io
    self.reader = reader
  }

  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    io.setDevice(choice, slot: slot)
    // Decision 12 (the player screen does the same): the app turns the IMU pointer off on every
    // touchscreen-bound Wii Remote, so a gyro pad taking over would leave its pointer off.
    if slot.kind == .wiiRemote, case .pad(let qualifier) = choice,
       reader.connectedPads().first(where: { $0.qualifier == qualifier })?.hasGyro == true {
      io.setMotionPointerEnabled(true, wiimote: slot.port)
    }
  }

  /// A touchscreen qualifier becomes `.touchscreen`, which `PlayerScreenIO.setDevice` binds through
  /// `ControllerManager.assignTouchscreen(toGCPort:/toWiimote:)`: the instance id is chosen for the
  /// DESTINATION's kind (GameCube 0-3, Wii 4-7), never carried over from the source slot.
  func assign(qualifier: String, slot: PlayerSlot) -> Bool {
    setDevice(PlayerDeviceChoice(qualifier: qualifier), slot: slot)
    let bound = slot.kind == .gameCube ? reader.boundQualifier(forGCPort: slot.port) : reader.boundQualifier(forWiimote: slot.port)
    return Self.bindingTook(requested: qualifier, bound: bound)
  }

  /// Whether `bound` is the device `requested` asked for. Compared as device choices, not strings:
  /// `iOS/4/Touchscreen` moved to a GameCube port reads back as `iOS/0/Touchscreen`.
  static func bindingTook(requested: String, bound: String) -> Bool {
    PlayerDeviceChoice(qualifier: requested) == PlayerDeviceChoice(qualifier: bound) && !bound.isEmpty
  }

  func clear(slot: PlayerSlot) { io.setDevice(.noDevice, slot: slot) }

  func setExtension(_ value: Int, wiimote: Int) { io.setExtension(value, wiimote: wiimote) }
  func setSideways(_ enabled: Bool, wiimote: Int) { io.setSideways(enabled, wiimote: wiimote) }
  func setPointerMode(_ mode: PointerMode) { io.setPointerMode(mode) }
  func setMotionPointer(_ enabled: Bool, wiimote: Int) { io.setMotionPointerEnabled(enabled, wiimote: wiimote) }

  func setOverlayMode(_ mode: ControllerManager.OverlayMode) {
    ControllerManager.shared.overlayMode = mode
    // The top bar's rule: picking a specific style also shows the controls.
    if mode != .auto { ControllerManager.shared.overlayVisible = true }
  }

  func setBackgroundInput(_ enabled: Bool) { DOLConfigBridge.setMainBackgroundInput(enabled) }
  func setRumbleDestination(_ value: RumbleDestination) { UserDefaults.standard.set(value.rawValue, forKey: RumbleDestination.defaultsKey) }
  func setConnectTakesPlayer1(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: ControllerManager.connectTakesPlayer1DefaultsKey) }

  func testRumble() {
    #if os(iOS)
    RumbleTest.run()
    #endif
  }

  func resetOverlayLayouts() {
    #if os(iOS)
    for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
    #endif
  }

  func setTouchOverlayProgrammatic(_ enabled: Bool) {
    #if os(iOS)
    TouchOverlayFlag.isProgrammatic = enabled
    #endif
  }
}
