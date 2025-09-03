// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(CoreMotion)
import CoreMotion
import Foundation

@objc public class TCDeviceMotion: NSObject {
  @objc public static let shared = TCDeviceMotion()

  private let motionManager = CMMotionManager()
  private let operationQueue = OperationQueue()

  private var orientation: UIInterfaceOrientation = .portrait
  private var motionEnabled = false
  private var port = 0

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
  }

  @objc func setMotionEnabled(_ mode: Bool) {
    if self.motionEnabled == mode { return }
    self.motionEnabled = mode

    if self.motionEnabled {
      self.registerMotionHandlers()
    } else {
      self.motionManager.stopAccelerometerUpdates()
      self.motionManager.stopGyroUpdates()
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
