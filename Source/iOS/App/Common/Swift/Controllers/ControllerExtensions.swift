// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController

// Track per-controller state for touchpad-based Wii IR drag mode
private final class TouchpadIRState {
  var touching: Bool = false
  var startX: Float = 0
  var startY: Float = 0
  var oldX: Float = 0
  var oldY: Float = 0
}

private var touchpadIRStates: [ObjectIdentifier: TouchpadIRState] = [:]
private var activeTurboControllers: Set<ObjectIdentifier> = []

// Shake detection state per controller
private struct ShakeState {
  var lastTriggerX: TimeInterval = 0
  var lastTriggerY: TimeInterval = 0
  var lastTriggerZ: TimeInterval = 0
}

private var shakeStates: [ObjectIdentifier: ShakeState] = [:]

/// Shoulder state tracking for pause/fast-forward gestures
private final class ShoulderState {
  var l1: Bool = false
  var r1: Bool = false
  var l2: Bool = false
  var r2: Bool = false
  var allPressed: Bool { l1 && r1 && l2 && r2 }
}

private var shoulderStates: [ObjectIdentifier: ShoulderState] = [:]

/// Helper to show the pause menu consistently
private func presentPauseMenu() {
  #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
  GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
  #endif
  TVEmulationBridge.pause()
  NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
}

func configureController(_ c: GCController) {
  if let mg = c.microGamepad {
    mg.reportsAbsoluteDpadValues = true
    mg.allowsRotation = true
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog("[INPUT] Configured microGamepad: absolute=%d rotation=%d", mg.reportsAbsoluteDpadValues, mg.allowsRotation)
    }
    if #available(tvOS 14.0, *) {
      mg.buttonA.preferredSystemGestureState = .disabled
      mg.buttonX.preferredSystemGestureState = .disabled
      mg.buttonMenu.preferredSystemGestureState = .disabled
    }
  }
  if let eg = c.extendedGamepad {
    eg.allButtons.forEach { button in
      button.preferredSystemGestureState = .disabled
    }
    eg.buttonB.preferredSystemGestureState = .disabled
    eg.buttonHome?.preferredSystemGestureState = .disabled
    eg.buttonMenu.preferredSystemGestureState = .disabled
    eg.buttonOptions?.preferredSystemGestureState = .disabled
  }
  installExtraInputHandlers(c)
}

func configureAllControllers() {
  for c in GCController.controllers() {
    configureController(c)
  }
}

private func installMotionHandler(_ c: GCController) {
  // Map controller motion (if available) to Wii accelerometer and gyro
  if #available(iOS 14.0, tvOS 14.0, *), let motion = c.motion {
    /// Some controllers (e.g. DualShock 4) require manual activation for motion sensors
    if motion.sensorsRequireManualActivation {
      motion.sensorsActive = true
    }
    motion.valueChangedHandler = { m in
      // Use userAcceleration for shake/tilt impulses and rotationRate for gyro
      let ax = Float(m.userAcceleration.x)
      let ay = Float(m.userAcceleration.y)
      let az = Float(m.userAcceleration.z)
      // Accelerometer -> Wii accel axes
      if let slot = ControllerManager.shared.wiimoteIndex(for: c) {
        let controllerId = 3 + slot
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelLeft.rawValue, controller: controllerId, value: ax)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelRight.rawValue, controller: controllerId, value: ax)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelForward.rawValue, controller: controllerId, value: ay)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelBackward.rawValue, controller: controllerId, value: ay)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelUp.rawValue, controller: controllerId, value: az)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiAccelDown.rawValue, controller: controllerId, value: az)
      }
      // Gyro -> Wii gyro axes
      let gx = Float(m.rotationRate.x)
      let gy = Float(m.rotationRate.y)
      let gz = Float(m.rotationRate.z)
      if let slot = ControllerManager.shared.wiimoteIndex(for: c) {
        let controllerId = 3 + slot
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchUp.rawValue, controller: controllerId, value: gx)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchDown.rawValue, controller: controllerId, value: gx)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollLeft.rawValue, controller: controllerId, value: gy)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroRollRight.rawValue, controller: controllerId, value: gy)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawLeft.rawValue, controller: controllerId, value: gz)
        TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroYawRight.rawValue, controller: controllerId, value: gz)

        // Shake synthesis from high acceleration/rotation spikes; small debounce
        let id = ObjectIdentifier(c)
        let now = Date().timeIntervalSince1970
        var state = shakeStates[id] ?? ShakeState()
        let debounce: TimeInterval = 0.18
        let hold: TimeInterval = 0.10
        let accelAxisThresh: Float = 0.80
        let accelMagThresh: Float = 1.10
        let rotMagThresh: Float = 4.5

        func trigger(button: Int, last: inout TimeInterval) {
          if now - last >= debounce {
            last = now
            TCManagerInterface.setButtonStateFor(button, controller: controllerId, state: true)
            // Mirror to controller 1 to satisfy Physical Controller.ini shake mapping
            TCManagerInterface.setButtonStateFor(button, controller: 1, state: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
              TCManagerInterface.setButtonStateFor(button, controller: controllerId, state: false)
              TCManagerInterface.setButtonStateFor(button, controller: 1, state: false)
            }
          }
        }

        // Axis thresholds
        if abs(ax) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeX.rawValue, last: &state.lastTriggerX) }
        if abs(ay) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeY.rawValue, last: &state.lastTriggerY) }
        if abs(az) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ) }

        // Combined magnitude thresholds (accel and rotation) as fallback
        let amag = sqrtf(ax * ax + ay * ay + az * az)
        if amag > accelMagThresh {
          trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ)
        } else {
          let rmag = sqrtf(gx * gx + gy * gy + gz * gz)
          if rmag > rotMagThresh {
            trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ)
          }
        }

        shakeStates[id] = state
      }
