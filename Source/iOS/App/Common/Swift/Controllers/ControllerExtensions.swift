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

func configureController(_ c: GCController) {
  if let mg = c.microGamepad {
    mg.reportsAbsoluteDpadValues = true
    mg.allowsRotation = true
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog("[INPUT] Configured microGamepad: absolute=%d rotation=%d", mg.reportsAbsoluteDpadValues, mg.allowsRotation)
    }
    if #available(tvOS 14.0, *) {
      mg.buttonX.preferredSystemGestureState = .disabled
    }
  }
  if let eg = c.extendedGamepad {
    eg.buttonB.preferredSystemGestureState = .disabled
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

func installExtraInputHandlers(_ c: GCController) {
  
  // Map controller motion (if available) to Wii accelerometer and gyro
  if #available(iOS 14.0, tvOS 14.0, *), let motion = c.motion {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
              TCManagerInterface.setButtonStateFor(button, controller: controllerId, state: false)
            }
          }
        }
        
        // Axis thresholds
        if abs(ax) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeX.rawValue, last: &state.lastTriggerX) }
        if abs(ay) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeY.rawValue, last: &state.lastTriggerY) }
        if abs(az) > accelAxisThresh { trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ) }
        
        // Combined magnitude thresholds (accel and rotation) as fallback
        let amag = sqrtf(ax*ax + ay*ay + az*az)
        if amag > accelMagThresh {
          // Prefer Z for generic shakes, but also bump X/Y timers so rapid repeats don't spam
          trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ)
        } else {
          let rmag = sqrtf(gx*gx + gy*gy + gz*gz)
          if rmag > rotMagThresh {
            trigger(button: TCButtonType.wiiShakeZ.rawValue, last: &state.lastTriggerZ)
          }
        }
        
        shakeStates[id] = state
      }
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT][Motion] acc(%.2f,%.2f,%.2f) rot(%.2f,%.2f,%.2f)", ax, ay, az, gx, gy, gz)
      }
    }
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
      extendedGamepad.buttonMenu.preferredSystemGestureState = .alwaysReceive
    }
  }
  
  if let microGamepad = controller.microGamepad {
    if #available(iOS 14, tvOS 14.0, *) {
      // Ensure Menu button preference is set to always receive for micro gamepad too
      microGamepad.buttonMenu.preferredSystemGestureState = .alwaysReceive
    }
  }
}
