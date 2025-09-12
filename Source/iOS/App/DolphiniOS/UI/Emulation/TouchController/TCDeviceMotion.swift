// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(CoreMotion)
import CoreMotion
import Foundation

@objc public class TCDeviceMotion: NSObject {
  @objc public static let shared = TCDeviceMotion()

  private let motionManager = CMMotionManager()
  private let operationQueue = OperationQueue()

  public private(set) var orientation: UIInterfaceOrientation = .portrait
  public private(set) var motionEnabled = false
  private var port = 0

  // Enhanced motion features
  private var shakeHistory: [Double] = []
  private var lastShakeTime: TimeInterval = 0

  override required init() {
    //
  }

  @objc func registerMotionHandlers() {
    // Set our orientation properly
    self.statusBarOrientationChanged()

    // Set the sensor update times
    // 200Hz is the Wiimote update interval
    let updateInterval: Double = 1.0 / 200.0
    self.motionManager.accelerometerUpdateInterval = updateInterval
    self.motionManager.gyroUpdateInterval = updateInterval
    self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // Device motion for enhanced features

    func clamp(_ v: Double) -> Float { return Float(max(-1.0, min(1.0, v))) }
    let accelGain: Double = 1.0 / 9.81 // scale to ~[-1,1] before clamping
    let gyroGain: Double = 1.0 / 8.0   // reduce gyro sensitivity

    // Register the handlers
    self.motionManager.startAccelerometerUpdates(to: operationQueue) { (data, error) in
      if error != nil { return }
      // Get the data
      let acceleration = data!.acceleration

      var x, y: Double
      var z = acceleration.z

      switch self.orientation {
      case .portrait, .unknown:
        x = -acceleration.x
        y = -acceleration.y
      case .landscapeRight:
        x = acceleration.y
        y = -acceleration.x
      case .portraitUpsideDown:
        x = acceleration.x
        y = acceleration.y
      case .landscapeLeft:
        x = -acceleration.y
        y = acceleration.x
      @unknown default:
        return
      }

      // CMAccelerationData's units are G's -> scale to ~[-1,1]
      x *= accelGain
      y *= accelGain
      z *= accelGain

      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelLeft.rawValue, controller: self.port, value: clamp(x))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelRight.rawValue, controller: self.port, value: clamp(x))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelForward.rawValue, controller: self.port, value: clamp(y))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelBackward.rawValue, controller: self.port, value: clamp(y))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelUp.rawValue, controller: self.port, value: clamp(z))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelDown.rawValue, controller: self.port, value: clamp(z))

      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelLeft.rawValue, controller: self.port, value: clamp(x))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelRight.rawValue, controller: self.port, value: clamp(x))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelForward.rawValue, controller: self.port, value: clamp(y))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelBackward.rawValue, controller: self.port, value: clamp(y))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelUp.rawValue, controller: self.port, value: clamp(z))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelDown.rawValue, controller: self.port, value: clamp(z))
    }

    self.motionManager.startGyroUpdates(to: operationQueue) { (data, error) in
      if error != nil { return }

      let rr = data!.rotationRate

      var horiz: Double = 0.0 // from yaw (z)
      var vert: Double = 0.0  // from pitch (x or y depending on orientation)

      switch self.orientation {
      case .portrait, .unknown:
        horiz = rr.z
        vert = -rr.x
      case .portraitUpsideDown:
        horiz = -rr.z
        vert = rr.x
      case .landscapeLeft:
        horiz = rr.z
        vert = -rr.y
      case .landscapeRight:
        horiz = -rr.z
        vert = rr.y
      @unknown default:
        return
      }

      horiz *= gyroGain
      vert  *= gyroGain

      // Map to Wii gyro axes: yaw drives horizontal, pitch drives vertical, roll unused (0)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchUp.rawValue, controller: self.port, value: clamp(vert))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchDown.rawValue, controller: self.port, value: clamp(vert))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollLeft.rawValue, controller: self.port, value: 0)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollRight.rawValue, controller: self.port, value: 0)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawLeft.rawValue, controller: self.port, value: clamp(horiz))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawRight.rawValue, controller: self.port, value: clamp(horiz))
    }

    // Enhanced device motion updates for shake detection, IR cursor, and 6DOF motion
    if self.motionManager.isDeviceMotionAvailable {
      self.motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: operationQueue) { (motion, error) in
        guard let motion = motion, error == nil else { return }

        self.handleEnhancedMotionFeatures(motion: motion)
      }
    }
  }

  /// Handle enhanced motion features: shake detection, IR cursor, and 6DOF motion mapping
  private func handleEnhancedMotionFeatures(motion: CMDeviceMotion) {
    // Enhanced shake detection
    if UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection") {
      handleShakeDetection(motion: motion)
    }

    // IR cursor mapping (when gyro mode is active)
    if DOLConfigBridge.mainTouchPadIRMode() == 0 {
      handleIRCursorMapping(motion: motion)
    }

    // Full 6DOF motion mapping (when not using gyro IR)
    if DOLConfigBridge.mainTouchPadIRMode() != 0 && UserDefaults.standard.bool(forKey: "motion_enable_full_6dof") {
      handle6DOFMotionMapping(motion: motion)
    }
  }

  /// Enhanced shake detection using variance-based algorithm
  private func handleShakeDetection(motion: CMDeviceMotion) {
    let userAccel = motion.userAcceleration
    let magnitude = sqrt(userAccel.x * userAccel.x + userAccel.y * userAccel.y + userAccel.z * userAccel.z)

    shakeHistory.append(magnitude)
    if shakeHistory.count > 15 {
      shakeHistory.removeFirst()
    }

    guard shakeHistory.count >= 8 else { return }

    let mean = shakeHistory.reduce(0, +) / Double(shakeHistory.count)
    let variance = shakeHistory.reduce(0) { acc, val in acc + pow(val - mean, 2) } / Double(shakeHistory.count)
    let standardDeviation = sqrt(variance)

    let varianceThreshold = 0.15
    let accelerationThreshold = 0.8

    let hasHighVariance = standardDeviation > varianceThreshold
    let hasHighAcceleration = magnitude > accelerationThreshold

    if hasHighVariance && hasHighAcceleration {
      let currentTime = Date().timeIntervalSinceReferenceDate
      let shakeCooldown: TimeInterval = 0.5

      if (currentTime - lastShakeTime) > shakeCooldown {
        triggerWiimoteShake()
        lastShakeTime = currentTime
      }
    }
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

        if wiimoteEnabled {
      let accel = motion.userAcceleration
      let gyro = motion.rotationRate

      // Wiimote Accelerometer - use proper IMU button types
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelLeft.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelRight.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelForward.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelBackward.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelUp.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.z))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelDown.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.z))))

      // Wiimote Gyroscope - use proper IMU button types
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchUp.rawValue, controller: port, value: Float(max(-1.0, min(1.0, gyro.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchDown.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -gyro.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollLeft.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -gyro.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollRight.rawValue, controller: port, value: Float(max(-1.0, min(1.0, gyro.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawLeft.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -gyro.z))))
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawRight.rawValue, controller: port, value: Float(max(-1.0, min(1.0, gyro.z))))
    }

    if nunchuckEnabled {
      let accel = motion.userAcceleration

      // Nunchuck Accelerometer - use proper IMU button types
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelLeft.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelRight.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.x))))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelForward.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelBackward.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.y))))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelUp.rawValue, controller: port, value: Float(max(-1.0, min(1.0, accel.z))))
      TCManagerInterface.setAxisValueFor(TCButtonType.nunchukAccelDown.rawValue, controller: port, value: Float(max(-1.0, min(1.0, -accel.z))))

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

  @objc func setMotionEnabled(_ mode: Bool) {
    if self.motionEnabled == mode { return }
    self.motionEnabled = mode

    if self.motionEnabled {
      self.registerMotionHandlers()
    } else {
      self.motionManager.stopAccelerometerUpdates()
      self.motionManager.stopGyroUpdates()
      self.motionManager.stopDeviceMotionUpdates()
    }
  }

  @objc func setPort(_ port: Int) { self.port = port }

  // UIApplicationDidChangeStatusBarOrientationNotification is deprecated...
  @objc func statusBarOrientationChanged() {
    if #available(iOS 13.0, *) {
      if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        self.orientation = scene.interfaceOrientation
        return
      }
    }
    self.orientation = UIApplication.shared.statusBarOrientation
  }
}
#endif