//      if UserDefaults.standard.bool(forKey: "input_debug") {
//        NSLog("[INPUT][Motion] acc(%.2f,%.2f,%.2f) rot(%.2f,%.2f,%.2f)", ax, ay, az, gx, gy, gz)
//      }
    }
  }
}

private func installTouchpadIRHandlers(_ c: GCController, eg: GCExtendedGamepad) {
//  guard DOLConfigBridge.mainTouchPadIRMode() != 0 else { return }
  let irMode = DOLConfigBridge.mainTouchPadIRMode() // 1 = follow, 2 = drag

  // Internal func
  func setIR(controllerId: Int, x: Float, y: Float) {
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredLeft.rawValue, controller: controllerId, value: x)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredRight.rawValue, controller: controllerId, value: x)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredUp.rawValue, controller: controllerId, value: y)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredDown.rawValue, controller: controllerId, value: y)
    // Also mirror to Wiimote 1 to support profiles bound to P1 only
    if controllerId != 4 {
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredLeft.rawValue, controller: 4, value: x)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredRight.rawValue, controller: 4, value: x)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredUp.rawValue, controller: 4, value: y)
      TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredDown.rawValue, controller: 4, value: y)
    }
  }

  // Internal func
  func mapTouch(_ touchpad: GCControllerDirectionPad?) {
    NSLog("mapTouch: \(String(describing: touchpad))")
    guard let slot = ControllerManager.shared.wiimoteIndex(for: c) else { return }
    let controllerId = 3 + slot

    let id = ObjectIdentifier(c)
    if touchpadIRStates[id] == nil { touchpadIRStates[id] = TouchpadIRState() }
    guard touchpadIRStates[id] != nil else { return }

    // Read current pad values in [-1, 1]
    let xRaw = touchpad?.xAxis.value ?? 0.0
    let yRaw = touchpad?.yAxis.value ?? 0.0

    // Map to IR: X is direct, Y is inverted (IR up is negative)
    let absX = max(-1, min(1, xRaw))
    let absY = max(-1, min(1, -yRaw))

    switch irMode {
    case 0, 1, 2: // absolute mapping for stability
      NSLog("setIR(controllerId \(controllerId) \(absX) , \(absY)")
      setIR(controllerId: controllerId, x: absX, y: absY)
//    case 2: // drag/relative – accumulate deltas
//      if !state.touching {
//        state.touching = true
//        state.startX = xVal
//        state.startY = yVal
//        state.oldX = xVal
//        state.oldY = yVal
//      }
//      let dx = xVal - state.oldX
//      let dy = yVal - state.oldY
//      state.oldX = xVal
//      state.oldY = yVal
//      // Sensitivity tuned for comfortable cursor speed
//      let sens: Float = 2.0
    ////      let curX = max(-1, min(1, ((touchpad?.value(forKey: "_pv_ir_accum_x") as? Float) ?? 0) + dx * sens))
    ////      let curY = max(-1, min(1, ((touchpad?.value(forKey: "_pv_ir_accum_y") as? Float) ?? 0) - dy * sens))
//      setIR(controllerId: controllerId, x: curX, y: curY)
//      // This chrashes
    ////      touchpad?.setValue(curX, forKey: "_pv_ir_accum_x")
    ////      touchpad?.setValue(curY, forKey: "_pv_ir_accum_y")
    default:
      break
    }
  }

  if #available(iOS 14.0, tvOS 14.0, *), let ds4 = eg as? GCDualShockGamepad {
    let tp = ds4.touchpadPrimary
    tp?.xAxis.valueChangedHandler = { _, _ in mapTouch(tp) }
    tp?.yAxis.valueChangedHandler = { _, _ in mapTouch(tp) }
