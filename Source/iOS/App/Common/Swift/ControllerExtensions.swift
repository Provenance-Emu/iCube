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

func configureControllerForTVOS(_ c: GCController) {
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
        if #available(tvOS 14.0, *) {
            eg.buttonB.preferredSystemGestureState = .disabled
            eg.buttonMenu.preferredSystemGestureState = .alwaysReceive
            eg.buttonOptions?.preferredSystemGestureState = .disabled
        }
    }
    installInputDebugHandlers(c)
}

func configureAllControllersForTVOS() {
    for c in GCController.controllers() {
        configureControllerForTVOS(c)
        installInputDebugHandlers(c)
    }
}

func installInputDebugHandlers(_ c: GCController) {
    // Chain pause handler

    if let gp = c.extendedGamepad {
        if UserDefaults.standard.bool(forKey: "input_debug") {
            NSLog("[INPUT] gamepad handler set")
        }
        if #available(tvOS 14.0, *) {
            gp.buttonB.preferredSystemGestureState = .disabled
            gp.buttonMenu.preferredSystemGestureState = .alwaysReceive
        }
        let prev = gp.valueChangedHandler
        gp.valueChangedHandler = { gamepad, element in
            prev?(gamepad, element)
            let pressed: (GCControllerButtonInput?) -> Bool = { $0?.isPressed ?? false }
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonA.rawValue, controller: 0, state: pressed(gamepad.buttonA))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonB.rawValue, controller: 0, state: pressed(gamepad.buttonB))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonX.rawValue, controller: 0, state: pressed(gamepad.buttonX))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonY.rawValue, controller: 0, state: pressed(gamepad.buttonY))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonUp.rawValue, controller: 0, state: gamepad.dpad.up.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonDown.rawValue, controller: 0, state: gamepad.dpad.down.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonLeft.rawValue, controller: 0, state: gamepad.dpad.left.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonRight.rawValue, controller: 0, state: gamepad.dpad.right.isPressed)
            if #available(tvOS 14.0, *) {
                let menu = gamepad.buttonMenu
                if menu.isPressed {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 1.0)
                } else {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 0.0)
                }
            }
            // Multiple pause gesture options for different controller types (tvOS)
            #if os(tvOS)
            let l1Down = gamepad.leftShoulder.isPressed
            let r1Down = gamepad.rightShoulder.isPressed
            let l2Down = gamepad.leftTrigger.value > 0.5
            let r2Down = gamepad.rightTrigger.value > 0.5
            let allFourShoulders = l1Down && r1Down && l2Down && r2Down

            // Option 1: All 4 shoulders + Menu (for controllers with Menu button)
            let menuCombo = allFourShoulders && gamepad.buttonMenu.isPressed
            if menuCombo {
                TVEmulationBridge.pause()
                #if canImport(ActivityKit)
                GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
                #endif
                NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
            }

            // Option 2: All 4 shoulders held for 2 seconds (for controllers without Menu button)
            PauseGestureTracker.shared.updateShoulderState(allPressed: allFourShoulders)

            // Option 3: L1+R1+Options (if available, for controllers with Options but no Menu)
            if #available(tvOS 14.0, *) {
                if let options = gamepad.buttonOptions {
                    let optionsCombo = gamepad.leftShoulder.isPressed && gamepad.rightShoulder.isPressed && options.isPressed
                    if optionsCombo {
                        TVEmulationBridge.pause()
                        #if canImport(ActivityKit)
                        GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
                        #endif
                        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
                    }
                }
            }
            #endif
        }
        // Install high-reliability handlers for Menu/Options/Home presses
        if #available(iOS 14.0, tvOS 14.0, *) {
            /// Map Menu button to Start reliably and trigger pause chord when applicable
            gp.buttonMenu.pressedChangedHandler = { _, _, pressed in
                InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: pressed ? 1.0 : 0.0)
                if pressed {
                    PauseGestureTracker.shared.menuOrStartPressed()
                }
            }
            /// Treat Options as Start-equivalent for pause chord and quick menu on iOS
            if let options = gp.buttonOptions {
                options.pressedChangedHandler = { _, _, pressed in
                    if pressed {
                        PauseGestureTracker.shared.menuOrStartPressed()
                        #if os(iOS)
                        TVEmulationBridge.pause()
                        #if canImport(ActivityKit)
                        GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
                        #endif
                        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
                        #endif
                    }
                }
            }
            /// Home can also act as Start for chord if available and not reserved
            if let home = gp.buttonHome {
                home.pressedChangedHandler = { _, _, pressed in
                    if pressed {
                        PauseGestureTracker.shared.menuOrStartPressed()
                    }
                }
            }
        }
    }

    if let g = c.extendedGamepad {
        if UserDefaults.standard.bool(forKey: "input_debug") {
            NSLog("[INPUT] extendedGamepad handler set for %@", c.vendorName ?? "(nil)")
        }
        let prev = g.valueChangedHandler
        g.valueChangedHandler = { gamepad, element in
            prev?(gamepad, element)
            let pressed: (GCControllerButtonInput?) -> Bool = { $0?.isPressed ?? false }
            // Overrider injection
            InputOverriderBridge.setControl(.gcPadA, controller: 0, value: pressed(gamepad.buttonA) ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadB, controller: 0, value: pressed(gamepad.buttonB) ? 1.0 : 0.0)
            if #available(tvOS 14.0, iOS 14.0, *) {
                let menu = gamepad.buttonMenu
                if menu.isPressed {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 1.0)
                } else {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 0.0)
                }
            }
            InputOverriderBridge.setControl(.gcPadX, controller: 0, value: pressed(gamepad.buttonX) ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadY, controller: 0, value: pressed(gamepad.buttonY) ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadUp, controller: 0, value: gamepad.dpad.up.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadDown, controller: 0, value: gamepad.dpad.down.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadLeft, controller: 0, value: gamepad.dpad.left.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadRight, controller: 0, value: gamepad.dpad.right.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadLAnalog, controller: 0, value: Double(gamepad.leftTrigger.value))
            // R2 is pure analog R; R1 should map to Z
            InputOverriderBridge.setControl(.gcPadRAnalog, controller: 0, value: Double(gamepad.rightTrigger.value))
            // Map shoulders: L1 -> L digital, R1 -> Z digital (not R digital)
            InputOverriderBridge.setControl(.gcPadLDigital, controller: 0, value: gamepad.leftShoulder.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadZ, controller: 0, value: gamepad.rightShoulder.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadMainStickX, controller: 0, value: Double(gamepad.leftThumbstick.xAxis.value))
            InputOverriderBridge.setControl(.gcPadMainStickY, controller: 0, value: Double(gamepad.leftThumbstick.yAxis.value))
            // Map right thumbstick to C-Stick
            InputOverriderBridge.setControl(.gcPadCStickX, controller: 0, value: Double(gamepad.rightThumbstick.xAxis.value))
            InputOverriderBridge.setControl(.gcPadCStickY, controller: 0, value: Double(gamepad.rightThumbstick.yAxis.value))
            // StateManager injection too
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonA.rawValue, controller: 0, state: pressed(gamepad.buttonA))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonB.rawValue, controller: 0, state: pressed(gamepad.buttonB))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonX.rawValue, controller: 0, state: pressed(gamepad.buttonX))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonY.rawValue, controller: 0, state: pressed(gamepad.buttonY))
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonUp.rawValue, controller: 0, state: gamepad.dpad.up.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonDown.rawValue, controller: 0, state: gamepad.dpad.down.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonLeft.rawValue, controller: 0, state: gamepad.dpad.left.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonRight.rawValue, controller: 0, state: gamepad.dpad.right.isPressed)
            TCManagerInterface.setAxisValueFor(TCButtonType.gcTriggerL.rawValue, controller: 0, value: gamepad.leftTrigger.value)
            TCManagerInterface.setAxisValueFor(TCButtonType.gcTriggerR.rawValue, controller: 0, value: gamepad.rightTrigger.value)
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue, controller: 0, value: gamepad.leftThumbstick.xAxis.value)
            let ly = gamepad.leftThumbstick.yAxis.value
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue + 2, controller: 0, value: max(0, ly))
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue + 3, controller: 0, value: max(0, -ly))
            // C-Stick UI
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue, controller: 0, value: gamepad.rightThumbstick.yAxis.value)
            let cy = gamepad.rightThumbstick.yAxis.value
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue + 2, controller: 0, value: max(0, cy))
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue + 3, controller: 0, value: max(0, -cy))
            // Non-gesture Wiimote shake: map L3/R3 press to a short shake pulse on the assigned Wiimote slot
            if #available(iOS 12.0, tvOS 14.0, *), let slot = ControllerManager.shared.wiimoteIndex(for: c) {
                let controllerId = 3 + slot
                let pulse: () -> Void = {
                    let b = TCButtonType.wiiShakeZ.rawValue
                    TCManagerInterface.setButtonStateFor(b, controller: controllerId, state: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        TCManagerInterface.setButtonStateFor(b, controller: controllerId, state: false)
                    }
                }
                if let l3 = gamepad.leftThumbstickButton, element === l3, l3.isPressed { pulse() }
                if let r3 = gamepad.rightThumbstickButton, element === r3, r3.isPressed { pulse() }
            }
            // 4x turbo while all four shoulders/triggers held
            let controllerId = ObjectIdentifier(c)
            // Use analog threshold for triggers to be more reliable across controllers
            let l1Down = gamepad.leftShoulder.isPressed
            let r1Down = gamepad.rightShoulder.isPressed
            let l2Down = gamepad.leftTrigger.value > 0.5
            let r2Down = gamepad.rightTrigger.value > 0.5
            let allFour = l1Down && r1Down && l2Down && r2Down
            if UserDefaults.standard.bool(forKey: "input_debug") {
                NSLog("[INPUT][Turbo] L1=%d R1=%d L2=%.2f R2=%.2f allFour=%d", l1Down, r1Down, gamepad.leftTrigger.value, gamepad.rightTrigger.value, allFour)
            }

            let wasActive = activeTurboControllers.contains(controllerId)
            if allFour && !wasActive {
                activeTurboControllers.insert(controllerId)
                if activeTurboControllers.count == 1 {
                    let configuredTurbo = UserDefaults.standard.integer(forKey: "controller_turbo_multiplier_percent")
                    let turboPercent = (configuredTurbo > 0) ? configuredTurbo : 800
                    DOLConfigBridge.setMainEmulationSpeedPercent(turboPercent)
                    if UserDefaults.standard.bool(forKey: "input_debug") {
                        NSLog("[INPUT][Turbo] ENTER turbo at %d%%", turboPercent)
                    }
                    NotificationCenter.default.post(name: Notification.Name("DOLFastForwardToggled"), object: nil, userInfo: ["enabled": true])
                }
            } else if !allFour && wasActive {
                activeTurboControllers.remove(controllerId)
                if activeTurboControllers.isEmpty {
                    DOLConfigBridge.setMainEmulationSpeedPercent(100)
                    if UserDefaults.standard.bool(forKey: "input_debug") {
                        NSLog("[INPUT][Turbo] EXIT turbo")
                    }
                    NotificationCenter.default.post(name: Notification.Name("DOLFastForwardToggled"), object: nil, userInfo: ["enabled": false])
                }
            }

            // Shoulder + Menu/Options -> Pause
            PauseGestureTracker.shared.updateShoulderState(allPressed: allFour)
            if #available(tvOS 14.0, iOS 14.0, *) {
                if element === gamepad.buttonMenu, gamepad.buttonMenu.isPressed {
                    PauseGestureTracker.shared.menuOrStartPressed()
                }
                if let options = gamepad.buttonOptions, element === options, options.isPressed {
                    PauseGestureTracker.shared.menuOrStartPressed()
                }
            }

            #if os(iOS)
            // Quick actions: Share/Options → quick menu; L1 → toggle touch cursor mode
            if #available(iOS 14.0, *) {
                if let options = gamepad.buttonOptions, options.isPressed {
                    TVEmulationBridge.pause()
                    #if canImport(ActivityKit)
                    GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
                    #endif
                    NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
                }
            }
            if gamepad.leftShoulder.isPressed {
                let mode = DOLConfigBridge.mainTouchPadIRMode()
                let next = (mode == 1) ? 2 : 1
                DOLConfigBridge.setMainTouchPadIRMode(next)
                NotificationCenter.default.post(name: Notification.Name("DOLTouchCursorModeChanged"), object: nil)
            }
            #endif

            // DualSense/DualShock touchpad -> Wii IR mapping
            if #available(iOS 14.5, tvOS 14.5, *) {
                let controllerId = ObjectIdentifier(c)
                let state = touchpadIRStates[controllerId] ?? TouchpadIRState()
                touchpadIRStates[controllerId] = state

                // Read configured IR mode
                let modeRaw = DOLConfigBridge.mainTouchPadIRMode()
                guard let irMode = TCWiiTouchIRMode(rawValue: modeRaw), irMode != .none else {
                    // Reset state when disabled
                    state.touching = false
                    state.startX = 0; state.startY = 0
                    // Do not push IR axes when disabled
                    // Note: IMUPoint enable/disable handled elsewhere (EmulationiOSViewController)
                    return
                }

                // Helper to process a specific touchpad provider
                func process(button: GCControllerButtonInput, xAxis: GCControllerAxisInput, yAxis: GCControllerAxisInput) {
                    // Apple's API typically provides 0..1 for touchpad coordinates; map to -1..1 centered
                    let rawX = xAxis.value
                    let rawY = yAxis.value
                    let nx = max(-1.0 as Float, min(1.0 as Float, rawX * 2 - 1))
                    let ny = max(-1.0 as Float, min(1.0 as Float, rawY * 2 - 1))

                    let isPressed = button.isPressed

                    var outX: Float = 0
                    var outY: Float = 0

                    switch irMode {
                    case .follow:
                        // Optionally allow follow without click, controlled by settings
                        let withoutClick = UserDefaults.standard.bool(forKey: "touchpad_ir_follow_without_click")
                        if !withoutClick && !isPressed { return }
                        outX = nx
                        outY = ny
                        // When switching back to follow, reset drag state
                        state.touching = false
                        state.startX = 0; state.startY = 0
                        state.oldX = 0; state.oldY = 0
                    case .drag:
                        if isPressed && !state.touching {
                            state.touching = true
                            state.startX = nx
                            state.startY = ny
                        }
                        if isPressed {
                            outX = state.oldX + (nx - state.startX)
                            outY = state.oldY + (ny - state.startY)
                        } else {
                            if state.touching {
                                // Commit accumulated offset when finger lifts
                                state.oldX = max(-1, min(1, state.oldX + (nx - state.startX)))
                                state.oldY = max(-1, min(1, state.oldY + (ny - state.startY)))
                                state.touching = false
                            }
                            outX = state.oldX
                            outY = state.oldY
                        }
                    default:
                        break
                    }

                    // Push to Wii IR axes: order [Y, Y, X, X] to match TCWiiPad
                    if let slot = ControllerManager.shared.wiimoteIndex(for: c) {
                        let controllerId = 3 + slot
                        let base = TCButtonType.wiiInfrared.rawValue
                        let values: [Float] = [outY, outY, outX, outX]
                        for (i, v) in values.enumerated() {
                            TCManagerInterface.setAxisValueFor(base + i + 1, controller: controllerId, value: v)
                        }
                    }
                }

                if let ds = gamepad as? GCDualSenseGamepad {
                    process(button: ds.touchpadButton, xAxis: ds.touchpadPrimary.xAxis, yAxis: ds.touchpadPrimary.yAxis)
                } else if let ds4 = gamepad as? GCDualShockGamepad {
                    process(button: ds4.touchpadButton, xAxis: ds4.touchpadPrimary.xAxis, yAxis: ds4.touchpadPrimary.yAxis)
                }
            }
        }
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

    if let mg = c.microGamepad {
        if UserDefaults.standard.bool(forKey: "input_debug") {
            NSLog("[INPUT] microGamepad handler set")
        }
        let prev = mg.valueChangedHandler
        mg.valueChangedHandler = { micro, element in
            prev?(micro, element)
            InputOverriderBridge.setControl(.gcPadA, controller: 0, value: micro.buttonA.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadB, controller: 0, value: micro.buttonX.isPressed ? 1.0 : 0.0)
            if #available(tvOS 14.0, *) {
                let menu = micro.buttonMenu
                if menu.isPressed {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 1.0)
                } else {
                    InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: 0.0)
                }
            }
            let dx = micro.dpad.xAxis.value
            let dy = micro.dpad.yAxis.value
            InputOverriderBridge.setControl(.gcPadDpadLeft, controller: 0, value: dx < -0.5 ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadRight, controller: 0, value: dx > 0.5 ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadDown, controller: 0, value: dy < -0.5 ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadDpadUp, controller: 0, value: dy > 0.5 ? 1.0 : 0.0)
            // also StateManager
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonA.rawValue, controller: 0, state: micro.buttonA.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonB.rawValue, controller: 0, state: micro.buttonX.isPressed)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonLeft.rawValue, controller: 0, state: dx < -0.5)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonRight.rawValue, controller: 0, state: dx > 0.5)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonDown.rawValue, controller: 0, state: dy < -0.5)
            TCManagerInterface.setButtonStateFor(TCButtonType.gcButtonUp.rawValue, controller: 0, state: dy > 0.5)
        }
        // High-reliability Start mapping for remotes/controllers with only Menu button
        if #available(iOS 14.0, tvOS 14.0, *) {
            /// Map Menu to Start and also allow pause chord when applicable
            mg.buttonMenu.pressedChangedHandler = { _, _, pressed in
                InputOverriderBridge.setControl(.gcPadStart, controller: 0, value: pressed ? 1.0 : 0.0)
                if pressed {
                    PauseGestureTracker.shared.menuOrStartPressed()
                }
            }
        }
    }
}
