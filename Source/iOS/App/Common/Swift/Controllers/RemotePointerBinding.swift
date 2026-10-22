// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import QuartzCore

/// The bridge and input writes `RemotePointerBinding` makes, behind a seam for tests.
protocol RemotePointerWriting {
  /// `TVControllerMappingBridge.bindRemotePointer(forWiimote:)`.
  func bind(wiimote: Int)
  /// `TVControllerMappingBridge.unbindRemotePointer(forWiimote:)`: exact-match only.
  func unbind(wiimote: Int)
  /// The IR axes 112-115 of the Wii Remote 1 touchscreen device (`iOS/4`).
  func writeIR(_ writes: [TCButtonType: Float])
}

struct LiveRemotePointerWriter: RemotePointerWriting {
  func bind(wiimote: Int) { TVControllerMappingBridge.bindRemotePointer(forWiimote: wiimote) }
  func unbind(wiimote: Int) { TVControllerMappingBridge.unbindRemotePointer(forWiimote: wiimote) }

  func writeIR(_ writes: [TCButtonType: Float]) {
    for (button, value) in writes {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: RemotePointerBinding.touchscreenControllerId, value: value)
    }
  }
}

/// The Siri Remote as Wii Remote 1's pointer (tvOS; plan "Mechanism"). When the resolver says
/// `.remoteGyro`, Wii Remote 1's IR rows read the idle touchscreen device's IR axes (a persisted,
/// fully qualified binding) and the remote's rotation rate is integrated into those axes; for any
/// other source the binding is removed, but only when it is exactly the one this wrote.
///
/// `apply` must run after anything that loads Wii Remote 1's profile (`Physical Controller.ini` has
/// no IR lines, so a load clears the binding): `ControllerManager.reconcile` (which every assign and
/// profile load ends with) and `prepareForBoot` call `refresh()`, as does a Pointer Source change.
///
/// Main thread only: `GCMotion.valueChangedHandler` runs there (`installMotionHandler`).
@MainActor
final class RemotePointerBinding {
  static let shared = RemotePointerBinding(writer: LiveRemotePointerWriter())

  /// `iOS/4/Touchscreen`, Wii Remote 1's touchscreen device (`ControllerManager.touchscreenWiimoteIdBase`).
  nonisolated static let touchscreenControllerId = ControllerManager.touchscreenWiimoteIdBase
  /// The pointer source is Player 1's: Wii Remote 1.
  nonisolated static let wiimote = 1

  /// The remote's motion drives the pointer. Read on every motion sample.
  private(set) var isActive = false
  private(set) var integrator = GyroPointerIntegrator()
  /// The previous sample's time, for the integration step; nil after a recenter or a switch.
  private var lastSampleTime: TimeInterval?
  private let writer: any RemotePointerWriting

  init(writer: any RemotePointerWriting) {
    self.writer = writer
  }

  /// Re-resolves Wii Remote 1's pointer source from the live state and applies it. tvOS only: iOS
  /// has no remote source, and nothing there ever wrote the binding.
  func refresh() {
    #if os(tvOS)
    apply(source: PointerSourceLive.current().source)
    #endif
  }

  func apply(source: PointerSource) {
    let active = source == .remoteGyro
    if active {
      writer.bind(wiimote: Self.wiimote)
    } else {
      writer.unbind(wiimote: Self.wiimote)
    }
    if active != isActive {
      isActive = active
      recenter()
    }
  }

  /// One `GCMotion` sample of the remote (rad/s). Ignored unless the remote is the pointer source.
  func handleRotation(x: Double, y: Double, z: Double, at time: TimeInterval, settings: MotionSettings.Snapshot) {
    guard isActive else { return }
    let dt = lastSampleTime.map { time - $0 } ?? 0
    lastSampleTime = time
    let rates = GyroPointerIntegrator.remoteRates(x: x, y: y, z: z)
    integrator.integrate(
      horizontalRate: rates.horizontal, verticalRate: rates.vertical, dt: dt,
      sensitivity: settings.gyroPointerSensitivity, invertX: settings.invertRoll, invertY: settings.invertPitch)
    writer.writeIR(integrator.irWrites)
  }

  /// The pause menu's Recenter Pointer, and every switch on or off: the cursor back to the centre.
  func recenter() {
    integrator.recenter()
    lastSampleTime = nil
    writer.writeIR(integrator.irWrites)
  }

  /// The live sample entry point, from `installMotionHandler`.
  func handleRotation(x: Double, y: Double, z: Double) {
    guard isActive else { return }
    handleRotation(x: x, y: y, z: z, at: CACurrentMediaTime(), settings: MotionSettingsCache.shared.snapshot)
  }
}
