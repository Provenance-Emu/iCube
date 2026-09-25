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

/// Drops the per-controller caches this file keeps, keyed by `ObjectIdentifier`.
///
/// They are module-level dictionaries that nothing used to clean up, so a
/// disconnected controller's shoulder / shake / touchpad-IR state stayed behind
/// forever — and `ObjectIdentifier` is just the object address, so a later
/// allocation could land on the same key and inherit a dead controller's state
/// (e.g. a phantom "all shoulders held" that keeps fast-forward latched).
func releaseControllerInputState(for controller: GCController) {
  let id = ObjectIdentifier(controller)
  touchpadIRStates.removeValue(forKey: id)
  shakeStates.removeValue(forKey: id)
  shoulderStates.removeValue(forKey: id)
  recomputeShoulderGesture()
}

/// Clears every per-controller cache. Called when a game tears down so state
/// cannot leak from one game into the next.
func resetAllControllerInputState() {
  touchpadIRStates.removeAll()
  shakeStates.removeAll()
  shoulderStates.removeAll()
  recomputeShoulderGesture()
}

/// Re-derives the shoulder chord from whatever controllers remain, so removing
/// a controller that was mid-chord releases fast-forward instead of latching it.
func recomputeShoulderGesture() {
  let anyAll = shoulderStates.values.contains { $0.allPressed }
  Task { @MainActor in
    PauseGestureTracker.shared.updateShoulderState(allPressed: anyAll)
  }
}

/// Helper to show the pause menu consistently.
/// Delegates to `PauseGestureTracker.requestPauseMenu`, the single gated +
/// coalesced sink for every pause route.
private func presentPauseMenu(_ reason: String) {
  Task { @MainActor in
    PauseGestureTracker.shared.requestPauseMenu(reason: reason)
  }
}

