// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The Siri Remote pointer: `GyroPointerIntegrator` (pure) and `RemotePointerBinding` (bind,
/// unbind, recenter and the per-sample writes, through a recording writer).
final class GyroPointerIntegratorTests: XCTestCase {

  private func integrate(
    _ integrator: inout GyroPointerIntegrator, h: Double = 0, v: Double = 0, dt: TimeInterval = 0.01,
    sensitivity: Double = 1, invertX: Bool = false, invertY: Bool = false
  ) {
    integrator.integrate(horizontalRate: h, verticalRate: v, dt: dt, sensitivity: sensitivity, invertX: invertX, invertY: invertY)
  }

  func test_rateTimesTimeMovesTheCursor() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: 1, v: -0.5, dt: 0.05)
    XCTAssertEqual(integrator.horizontal, 0.05 * GyroPointerIntegrator.unitsPerRadian, accuracy: 1e-9)
    XCTAssertEqual(integrator.vertical, -0.025 * GyroPointerIntegrator.unitsPerRadian, accuracy: 1e-9)
  }

  func test_sensitivityScales_andANonsenseSensitivityReadsAsOne() {
    var doubled = GyroPointerIntegrator()
    integrate(&doubled, h: 1, dt: 0.05, sensitivity: 2)
    var broken = GyroPointerIntegrator()
    integrate(&broken, h: 1, dt: 0.05, sensitivity: -3)
    XCTAssertEqual(doubled.horizontal, 0.2, accuracy: 1e-9)
    XCTAssertEqual(broken.horizontal, 0.1, accuracy: 1e-9)
  }

  func test_clampsToTheScreen() {
    var integrator = GyroPointerIntegrator()
    for _ in 0 ..< 100 { integrate(&integrator, h: 10, v: -10, dt: 0.05) }
    XCTAssertEqual(integrator.horizontal, 1)
    XCTAssertEqual(integrator.vertical, -1)
    // Turning back starts moving at once: the clamp leaves no wind-up to undo.
    integrate(&integrator, h: -1, dt: 0.05)
    XCTAssertEqual(integrator.horizontal, 0.9, accuracy: 1e-9)
  }

  func test_invertFlipsEachAxis() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: 1, v: 1, dt: 0.05, invertX: true, invertY: true)
    XCTAssertLessThan(integrator.horizontal, 0)
    XCTAssertLessThan(integrator.vertical, 0)
  }

  /// A long gap (the remote slept) moves the cursor by at most `maxStep` of rotation.
  func test_aLongGapIsCapped() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: 1, dt: 5)
    XCTAssertEqual(integrator.horizontal, GyroPointerIntegrator.maxStep * GyroPointerIntegrator.unitsPerRadian, accuracy: 1e-9)
  }

  func test_ignoresNonFiniteRatesAndNoTime() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: .nan, v: .infinity)
    integrate(&integrator, h: 1, v: 1, dt: 0)
    XCTAssertEqual(integrator, GyroPointerIntegrator())
  }

  func test_recenter() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: 3, v: 3, dt: 0.1)
    integrator.recenter()
    XCTAssertEqual(integrator.horizontal, 0)
    XCTAssertEqual(integrator.vertical, 0)
  }

  /// z (turning left is positive) drives left/right with its sign flipped; x (tipping up) drives up.
  func test_remoteRates_axisChoice() {
    let rates = GyroPointerIntegrator.remoteRates(x: 0.3, y: 9, z: 0.5)
    XCTAssertEqual(rates.horizontal, -0.5)
    XCTAssertEqual(rates.vertical, 0.3)
  }

  /// The writes use the IR cursor convention the phone gyro pointer uses (positive = right / up).
  func test_irWrites_followTheSharedConvention() {
    var integrator = GyroPointerIntegrator()
    integrate(&integrator, h: 2.5, v: 2.5, dt: 0.1)
    XCTAssertEqual(integrator.irWrites, GyroPointerMath.irCursorWrites(horizontal: 0.5, vertical: 0.5))
    XCTAssertEqual(integrator.irWrites[.wiiInfraredRight] ?? 0, 0.5, accuracy: 1e-6)
    XCTAssertEqual(integrator.irWrites[.wiiInfraredUp] ?? 0, -0.5, accuracy: 1e-6)
  }
}

