// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(CoreMotion)
import CoreMotion
import Foundation

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

  public private(set) var orientation: UIInterfaceOrientation = .portrait
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

  /// Standard gravity, used to convert CoreMotion's g-relative acceleration into the
  /// m/s^2 the core's IMUAccelerometer expects (see `mapAccelToWiimoteFrame`).
  static let gravityToMetersPerSecondSquared: Double = 9.80665

  override required init() {
    //
  }

  @objc func registerMotionHandlers() {
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
      let full6DOFEnabled = UserDefaults.standard.bool(forKey: "motion_enable_full_6dof")
      let wiimoteIMUEnabled = UserDefaults.standard.bool(forKey: "motion_wiimote_imu_enabled")
      let nunchuckIMUEnabled = UserDefaults.standard.bool(forKey: "motion_nunchuck_imu_enabled")
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
      let full6DOFEnabled = UserDefaults.standard.bool(forKey: "motion_enable_full_6dof")
      let wiimoteIMUEnabled = UserDefaults.standard.bool(forKey: "motion_wiimote_imu_enabled")
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
    if shake.detected, UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection") {
      let currentTime = Date().timeIntervalSinceReferenceDate
      if (currentTime - lastShakeTime) > Self.shakeCooldown {
        triggerWiimoteShake()
        lastShakeTime = currentTime
      }
    }
    publishSample(motion: motion, shake: shake)

    // IR cursor mapping (when gyro mode is active)
    let irMode = DOLConfigBridge.mainTouchPadIRMode()
    if irMode == 0 {
      handleIRCursorMapping(motion: motion)
    }

    // Full 6DOF motion mapping (when not using gyro IR)
    let full6DOFEnabled = UserDefaults.standard.bool(forKey: "motion_enable_full_6dof")
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
    let attitude = motion.attitude
    let useYawForHorizontal = UserDefaults.standard.bool(forKey: "motion_use_yaw_for_horizontal")
    let invertRoll = UserDefaults.standard.bool(forKey: "motion_invert_roll")
    let invertPitch = UserDefaults.standard.bool(forKey: "motion_invert_pitch")

    let horizontalAxis = useYawForHorizontal ? attitude.yaw : attitude.roll
    let verticalAxis = attitude.pitch

    let horizontalSensitivity = 2.66
    let verticalSensitivity = 2.0

    var horizontalValue = horizontalAxis * horizontalSensitivity
    var verticalValue = verticalAxis * verticalSensitivity

    if invertRoll { horizontalValue = -horizontalValue }
    if invertPitch { verticalValue = -verticalValue }

    // Clamp to [-1, 1]
    horizontalValue = max(-1.0, min(1.0, horizontalValue))
    verticalValue = max(-1.0, min(1.0, verticalValue))

    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredLeft.rawValue, controller: port, value: Float(horizontalValue))
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredRight.rawValue, controller: port, value: Float(horizontalValue))
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredUp.rawValue, controller: port, value: Float(verticalValue))
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredDown.rawValue, controller: port, value: Float(verticalValue))
  }

  /// Map full 6DOF motion to Wiimote/Nunchuck IMU axes
  private func handle6DOFMotionMapping(motion: CMDeviceMotion) {
    let wiimoteEnabled = UserDefaults.standard.bool(forKey: "motion_wiimote_imu_enabled")
    let nunchuckEnabled = UserDefaults.standard.bool(forKey: "motion_nunchuck_imu_enabled")

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
    if #available(iOS 13.0, *) {
      if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        orientation = scene.interfaceOrientation
        return
      }
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
  /// with `m_neg == -1.0`. The core's `IMUAccelerometer::GetState()`
  /// (InputCommon/ControllerEmu/ControlGroup/IMUAccelerometer.cpp) then combines them
  /// as `x = Left - Right`, `y = Backward - Forward`, `z = Up - Down`.
  ///
  /// So writing the signed value to the `m_neg == +1` side and 0 to the `m_neg == -1`
  /// side makes the combined axis equal exactly the signed value: e.g. for X,
  /// `Left.GetState() - Right.GetState()` becomes `(x * 1) - (0 * -1) == x`. This avoids
  /// both the old bug of writing the same value to both sides (which doubled it) and
  /// the old bug of writing +v/-v to either side (which always canceled to 0).
  static func imuAccelWrites(
    x: Double, y: Double, z: Double,
    left: TCButtonType, right: TCButtonType,
    forward: TCButtonType, backward: TCButtonType,
    up: TCButtonType, down: TCButtonType
  ) -> [TCButtonType: Float] {
    [
      left: Float(x), right: 0,
      backward: Float(y), forward: 0,
      up: Float(z), down: 0,
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
      pitchDown: Float(pitch), pitchUp: 0,
      rollLeft: Float(roll), rollRight: 0,
      yawLeft: Float(yaw), yawRight: 0,
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
}
#endif