//    ds4.touchpadButton?.pressedChangedHandler = { _, _, pressed in
//      let id = ObjectIdentifier(c)
//      if let pad = tp as AnyObject? {
//        pad.setValue(0 as Float, forKey: "_pv_ir_accum_x")
//        pad.setValue(0 as Float, forKey: "_pv_ir_accum_y")
//      }
//      touchpadIRStates[id]?.touching = pressed
//    }
  }

  if #available(iOS 14.0, tvOS 14.0, *), let ds5 = eg as? GCDualSenseGamepad {
    let tp = ds5.touchpadPrimary
    tp.xAxis.valueChangedHandler = { _, _ in mapTouch(tp) }
    tp.yAxis.valueChangedHandler = { _, _ in mapTouch(tp) }
//    ds5.touchpadButton?.pressedChangedHandler = { _, _, pressed in
//      let id = ObjectIdentifier(c)
//      if let pad = tp as AnyObject? {
//        pad.setValue(0 as Float, forKey: "_pv_ir_accum_x")
//        pad.setValue(0 as Float, forKey: "_pv_ir_accum_y")
//      }
//      touchpadIRStates[id]?.touching = pressed
//    }
  }
}

func installExtraInputHandlers(_ c: GCController) {
  installMotionHandler(c)

  // Pause + shoulder gesture handling
  let id = ObjectIdentifier(c)
  if shoulderStates[id] == nil { shoulderStates[id] = ShoulderState() }
  func recomputeShouldersAndNotify() {
    let anyAll = shoulderStates.values.contains { $0.allPressed }
    Task { @MainActor in
      PauseGestureTracker.shared.updateShoulderState(allPressed: anyAll)
    }
  }

  if let eg = c.extendedGamepad {
    // Shoulder buttons
    eg.leftShoulder.pressedChangedHandler = { _, _, pressed in
      shoulderStates[id, default: ShoulderState()].l1 = pressed
      recomputeShouldersAndNotify()
    }
    eg.rightShoulder.pressedChangedHandler = { _, _, pressed in
      shoulderStates[id, default: ShoulderState()].r1 = pressed
      recomputeShouldersAndNotify()
    }
    eg.leftTrigger.pressedChangedHandler = { _, _, pressed in
      shoulderStates[id, default: ShoulderState()].l2 = pressed
      recomputeShouldersAndNotify()
    }
    eg.rightTrigger.pressedChangedHandler = { _, _, pressed in
      shoulderStates[id, default: ShoulderState()].r2 = pressed
      recomputeShouldersAndNotify()
    }

    // Start/Menu style buttons should consult PauseGestureTracker for shoulder+start combo
    eg.buttonMenu.pressedChangedHandler = { _, _, pressed in
      Task { @MainActor in
        if pressed { PauseGestureTracker.shared.menuOrStartPressed() }
      }
    }
    eg.buttonOptions?.pressedChangedHandler = { _, _, pressed in
      Task { @MainActor in
        if pressed { PauseGestureTracker.shared.menuOrStartPressed() }
      }
    }

    // DualShock / DualSense / Xbox Home buttons open pause menu directly
    if #available(iOS 14.0, tvOS 14.0, *) {
      if let ds4 = eg as? GCDualShockGamepad {
        // TouchPad
        ds4.touchpadButton?.pressedChangedHandler = { _, _, pressed in
          Task { @MainActor in
            NSLog("ds4.touchpadButton")
            if pressed { PauseGestureTracker.shared.menuOrStartPressed() }
          }
        }
        // Home button
        ds4.buttonHome?.preferredSystemGestureState = .disabled
        // Some OS versions expose a home button
        ds4.buttonHome?.pressedChangedHandler = { _, _, pressed in
          Task { @MainActor in
            NSLog("ds4.buttonHome")
            if pressed { presentPauseMenu() }
          }
        }
        // Install IR mapping from touchpad
        installTouchpadIRHandlers(c, eg: eg)
      }
    }
    if #available(iOS 14.0, tvOS 14.0, *) {
      if let ds5 = eg as? GCDualSenseGamepad {
        // Home button
        ds5.buttonHome?.preferredSystemGestureState = .disabled

        ds5.buttonHome?.pressedChangedHandler = { _, _, pressed in
          Task { @MainActor in
            NSLog("ds5.buttonHome")
            if pressed { presentPauseMenu() }
          }
        }
        // Install IR mapping from touchpad
        installTouchpadIRHandlers(c, eg: eg)
      }
    }
    if #available(iOS 14.5, tvOS 14.5, *) {
      if let xbox = eg as? GCXboxGamepad {
        // Home button
        xbox.buttonHome?.preferredSystemGestureState = .disabled

        xbox.buttonHome?.pressedChangedHandler = { _, _, pressed in
          Task { @MainActor in
            NSLog("xbox.buttonHome")
            if pressed { presentPauseMenu() }
          }
        }
      }
    }
  }

  // Home button Apple nonsense fixes

  // Home - Extended
  c.extendedGamepad?.buttonOptions?.preferredSystemGestureState = .disabled
  c.extendedGamepad?.buttonHome?.preferredSystemGestureState = .disabled
  c.extendedGamepad?.buttonMenu.preferredSystemGestureState = .disabled

  // Home - Micro
  c.microGamepad?.buttonMenu.preferredSystemGestureState = .disabled
  // Generic pause handler for controllers that surface a pause/home action
  // ! THIS IS REQUIRED FOR CONTROLLERS LIKE NIMBUS
  // in order to prevent GameCenter from opening.
  // IGNORE THE COMPILER WARNING, USING .HOME HANDLER IS NOT GOOD ENOUGH!
  // FUCK YOU APPLE I HATE THIS STUPID MENU BUTTON SHIT AND ALL OF GCCONTROLLER!!!
  c.controllerPausedHandler = { _ in
    Task { @MainActor in
      NSLog("controllerPausedHandler entered")
      PauseGestureTracker.shared.menuOrStartPressed()
    }
  }

  // Fix B going back on tvOS
  if #available(tvOS 14.0, *) {
    c.extendedGamepad?.buttonA.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonB.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonX.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonY.preferredSystemGestureState = .disabled
  }
}