@MainActor
final class RemotePointerBindingTests: XCTestCase {

  private final class RecordingWriter: RemotePointerWriting {
    var calls: [String] = []
    var lastIR: [TCButtonType: Float] = [:]
    func bind(wiimote: Int) { calls.append("bind \(wiimote)") }
    func unbind(wiimote: Int) { calls.append("unbind \(wiimote)") }
    func writeIR(_ writes: [TCButtonType: Float]) {
      calls.append("ir")
      lastIR = writes
    }
  }

  private var settings: MotionSettings.Snapshot {
    var snapshot = MotionSettings.Snapshot(store: UserDefaults(suiteName: "RemotePointerBindingTests")!)
    snapshot.gyroPointerSensitivity = 1
    snapshot.invertRoll = false
    snapshot.invertPitch = false
    return snapshot
  }

  func test_remoteSource_bindsWiiRemote1_andCentresTheCursor() {
    let writer = RecordingWriter()
    let binding = RemotePointerBinding(writer: writer)
    binding.apply(source: .remoteGyro)
    XCTAssertTrue(binding.isActive)
    XCTAssertEqual(writer.calls, ["bind 1", "ir"])
    XCTAssertEqual(writer.lastIR, GyroPointerMath.irCursorWrites(horizontal: 0, vertical: 0))
  }

  /// Any other source removes the binding (the bridge removes only its own exact expressions).
  func test_otherSources_unbind() {
    for source in [PointerSource.padGyro(padName: "DS"), .padTouchpad(padName: "DS"), .none] {
      let writer = RecordingWriter()
      RemotePointerBinding(writer: writer).apply(source: source)
      XCTAssertEqual(writer.calls, ["unbind 1"], "\(source)")
    }
  }

  /// Applying the same source again rewrites the binding (a profile load may have cleared it) but
  /// keeps the cursor where it is.
  func test_reapplying_rebindsWithoutRecentring() {
    let writer = RecordingWriter()
    let binding = RemotePointerBinding(writer: writer)
    binding.apply(source: .remoteGyro)
    binding.handleRotation(x: 0, y: 0, z: 0, at: 1, settings: settings)
    binding.handleRotation(x: 1, y: 0, z: 0, at: 1.05, settings: settings)
    let before = binding.integrator
    writer.calls.removeAll()
    binding.apply(source: .remoteGyro)
    XCTAssertEqual(writer.calls, ["bind 1"])
    XCTAssertEqual(binding.integrator, before)
  }

  func test_samples_moveTheCursorOnlyWhileActive() {
    let writer = RecordingWriter()
    let binding = RemotePointerBinding(writer: writer)
    binding.handleRotation(x: 1, y: 0, z: 0, at: 1, settings: settings)
    XCTAssertTrue(writer.calls.isEmpty, "inactive: the remote's motion goes nowhere")

    binding.apply(source: .remoteGyro)
    binding.handleRotation(x: 0, y: 0, z: 0, at: 1, settings: settings)
    binding.handleRotation(x: 1, y: 0, z: 0, at: 1.05, settings: settings)
    XCTAssertEqual(binding.integrator.vertical, 0.05 * GyroPointerIntegrator.unitsPerRadian, accuracy: 1e-9)
    XCTAssertEqual(writer.lastIR, binding.integrator.irWrites)

    binding.apply(source: .none)
    XCTAssertFalse(binding.isActive)
    XCTAssertEqual(binding.integrator, GyroPointerIntegrator(), "switching off recentres")
  }

  /// Recenter puts the cursor back and forgets the last sample, so the next one is not a long step.
  func test_recenter() {
    let writer = RecordingWriter()
    let binding = RemotePointerBinding(writer: writer)
    binding.apply(source: .remoteGyro)
    binding.handleRotation(x: 0, y: 0, z: 0, at: 1, settings: settings)
    binding.handleRotation(x: 0, y: 0, z: -1, at: 1.05, settings: settings)
    XCTAssertGreaterThan(binding.integrator.horizontal, 0)
    binding.recenter()
    XCTAssertEqual(binding.integrator, GyroPointerIntegrator())
    binding.handleRotation(x: 0, y: 0, z: -1, at: 9, settings: settings)
    XCTAssertEqual(binding.integrator, GyroPointerIntegrator(), "the first sample after a recenter only sets the clock")
  }
}
