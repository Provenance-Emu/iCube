// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(CoreMotion)
import CoreMotion
import Foundation
import simd

@objc public class TCDeviceMotion: NSObject {
  @MainActor
  @objc public static let shared = TCDeviceMotion()

  private let motionManager = CMMotionManager()
  /// CoreMotion delivers on this queue. It MUST be serial: the accelerometer, gyro and device-motion
  /// callbacks all mutate the same state (`shakeHistory`, cursor position, port), and with the default
  /// unlimited concurrency they ran in parallel and crashed inside `shakeHistory.append` (EXC_BAD_ACCESS
  /// in swift_release from a torn Array buffer) as soon as a game booted.
  private let operationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.joemattiello.iCube.device-motion"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInteractive
    return queue
  }()

  /// The interface orientation the pointer and IMU mappings read their axes from. Written on the
  /// main thread by `statusBarOrientationChanged()`, read on `operationQueue` by the CoreMotion
  /// handlers, so it is behind a lock.
  public private(set) var orientation: UIInterfaceOrientation {
    get {
      orientationLock.lock()
      defer { orientationLock.unlock() }
      return storedOrientation
    }
    set {
      orientationLock.lock()
      storedOrientation = newValue
      orientationLock.unlock()
    }
  }

  private let orientationLock = NSLock()
  private var storedOrientation: UIInterfaceOrientation = .portrait
  public private(set) var motionEnabled = false
  private var port = 0

  // Enhanced motion features
  private var shakeHistory: [Double] = []
  private var lastShakeTime: TimeInterval = 0
  static let shakeHistoryLength = 15
  static let shakeMinSamples = 8
  static let shakeVarianceThreshold = 0.15
  static let shakeAccelerationThreshold = 0.8
  static let shakeCooldown: TimeInterval = 0.5
  /// Standard deviation of the recent user-acceleration magnitude, scaled for display.
  static let shakeIntensityScale = 20.0

  /// Latest device-motion sample plus the shake statistics derived from it. Published for the
  /// Motion Debug screen, which observes this feed instead of running a second CMMotionManager
  /// (that copy also ran its own shake detector and could fire the same shake buttons twice).
  struct Sample {
    var roll = 0.0, pitch = 0.0, yaw = 0.0
    var rotationX = 0.0, rotationY = 0.0, rotationZ = 0.0
    var userAccelX = 0.0, userAccelY = 0.0, userAccelZ = 0.0
    var shakeIntensity = 0.0
    var shakeDetected = false
    var timestamp: TimeInterval = 0
  }

  private let sampleLock = NSLock()
  private var _latestSample = Sample()
  /// Thread-safe copy of the most recent device-motion sample (written on the motion queue).
  var latestSample: Sample {
    sampleLock.lock()
    defer { sampleLock.unlock() }
    return _latestSample
  }

  @objc public var isDeviceMotionAvailable: Bool { motionManager.isDeviceMotionAvailable }

  // MARK: Gyro pointer baseline

  /// Radians of tilt from the baseline to a full-width / full-height pointer swing (1 / gain).
  static let gyroPointerHorizontalSensitivity = 2.66
  static let gyroPointerVerticalSensitivity = 2.0
  /// How often (in gyro-pointer samples, 60 Hz) `input_debug` logs the pointer, about once a second.
  private static let gyroPointerLogInterval = 60

  /// Attitude the gyro pointer treats as "center" (CoreMotion's quaternion, device to reference
  /// frame), and the interface orientation it was taken in. Only touched on the serial motion queue.
  private var pointerBaseline: simd_quatd?
  private var pointerBaselineOrientation: UIInterfaceOrientation?
  /// IR mode seen on the previous device-motion sample (motion queue only), to catch a switch
  /// into gyro mode from any of the places that set it.
  private var lastIRMode: Int?
  private var gyroPointerSampleCount = 0
  /// Set from any thread by `recenterPointer()`, consumed on the motion queue.
  private let recenterLock = NSLock()
  private var recenterRequested = true

  /// Makes the device's current attitude the pointer's center on the next motion sample. Called on
  /// a recenter gesture or action; the motion queue also recenters itself when motion (re)starts and
  /// when the IR mode switches into gyro.
  @objc public func recenterPointer() {
    recenterLock.lock()
    recenterRequested = true
    recenterLock.unlock()
  }

  /// The user-facing "Recenter Pointer" action: recenters the gyro pointer and tells the touch IR
  /// pads (drag mode keeps its own offset) to center too.
  @MainActor
  static func requestPointerRecenter() {
    shared.recenterPointer()
    NotificationCenter.default.post(name: .DOLRecenterPointer, object: nil)
  }

  private func takeRecenterRequest() -> Bool {
    recenterLock.lock()
    defer { recenterLock.unlock() }
    let requested = recenterRequested
    recenterRequested = false
    return requested
  }

  /// Whether the gyro pointer takes the current attitude as its new center: on a recenter request,
  /// when there is no baseline yet (`baselineOrientation == nil`), and when the interface orientation
  /// changed since the baseline was taken. `orientation` is kept current by
  /// `statusBarOrientationChanged()`, which the emulation screen calls on every rotation.
  static func needsPointerRebaseline(
    recenterRequested: Bool,
    baselineOrientation: UIInterfaceOrientation?,
    orientation: UIInterfaceOrientation
  ) -> Bool {
    recenterRequested || baselineOrientation != orientation
  }

  /// Pointer offsets for the turn from `baseline` to `current`, before inversion and clamping.
  ///
  /// The turn is taken as a rotation vector in the baseline's device frame, then read along the
  /// screen's axes for `orientation`: tipping about the screen's horizontal axis moves the pointer
  /// up and down; turning about its vertical axis ("Yaw") or tilting about the axis out of the
  /// screen ("Roll") moves it left and right.
  ///
  /// Differences of CoreMotion's Euler angles, used before, broke in the two ways a phone is
  /// actually held: upright in portrait, pitch sits near 90 degrees, where roll and yaw degenerate
  /// (the pointer could not reach the edges and its scale drifted); in landscape, the device's
  /// axes are a quarter turn from the screen's, so tipping the phone moved the pointer sideways.
  static func gyroPointerOffsets(
    current: simd_quatd,
    baseline: simd_quatd,
    orientation: UIInterfaceOrientation,
    useYawForHorizontal: Bool,
    gain: Double = 1
  ) -> (horizontal: Double, vertical: Double) {
    let turn = rotationVector(baseline.inverse * current)
    let axes = screenAxes(for: orientation)
    // Right-handed: a positive turn about the screen's up axis swings the phone's back to the
    // left, and a positive turn about the axis out of the screen is counterclockwise, so both
    // horizontal readings are negated. A positive turn about the screen's right axis tips the back
    // up, which is pointer-up.
    let horizontalAngle = useYawForHorizontal ? -simd_dot(turn, axes.up) : -simd_dot(turn, axes.out)
    let verticalAngle = simd_dot(turn, axes.right)
    // `gain` is the user's gyro pointer sensitivity (`MotionSettings.gyroPointerSensitivity`, 1 by
    // default) on top of the fixed per-axis constants.
    return (
      horizontalAngle * gyroPointerHorizontalSensitivity * gain,
      verticalAngle * gyroPointerVerticalSensitivity * gain)
  }

  /// Axis times angle (radians) of `rotation`, taking the shorter way round: `q` and `-q` are the
  /// same attitude.
  private static func rotationVector(_ rotation: simd_quatd) -> SIMD3<Double> {
    let shortest = rotation.real < 0 ? simd_quatd(vector: -rotation.vector) : rotation
    let sinHalf = simd_length(shortest.imag)
    guard sinHalf > 1e-12 else { return .zero }
    let angle = 2 * atan2(sinHalf, shortest.real)
    return shortest.imag / sinHalf * angle
  }

  /// The screen's right, up and out-of-screen directions in device coordinates (+X the portrait
  /// right edge, +Y the portrait top edge, +Z out of the screen). Unknown folds into portrait.
  private static func screenAxes(for orientation: UIInterfaceOrientation)
    -> (right: SIMD3<Double>, up: SIMD3<Double>, out: SIMD3<Double>)
  {
    let out = SIMD3<Double>(0, 0, 1)
    switch orientation {
    case .portraitUpsideDown:
      return (SIMD3(-1, 0, 0), SIMD3(0, -1, 0), out)
    case .landscapeLeft:
      // Home side on the left: the device's top edge points right and its right edge down.
      return (SIMD3(0, 1, 0), SIMD3(-1, 0, 0), out)
    case .landscapeRight:
      return (SIMD3(0, -1, 0), SIMD3(1, 0, 0), out)
    default:
      return (SIMD3(1, 0, 0), SIMD3(0, 1, 0), out)
    }
  }

  /// Standard gravity, used to convert CoreMotion's g-relative acceleration into the
  /// m/s^2 the core's IMUAccelerometer expects (see `mapAccelToWiimoteFrame`).
  static let gravityToMetersPerSecondSquared: Double = 9.80665

  override required init() {
    //
  }

  @objc func registerMotionHandlers() {
    // Motion is (re)starting: emulation start or resume. Center on however the device is held now.
    recenterPointer()

    // Set our orientation properly
    Task { @MainActor in
      statusBarOrientationChanged()
    }

    // Set the sensor update times
    // 200Hz is the Wiimote update interval
    let updateInterval: Double = 1.0 / 200.0
    motionManager.accelerometerUpdateInterval = updateInterval
    motionManager.gyroUpdateInterval = updateInterval
    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // Device motion for enhanced features

    // Register the handlers
    motionManager.startAccelerometerUpdates(to: operationQueue) { data, error in
      if error != nil { return }
      // Get the data. CMAcceleration's units are G's (gravity included); the core's
      // IMUAccelerometer expects m/s^2, so scale by standard gravity. No clamping:
      // the core does not clamp its accelerometer state either.
      let acceleration = data!.acceleration
      let mapped = Self.mapAccelToWiimoteFrame(
        x: acceleration.x * Self.gravityToMetersPerSecondSquared,
        y: acceleration.y * Self.gravityToMetersPerSecondSquared,
        z: acceleration.z * Self.gravityToMetersPerSecondSquared,
        orientation: self.orientation
      )

      // Check if 6DOF motion mapping is enabled - if so, skip original IMU mappings to avoid conflicts
      let full6DOFEnabled = MotionSettings.full6DOF()
      let wiimoteIMUEnabled = MotionSettings.wiimoteIMU()
      let nunchuckIMUEnabled = MotionSettings.nunchukIMU()
      let isGyroIRMode = (DOLConfigBridge.mainTouchPadIRMode() == 0)

      // Only use original Wiimote accelerometer mapping if 6DOF is disabled OR Wiimote IMU is disabled
      if !full6DOFEnabled || !wiimoteIMUEnabled || isGyroIRMode {
        for (button, value) in Self.wiimoteAccelWrites(x: mapped.x, y: mapped.y, z: mapped.z) {
          TCManagerInterface.setAxisValueFor(button.rawValue, controller: self.port, value: value)
        }
      }

      // Only use original Nunchuk accelerometer mapping if 6DOF is disabled OR Nunchuk IMU is disabled
      if !full6DOFEnabled || !nunchuckIMUEnabled || isGyroIRMode {
        for (button, value) in Self.nunchukAccelWrites(x: mapped.x, y: mapped.y, z: mapped.z) {
          TCManagerInterface.setAxisValueFor(button.rawValue, controller: self.port, value: value)
        }
      }
    }

    motionManager.startGyroUpdates(to: operationQueue) { data, error in
      if error != nil { return }

      // CMRotationRate's units are already rad/s, which is what the core's
      // IMUGyroscope expects. No gain, no clamping: the core does not clamp either.
      let rr = data!.rotationRate
      let mapped = Self.mapGyroToWiimoteFrame(x: rr.x, y: rr.y, z: rr.z, orientation: self.orientation)

      // Check if 6DOF motion mapping is enabled - if so, skip original gyro mappings to avoid conflicts
      let full6DOFEnabled = MotionSettings.full6DOF()
      let wiimoteIMUEnabled = MotionSettings.wiimoteIMU()
      let isGyroIRMode = (DOLConfigBridge.mainTouchPadIRMode() == 0)

      // Only use original Wiimote gyro mapping if 6DOF is disabled OR Wiimote IMU is disabled
      if !full6DOFEnabled || !wiimoteIMUEnabled || isGyroIRMode {
        for (button, value) in Self.wiimoteGyroWrites(pitch: mapped.pitch, roll: mapped.roll, yaw: mapped.yaw) {
          TCManagerInterface.setAxisValueFor(button.rawValue, controller: self.port, value: value)
        }
      }
    }

    // Enhanced device motion updates for shake detection, IR cursor, and 6DOF motion
    if motionManager.isDeviceMotionAvailable {
      motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: operationQueue) { motion, error in
        guard let motion = motion, error == nil else { return }

        self.handleEnhancedMotionFeatures(motion: motion)
      }
    }
  }

  /// Handle enhanced motion features: shake detection, IR cursor, and 6DOF motion mapping
  private func handleEnhancedMotionFeatures(motion: CMDeviceMotion) {
    // Shake statistics are always kept (they feed the debug view); the Wii Remote shake is only
    // fired when enhanced shake detection is on.
    let shake = updateShakeStatistics(motion: motion)
    if shake.detected, MotionSettings.enhancedShakeDetection() {
      let currentTime = Date().timeIntervalSinceReferenceDate
      if (currentTime - lastShakeTime) > Self.shakeCooldown {
        triggerWiimoteShake()
        lastShakeTime = currentTime
      }
    }
    publishSample(motion: motion, shake: shake)

    // IR cursor mapping (when gyro mode is active)
    let irMode = DOLConfigBridge.mainTouchPadIRMode()
    if irMode == 0, lastIRMode != 0 {
      recenterPointer()
    }
    lastIRMode = irMode
    if irMode == 0 {
      handleIRCursorMapping(motion: motion)
    }

    // Full 6DOF motion mapping (when not using gyro IR)
    let full6DOFEnabled = MotionSettings.full6DOF()
    if irMode != 0, full6DOFEnabled {
      // Debug logging to verify this is being called
//      if UserDefaults.standard.bool(forKey: "input_debug") {
//        NSLog("[MOTION] 6DOF mapping active: IR mode=\(irMode), 6DOF enabled=\(full6DOFEnabled)")
//      }
      handle6DOFMotionMapping(motion: motion)
    }
  }

  /// Variance-based shake detection over the recent user-acceleration magnitude (gravity already
  /// removed by CoreMotion). A shake needs both high variance and a high current magnitude.
  private func updateShakeStatistics(motion: CMDeviceMotion) -> (intensity: Double, detected: Bool) {
    let userAccel = motion.userAcceleration
    let magnitude = sqrt(userAccel.x * userAccel.x + userAccel.y * userAccel.y + userAccel.z * userAccel.z)

    shakeHistory.append(magnitude)
    if shakeHistory.count > Self.shakeHistoryLength {
      shakeHistory.removeFirst()
    }
    guard shakeHistory.count >= Self.shakeMinSamples else { return (0, false) }

    let mean = shakeHistory.reduce(0, +) / Double(shakeHistory.count)
    let variance = shakeHistory.reduce(0) { acc, val in acc + pow(val - mean, 2) } / Double(shakeHistory.count)
    let standardDeviation = sqrt(variance)
    let detected = standardDeviation > Self.shakeVarianceThreshold && magnitude > Self.shakeAccelerationThreshold
    return (standardDeviation * Self.shakeIntensityScale, detected)
  }

  private func publishSample(motion: CMDeviceMotion, shake: (intensity: Double, detected: Bool)) {
    var sample = Sample()
    sample.roll = motion.attitude.roll
    sample.pitch = motion.attitude.pitch
    sample.yaw = motion.attitude.yaw
    sample.rotationX = motion.rotationRate.x
    sample.rotationY = motion.rotationRate.y
    sample.rotationZ = motion.rotationRate.z
    sample.userAccelX = motion.userAcceleration.x
    sample.userAccelY = motion.userAcceleration.y
    sample.userAccelZ = motion.userAcceleration.z
    sample.shakeIntensity = shake.intensity
    sample.shakeDetected = shake.detected
    sample.timestamp = motion.timestamp
    sampleLock.lock()
    _latestSample = sample
    sampleLock.unlock()
  }

  /// Map device attitude to IR cursor movement
  private func handleIRCursorMapping(motion: CMDeviceMotion) {
    let q = motion.attitude.quaternion
    let attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
    // Written on the main thread by statusBarOrientationChanged, behind its lock; read once per
    // sample.
    let orientation = self.orientation
    let useYawForHorizontal = MotionSettings.useYawForHorizontal()
    let invertRoll = MotionSettings.invertRoll()
    let invertPitch = MotionSettings.invertPitch()
    let debug = UserDefaults.standard.bool(forKey: "input_debug")

    // Rotating the UI turns the screen's axes against the device's, so recenter on whatever the
    // player is holding now rather than reading the old turn along the new axes.
    // `pointerBaselineOrientation` is set together with `pointerBaseline`, so nil means no baseline.
    if Self.needsPointerRebaseline(
      recenterRequested: takeRecenterRequest(), baselineOrientation: pointerBaselineOrientation,
      orientation: orientation) {
      pointerBaseline = attitude
      pointerBaselineOrientation = orientation
      if debug {
        NSLog("[MOTION] gyro pointer baseline orientation=%d", orientation.rawValue)
      }
    }
    guard let baseline = pointerBaseline else { return }

    // Read per sample, like the invert keys above, so a change applies without a restart.
    var (horizontalValue, verticalValue) = Self.gyroPointerOffsets(
      current: attitude, baseline: baseline, orientation: orientation,
      useYawForHorizontal: useYawForHorizontal, gain: MotionSettings.gyroPointerSensitivity())

    if invertRoll { horizontalValue = -horizontalValue }
    if invertPitch { verticalValue = -verticalValue }

    gyroPointerSampleCount += 1
    if debug, gyroPointerSampleCount % Self.gyroPointerLogInterval == 0 {
      NSLog("[MOTION] gyro pointer h=%.3f v=%.3f (before clamp)", horizontalValue, verticalValue)
    }

    // Clamping to [-1, 1] happens inside irCursorWrites so it stays covered by the
    // pure unit tests below, alongside the sign/single-sided derivation.
    for (button, value) in Self.irCursorWrites(horizontal: horizontalValue, vertical: verticalValue) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
  }

  /// Map full 6DOF motion to Wiimote/Nunchuck IMU axes
  private func handle6DOFMotionMapping(motion: CMDeviceMotion) {
    let wiimoteEnabled = MotionSettings.wiimoteIMU()
    let nunchuckEnabled = MotionSettings.nunchukIMU()

    guard wiimoteEnabled || nunchuckEnabled else { return }

    // The Wiimote accelerometer must include gravity (that's how the game senses tilt),
    // so combine gravity + userAcceleration rather than userAcceleration alone, which
    // has gravity removed. Both are in G's, in the device's own frame (like
    // CMAccelerometerData), so this is scaled and remapped exactly like the legacy
    // accelerometer handler above.
    let gravity = motion.gravity
    let userAccel = motion.userAcceleration
    let accel = Self.mapAccelToWiimoteFrame(
      x: (gravity.x + userAccel.x) * Self.gravityToMetersPerSecondSquared,
      y: (gravity.y + userAccel.y) * Self.gravityToMetersPerSecondSquared,
      z: (gravity.z + userAccel.z) * Self.gravityToMetersPerSecondSquared,
      orientation: orientation
    )

    if wiimoteEnabled {
      for (button, value) in Self.wiimoteAccelWrites(x: accel.x, y: accel.y, z: accel.z) {
        TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
      }

      // motion.rotationRate is in the device's own frame, like CMGyroData.rotationRate,
      // so it goes through the same mapping as the legacy gyro handler.
      let rr = motion.rotationRate
      let gyro = Self.mapGyroToWiimoteFrame(x: rr.x, y: rr.y, z: rr.z, orientation: orientation)
      for (button, value) in Self.wiimoteGyroWrites(pitch: gyro.pitch, roll: gyro.roll, yaw: gyro.yaw) {
        TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
      }
    }

    if nunchuckEnabled {
      for (button, value) in Self.nunchukAccelWrites(x: accel.x, y: accel.y, z: accel.z) {
        TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
      }

      // Note: Nunchuk gyro is not available in TCButtonType enum (only accelerometer)
    }
  }

  /// Trigger Wiimote shake events
  private func triggerWiimoteShake() {
    let shakeDuration: Float = 0.1

    // Trigger shake on all axes
    TCManagerInterface.setButtonStateFor(132, controller: port, state: true) // wiiShakeX
    TCManagerInterface.setButtonStateFor(133, controller: port, state: true) // wiiShakeY
    TCManagerInterface.setButtonStateFor(134, controller: port, state: true) // wiiShakeZ

    // Release after duration
    DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(shakeDuration)) {
      TCManagerInterface.setButtonStateFor(132, controller: self.port, state: false)
      TCManagerInterface.setButtonStateFor(133, controller: self.port, state: false)
      TCManagerInterface.setButtonStateFor(134, controller: self.port, state: false)
    }
  }

  /// Manual shake (Motion Debug "Test Wii Remote Shake"), sent to the bound slot like a real one.
  @objc public func triggerShake() { triggerWiimoteShake() }

  @objc func setMotionEnabled(_ mode: Bool) {
    if motionEnabled == mode { return }
    motionEnabled = mode

    if motionEnabled {
      registerMotionHandlers()
    } else {
      motionManager.stopAccelerometerUpdates()
      motionManager.stopGyroUpdates()
      motionManager.stopDeviceMotionUpdates()
    }
  }

  @objc func setPort(_ port: Int) { self.port = port }

  // UIApplicationDidChangeStatusBarOrientationNotification is deprecated...
  @MainActor
  @objc func statusBarOrientationChanged() {
    // The game's scene, not whichever scene the set lists first: with an external display
    // connected that can be the (landscape) external window while the phone is portrait.
    if let scene = MainSceneCoordinator.shared().mainScene
      ?? UIApplication.shared.connectedScenes.first as? UIWindowScene {
      orientation = scene.interfaceOrientation
      return
    }
    orientation = UIApplication.shared.statusBarOrientation
  }

  // MARK: - IMU axis mapping (pure, unit-testable)
  //
  // These are `internal` rather than `private` on purpose: they're implementation
  // details of this file, not part of any public API, but DolphiniOSTests needs to
  // reach them via `@testable import iCube` to unit test the mapping independently
  // of CoreMotion and the touch controller runtime.

  /// Rotates a phone-frame vector's X/Y components into the Wiimote's frame for the
  /// given interface orientation. This is the exact rotation the legacy accelerometer
  /// handler used. Z (out of the screen) is left to the caller: it passes straight
  /// through unchanged for every orientation, because gravity relative to "out of the
  /// screen" doesn't depend on which edge of the UI is currently "up".
  static func rotateInPlane(x: Double, y: Double, orientation: UIInterfaceOrientation) -> (x: Double, y: Double) {
    switch orientation {
    case .portrait, .unknown:
      return (-x, -y)
    case .landscapeRight:
      return (y, -x)
    case .portraitUpsideDown:
      return (x, y)
    case .landscapeLeft:
      return (-y, x)
    @unknown default:
      return (0, 0)
    }
  }

  /// Maps a phone-frame acceleration vector (already in m/s^2, gravity included) into
  /// the Wiimote's frame, honoring the current interface orientation.
  static func mapAccelToWiimoteFrame(
    x: Double, y: Double, z: Double, orientation: UIInterfaceOrientation
  ) -> (x: Double, y: Double, z: Double) {
    let (wx, wy) = rotateInPlane(x: x, y: y, orientation: orientation)
    return (wx, wy, z)
  }

  /// Maps a phone-frame rotation rate vector (rad/s) into the Wiimote's pitch/roll/yaw,
  /// honoring the current interface orientation.
  ///
  /// Pitch and yaw reuse the legacy gyro handler's orientation switch verbatim (it
  /// mapped `vert` to pitch and `horiz` to yaw; roll was always written as 0).
  ///
  /// Roll is derived, not copied from existing code: rr.x and rr.y are, like the
  /// accelerometer's x/y, a vector lying in the screen plane, so they transform under
  /// the same in-plane rotation as accelerometer x/y (`rotateInPlane`). Roll is the
  /// negated Y component of that same rotation applied to (rr.x, rr.y). That formula
  /// was picked because it reproduces "portrait roll == +rr.y" exactly while staying
  /// consistent with how pitch/yaw are permuted across orientations (see the
  /// implementation notes in the PR/commit this shipped with for the full derivation).
  /// This has NOT been verified on-device for perceived roll direction in-game; treat
  /// the sign as provisional until confirmed with a real Wiimote-roll test (e.g. a
  /// steering game) in each orientation.
  static func mapGyroToWiimoteFrame(
    x: Double, y: Double, z: Double, orientation: UIInterfaceOrientation
  ) -> (pitch: Double, roll: Double, yaw: Double) {
    let pitch: Double
    let yaw: Double

    switch orientation {
    case .portrait, .unknown:
      yaw = z
      pitch = -x
    case .portraitUpsideDown:
      yaw = -z
      pitch = x
    case .landscapeLeft:
      yaw = z
      pitch = -y
    case .landscapeRight:
      yaw = -z
      pitch = y
    @unknown default:
      return (0, 0, 0)
    }

    let (_, rotatedY) = rotateInPlane(x: x, y: y, orientation: orientation)
    let roll = -rotatedY

    return (pitch, roll, yaw)
  }

  /// Builds the raw axis writes for one IMU accelerometer triple, given the six
  /// Touchscreen.mm button types (in Left/Right/Forward/Backward/Up/Down order) and an
  /// acceleration vector already expressed in the Wiimote's frame.
  ///
  /// Touchscreen.mm (`AddInput(new Axis(...))`, ~lines 139-158) gives each half-axis a
  /// sign multiplier `m_neg`, and `Axis::GetState()` returns `storedValue * m_neg`.
  /// Left/Backward/Up default to `m_neg == +1.0`; Right/Forward/Down are constructed
  /// with `m_neg == -1.0`. A bound input then goes through `ControlExpression`
  /// (InputCommon/ControlReference/ExpressionParser.cpp), which clamps it at 0. The core's
  /// `IMUAccelerometer::GetState()` combines the clamped halves as `x = Left - Right`,
  /// `y = Backward - Forward`, `z = Up - Down`.
  ///
  /// So the same signed value goes to both sides of each pair: the clamp keeps it on the
  /// side whose `m_neg` makes it positive and zeroes the other, and the difference is the
  /// signed value, e.g. `max(0, x) - max(0, -x) == x`. Writing to one side only would lose
  /// every negative value to the clamp.
  static func imuAccelWrites(
    x: Double, y: Double, z: Double,
    left: TCButtonType, right: TCButtonType,
    forward: TCButtonType, backward: TCButtonType,
    up: TCButtonType, down: TCButtonType
  ) -> [TCButtonType: Float] {
    [
      left: Float(x), right: Float(x),
      backward: Float(y), forward: Float(y),
      up: Float(z), down: Float(z),
    ]
  }

  /// Same convention as `imuAccelWrites`, for the gyroscope triple. In Touchscreen.mm,
  /// PitchDown/RollLeft/YawLeft default to `m_neg == +1.0`; PitchUp/RollRight/YawRight
  /// are `m_neg == -1.0`. IMUGyroscope::GetRawState() combines them as
  /// `pitch = PitchDown - PitchUp`, `roll = RollLeft - RollRight`, `yaw = YawLeft - YawRight`.
  static func imuGyroWrites(
    pitch: Double, roll: Double, yaw: Double,
    pitchUp: TCButtonType, pitchDown: TCButtonType,
    rollLeft: TCButtonType, rollRight: TCButtonType,
    yawLeft: TCButtonType, yawRight: TCButtonType
  ) -> [TCButtonType: Float] {
    [
      pitchDown: Float(pitch), pitchUp: Float(pitch),
      rollLeft: Float(roll), rollRight: Float(roll),
      yawLeft: Float(yaw), yawRight: Float(yaw),
    ]
  }

  static func wiimoteAccelWrites(x: Double, y: Double, z: Double) -> [TCButtonType: Float] {
    imuAccelWrites(
      x: x, y: y, z: z,
      left: .wiiAccelLeft, right: .wiiAccelRight,
      forward: .wiiAccelForward, backward: .wiiAccelBackward,
      up: .wiiAccelUp, down: .wiiAccelDown
    )
  }

  static func nunchukAccelWrites(x: Double, y: Double, z: Double) -> [TCButtonType: Float] {
    imuAccelWrites(
      x: x, y: y, z: z,
      left: .nunchukAccelLeft, right: .nunchukAccelRight,
      forward: .nunchukAccelForward, backward: .nunchukAccelBackward,
      up: .nunchukAccelUp, down: .nunchukAccelDown
    )
  }

  static func wiimoteGyroWrites(pitch: Double, roll: Double, yaw: Double) -> [TCButtonType: Float] {
    imuGyroWrites(
      pitch: pitch, roll: roll, yaw: yaw,
      pitchUp: .wiiGyroPitchUp, pitchDown: .wiiGyroPitchDown,
      rollLeft: .wiiGyroRollLeft, rollRight: .wiiGyroRollRight,
      yawLeft: .wiiGyroYawLeft, yawRight: .wiiGyroYawRight
    )
  }

  /// The gyro-mode IR cursor's writes, by the same both-sides convention as `imuAccelWrites`.
  ///
  /// `ControllerEmu::Cursor::GetReshapableState()` (InputCommon/ControllerEmu/
  /// ControlGroup/Cursor.cpp:67-68) computes `y = Up - Down` and `x = Right - Left` on the
  /// clamped halves. `Touchscreen.mm` (~line 74-77) wires `WIIMOTE_IR_RIGHT` /
  /// `WIIMOTE_IR_DOWN` with `m_neg == +1` and `WIIMOTE_IR_UP` / `WIIMOTE_IR_LEFT` with
  /// `m_neg == -1`.
  ///
  /// X: `horizontal` on Right and Left gives `max(0, h) - max(0, -h) == h` (positive =
  /// right). Y: positive `vertical` means up, and Up's `m_neg == -1` makes `-vertical` on
  /// Up and Down read `max(0, v) - max(0, -v) == v`. This is the touch path's convention
  /// too (`TouchOverlayIRPadView.IRSurfaceView.sendIR` writes `[y, y, x, x]` with y positive = down).
  /// The single-sided writes this replaced lost the left and bottom halves to the clamp.
  static func irCursorWrites(horizontal: Double, vertical: Double) -> [TCButtonType: Float] {
    let clampedHorizontal = Float(max(-1.0, min(1.0, horizontal)))
    let clampedVertical = Float(max(-1.0, min(1.0, vertical)))
    return [
      .wiiInfraredRight: clampedHorizontal, .wiiInfraredLeft: clampedHorizontal,
      .wiiInfraredUp: -clampedVertical, .wiiInfraredDown: -clampedVertical,
    ]
  }
}
#endif
