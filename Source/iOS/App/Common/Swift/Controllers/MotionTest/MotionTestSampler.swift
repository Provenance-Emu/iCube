// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI
import simd
#if os(iOS)
import CoreMotion
#endif

extension GCMotion: ManuallyActivatedMotion {}

/// Reads every motion sensor Motion Test shows, about 15 times a second, between `start()` and
/// `stop()`.
///
/// It polls. A controller's `GCMotion.valueChangedHandler` belongs to `installMotionHandler`
/// (ControllerExtensions.swift), and the device's CoreMotion handlers to `TCDeviceMotion`, which
/// writes the running game's Wii Remote: this screen must not take either over.
@MainActor
@Observable
final class MotionTestSampler {
  /// Fast enough to follow a hand, slow enough to read the numbers.
  static let sampleInterval: TimeInterval = 1.0 / 15

  private(set) var state = MotionTestState()

  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var activation = MotionSensorActivation()
  #if os(iOS)
  /// Its own manager, in pull mode: `TCDeviceMotion`'s is private and is started and stopped with
  /// the game's motion, which a second reader must not disturb. Made by `start()`: SwiftUI builds
  /// (and throws away) a sampler every time the hub rebuilds its rows.
  @ObservationIgnored private var motionManager: CMMotionManager?
  #endif

  /// Idempotent.
  func start() {
    guard timer == nil else { return }
    startDeviceMotion()
    sample()
    let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sample() }
    }
    // Common modes: keep sampling while the list scrolls.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Stops the timer and the device's sensors, and turns off the controller sensors this screen
  /// turned on.
  func stop() {
    timer?.invalidate()
    timer = nil
    activation.restore()
    stopDeviceMotion()
  }

  private func sample() {
    var sources: [MotionTestSource] = []
    for (index, controller) in GCController.controllers().enumerated() {
      guard let motion = controller.motion else { continue }
      activation.sample(motion)
      let acceleration = motion.acceleration
      let rotationRate = motion.rotationRate
      // The index, not the qualifier: a remote the ControllerInterface has not enumerated has none.
      sources.append(.controller(
        id: "pad-\(index)", name: controller.vendorName ?? controller.productCategory,
        isMenuRemote: controller.isMenuRemote,
        acceleration: SIMD3(acceleration.x, acceleration.y, acceleration.z),
        rotationRate: SIMD3(rotationRate.x, rotationRate.y, rotationRate.z),
        flags: MotionSensorFlags(
          hasRotationRate: motion.hasRotationRate,
          hasGravityAndUserAcceleration: motion.hasGravityAndUserAcceleration,
          hasAttitude: motion.hasAttitude,
          sensorsRequireManualActivation: motion.sensorsRequireManualActivation,
          sensorsActive: motion.sensorsActive)))
    }
    let next = MotionTestState(sources: sources, device: deviceSource(), deviceMotionAvailable: isDeviceMotionAvailable)
    // The menu is rebuilt on every change: skip the samples that change nothing.
    if next != state { state = next }
  }

  #if os(iOS)
  private var isDeviceMotionAvailable: Bool { motionManager?.isAccelerometerAvailable == true }

  private func startDeviceMotion() {
    let manager = CMMotionManager()
    motionManager = manager
    guard manager.isAccelerometerAvailable else { return }
    manager.accelerometerUpdateInterval = Self.sampleInterval
    manager.startAccelerometerUpdates()
    guard manager.isGyroAvailable else { return }
    manager.gyroUpdateInterval = Self.sampleInterval
    manager.startGyroUpdates()
  }

  private func stopDeviceMotion() {
    motionManager?.stopAccelerometerUpdates()
    motionManager?.stopGyroUpdates()
    motionManager = nil
  }

  private func deviceSource() -> MotionTestSource? {
    guard let motionManager, let acceleration = motionManager.accelerometerData?.acceleration else { return nil }
    let rotationRate = motionManager.gyroData?.rotationRate
    // The game's scene, as `TCDeviceMotion.statusBarOrientationChanged()` picks it.
    let scene = MainSceneCoordinator.shared().mainScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    return .device(
      acceleration: SIMD3(acceleration.x, acceleration.y, acceleration.z),
      rotationRate: rotationRate.map { SIMD3($0.x, $0.y, $0.z) },
      orientation: scene?.interfaceOrientation ?? .portrait)
  }
  #else
  private var isDeviceMotionAvailable: Bool { false }
  private func startDeviceMotion() {}
  private func stopDeviceMotion() {}
  private func deviceSource() -> MotionTestSource? { nil }
  #endif
}

#if os(iOS)
extension MotionTestSource {
  static let deviceID = "device"

  /// This device's own reading as the touchscreen's Wii Remote reads it, through `TCDeviceMotion`'s
  /// mapping functions (never a second derivation): the static neutral grip, the remote pointing
  /// out of the device's back with its top at the screen's up edge. That is the mapping the DSU
  /// server streams. A game adds two things this screen cannot know: the mount Recenter takes (the
  /// grip held then reads as level), and the pointer mode (the touch modes keep the remote level).
  ///
  /// - `acceleration`: CoreMotion's accelerometer, in g (gravity included, gravity-vector sign).
  /// - `rotationRate`: CoreMotion's gyroscope, rad/s. nil without one.
  static func device(
    acceleration: SIMD3<Double>, rotationRate: SIMD3<Double>?, orientation: UIInterfaceOrientation
  ) -> MotionTestSource {
    MotionTestSource(
      id: deviceID, name: MotionTestModelBuilder.deviceHeader, kind: .device, acceleration: acceleration,
      rotationRate: rotationRate, flags: nil,
      remote: WiiRemoteMotion(
        acceleration: TCDeviceMotion.imuAcceleration(
          source: .phoneUnmounted, acceleration: acceleration, gravity: nil, mount: nil, orientation: orientation),
        angularVelocity: rotationRate.map { TCDeviceMotion.imuAngularVelocity($0, mount: nil, orientation: orientation) }))
  }
}
#endif