/// Installs the app-wide "one dedicated button opens the pause menu" handlers.
///
/// - `microGamepad.buttonMenu` (Siri Remote, and the micro profile every MFi
///   controller also exposes) is the **only** button the Siri Remote has, so
///   it keeps opening the pause menu (short press) ungated — no shoulder
///   chord required. This was previously either nil or an empty swallow
///   closure everywhere, which is why the Siri Remote could not reach the
///   pause menu at all.
/// - `extendedGamepad.buttonMenu` (Xbox "≡", the PlayStation button labelled
///   OPTIONS — GameController exposes it as `buttonMenu`, NOT `buttonOptions`
///   — Switch Pro "+", bare MFi Menu) is deliberately **not** wired to the
///   pause menu here.
///   The default Dolphin profiles (`Data/Sys/Profiles/GCPad/Physical
///   Controller.ini` binds `Buttons/Start = Menu`; the Wiimote profile binds
///   `Buttons/+ = Menu`) already map this button to the emulated GameCube
///   START / Wii Remote `+` / Classic Controller `+` via the MFi
///   `ControllerInterface` backend (`Source/Core/InputCommon/
///   ControllerInterface/iOS/MFiController.mm`), which polls
///   `GCControllerButtonInput.isPressed` independently of any Swift
///   `pressedChangedHandler`. Swallowing the press here for the pause menu
///   was the bug: the core kept receiving Start, but the same physical press
///   also paused emulation, so "Start" never visibly worked. Menu still feeds
///   the L1+R1+L2+R2+Menu fast-forward-exit chord through
///   `PauseGestureTracker.menuOrStartPressed()`, which is gated on all four
///   shoulders and therefore never fires on a plain Menu press.
/// - `extendedGamepad.buttonOptions` (Xbox View, PlayStation Share/Create,
///   Switch Pro "-") is the one dedicated pause-menu button on extended
///   gamepads, matching the DualShock/DualSense/Xbox Home-button routes
///   installed in `installExtraInputHandlers`.
///
/// The handlers are installed unconditionally and left installed; a nil handler
/// lets the system take the button back (Game Center / app switcher), which is
/// what the old per-screen swallow closures were working around. The gate is in
/// `requestPauseMenu`, which no-ops unless emulation is actually running, so a
/// press on the library screen is simply absorbed.
///
/// Verified per-family mapping (`MFiController.mm` publishes the GameController
/// element under the listed MFi input name; `Physical Controller.ini` is the
/// GCPad profile that consumes it for GameCube Start):
///
/// | Physical button           | GC element             | MFi input name | Profile binding      | Route here                          |
/// |----------------------------|-------------------------|-----------------|------------------------|---------------------------------------|
/// | PS4/PS5 OPTIONS             | `buttonMenu`            | `"Menu"`        | `Buttons/Start = Menu` | Start only (chord for fast-forward)   |
/// | PS4 Share / PS5 Create       | `buttonOptions`         | `"Options"`     | not bound in GCPad     | pause menu (`menuButtonChanged`)      |
/// | PS4/PS5 PS (Home)            | `GCDualShockGamepad`/`GCDualSenseGamepad`.`buttonHome` | `"Home"` | not bound | pause menu directly (`installExtraInputHandlers`) |
/// | Xbox "≡" (View's counterpart)| `buttonMenu`            | `"Menu"`        | `Buttons/Start = Menu` | Start only                             |
/// | Xbox View                   | `buttonOptions`         | `"Options"`     | not bound in GCPad     | pause menu                            |
/// | Xbox Xbox-button (Home)      | `buttonHome`            | `"Home"`        | not bound | pause menu directly                    |
/// | Switch Pro "+"               | `buttonMenu`            | `"Menu"`        | `Buttons/Start = Menu` | Start only                             |
/// | Switch Pro "-"                | `buttonOptions`         | `"Options"`     | not bound in GCPad     | pause menu                            |
/// | Bare MFi controller (no Options/Home) | `buttonMenu`   | `"Menu"`        | `Buttons/Start = Menu` | Start only + shoulder-chord pause     |
///
/// GameController has no separate "Share" API: `GCExtendedGamepad.buttonOptions`
/// is Apple's name for the PS4 Share / PS5 Create button on every deployment
/// target this app supports (iOS 17+), so there is nothing left to trace there.
///
/// Wii titles: `Data/Sys/Profiles/Wiimote/Physical Controller.ini` used to bind
/// `Buttons/- = Options`, so the same Share/Create/View/"-" press sent the
/// emulated Wii Remote `-` AND opened the pause menu on release, on every
/// family above. The profile now puts `-` on the right stick click (`"R Stick"`,
/// unused by the Wii Remote + Nunchuk layout) and leaves Options to the pause
/// route, the same split as GameCube Start. Existing bindings pick the new
/// profile up when the controller is next bound (reconnect / launch).
func installPauseMenuHandlers(_ c: GCController) {
  if #available(iOS 14.0, tvOS 14.0, *) {
    c.microGamepad?.buttonMenu.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonMenu.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonOptions?.preferredSystemGestureState = .disabled
  }

  c.microGamepad?.buttonMenu.pressedChangedHandler = { _, _, pressed in
    Task { @MainActor in
      PauseGestureTracker.shared.menuButtonChanged(pressed: pressed, reason: "microGamepad.buttonMenu")
    }
  }

  guard let eg = c.extendedGamepad else { return }

  // Menu maps to the emulated Start/+ (see the profile comment above) — do
  // NOT route a plain press to the pause menu. Only the gated shoulder-chord
  // path is wired here. Every transition is also noted on the tracker so it
  // can drop a same-press "uipress-menu" duplicate arriving via EmuEventVC's
  // GCEventViewController bridge — see `PauseGestureTracker.
  // noteExtendedGamepadMenuPress`.
  eg.buttonMenu.pressedChangedHandler = { _, _, pressed in
    Task { @MainActor in
      PauseGestureTracker.shared.noteExtendedGamepadMenuPress(pressed: pressed)
      if pressed { PauseGestureTracker.shared.menuOrStartPressed() }
    }
  }

  // Options is the one dedicated pause-menu button on extended gamepads.
  eg.buttonOptions?.pressedChangedHandler = { _, _, pressed in
    Task { @MainActor in
      PauseGestureTracker.shared.menuButtonChanged(pressed: pressed, reason: "extendedGamepad.buttonOptions")
    }
  }
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
        let controllerId = ControllerManager.touchscreenWiimoteIdBase - 1 + slot
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
        let controllerId = ControllerManager.touchscreenWiimoteIdBase - 1 + slot
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
  //
  // Used to also mirror onto controller 4 (Wii Remote 1's touchscreen instance)
  // "to support profiles bound to P1 only" -- which meant a DS4/DS5 touchpad
  // bound to Wii Remote 2-4 also moved player 1's pointer. Each touchpad now
  // writes only to its own slot's instance; a profile bound to Wii Remote 1
  // is driven by Wii Remote 1's own device (touch overlay or its own pad), not
  // by every other player's touchpad.
  func setIR(controllerId: Int, x: Float, y: Float) {
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredLeft.rawValue, controller: controllerId, value: x)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredRight.rawValue, controller: controllerId, value: x)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredUp.rawValue, controller: controllerId, value: y)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiInfraredDown.rawValue, controller: controllerId, value: y)
  }

  // Internal func
  func mapTouch(_ touchpad: GCControllerDirectionPad?) {
    NSLog("mapTouch: \(String(describing: touchpad))")
    guard let slot = ControllerManager.shared.wiimoteIndex(for: c) else { return }
    let controllerId = ControllerManager.touchscreenWiimoteIdBase - 1 + slot

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
  let recomputeShouldersAndNotify = recomputeShoulderGesture

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

    // DualShock / DualSense / Xbox Home buttons open pause menu directly
    if #available(iOS 14.0, tvOS 14.0, *) {
      if let ds4 = eg as? GCDualShockGamepad {
        // TouchPad
        ds4.touchpadButton?.pressedChangedHandler = { _, _, pressed in
          Task { @MainActor in
            if pressed { PauseGestureTracker.shared.menuOrStartPressed() }
          }
        }
        // Home button
        ds4.buttonHome?.preferredSystemGestureState = .disabled
        // Some OS versions expose a home button
        ds4.buttonHome?.pressedChangedHandler = { _, _, pressed in
          guard pressed else { return }
          presentPauseMenu("ds4.buttonHome")
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
          guard pressed else { return }
          presentPauseMenu("ds5.buttonHome")
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
          guard pressed else { return }
          presentPauseMenu("xbox.buttonHome")
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
    presentPauseMenu("controllerPausedHandler")
  }

  // Ungated Menu/Options -> pause menu for every controller type.
  installPauseMenuHandlers(c)

  // Fix B going back on tvOS
  if #available(tvOS 14.0, *) {
    c.extendedGamepad?.buttonA.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonB.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonX.preferredSystemGestureState = .disabled
    c.extendedGamepad?.buttonY.preferredSystemGestureState = .disabled
  }
}