/// Sets up pause gesture handlers for all currently connected controllers
func setupPauseGestureHandlers() {
  for controller in GCController.controllers() {
    setupPauseGestureHandler(for: controller)
  }
}

/// Sets up pause gesture handler for a specific controller
/// Supports multiple pause gesture combinations:
/// - L1+R1+L2+R2+Menu (for controllers with Menu button)
/// - L1+R1+L2+R2 held for 2 seconds (for controllers without Menu button)
/// - L1+R1+Options (for controllers with Options button but no Menu)
func setupPauseGestureHandler(for controller: GCController) {
  // The pause gesture handling is already implemented in installInputDebugHandlers
  // in ControllerExtensions.swift, so we just need to ensure it's called
  installExtraInputHandlers(controller)

  // Also ensure Menu button is mapped to Start for controllers that have it
  if let extendedGamepad = controller.extendedGamepad {
    if #available(iOS 14, tvOS 14.0, *) {
      // Ensure Menu button preference is set to always receive
      extendedGamepad.buttonMenu.preferredSystemGestureState = .disabled
    }
  }

  if let microGamepad = controller.microGamepad {
    if #available(iOS 14, tvOS 14.0, *) {
      // Ensure Menu button preference is set to always receive for micro gamepad too
      microGamepad.buttonMenu.preferredSystemGestureState = .disabled
    }
  }
}
