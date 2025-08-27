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
            let allFourShoulders = gamepad.leftShoulder.isPressed && gamepad.rightShoulder.isPressed && gamepad.leftTrigger.isPressed && gamepad.rightTrigger.isPressed

            // Option 1: All 4 shoulders + Menu (for controllers with Menu button)
            let menuCombo = allFourShoulders && gamepad.buttonMenu.isPressed
            if menuCombo {
                TVEmulationBridge.pause()
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
                        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
                    }
                }
            }
            #endif
        }
    }

    if let g = c.extendedGamepad {
        let prev = g.valueChangedHandler
        g.valueChangedHandler = { gamepad, element in
            prev?(gamepad, element)
            let pressed: (GCControllerButtonInput?) -> Bool = { $0?.isPressed ?? false }
            // Overrider injection
            InputOverriderBridge.setControl(.gcPadA, controller: 0, value: pressed(gamepad.buttonA) ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadB, controller: 0, value: pressed(gamepad.buttonB) ? 1.0 : 0.0)
            if #available(tvOS 14.0, *) {
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
            let r2Half: Double = gamepad.rightTrigger.isPressed ? 0.49 : 0.0
            let rAnalog = max(Double(gamepad.rightTrigger.value), r2Half)
            InputOverriderBridge.setControl(.gcPadRAnalog, controller: 0, value: rAnalog)
            // Map shoulders to digital L/R
            InputOverriderBridge.setControl(.gcPadLDigital, controller: 0, value: gamepad.leftShoulder.isPressed ? 1.0 : 0.0)
            InputOverriderBridge.setControl(.gcPadRDigital, controller: 0, value: gamepad.rightShoulder.isPressed ? 1.0 : 0.0)
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
            TCManagerInterface.setAxisValueFor(TCButtonType.gcTriggerR.rawValue, controller: 0, value: Float(rAnalog))
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue, controller: 0, value: gamepad.leftThumbstick.xAxis.value)
            let ly = gamepad.leftThumbstick.yAxis.value
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue + 2, controller: 0, value: max(0, ly))
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickMain.rawValue + 3, controller: 0, value: max(0, -ly))
            // C-Stick UI
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue, controller: 0, value: gamepad.rightThumbstick.xAxis.value)
            let cy = gamepad.rightThumbstick.yAxis.value
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue + 2, controller: 0, value: max(0, cy))
            TCManagerInterface.setAxisValueFor(TCButtonType.gcStickC.rawValue + 3, controller: 0, value: max(0, -cy))
            // 4x turbo while all four shoulders/triggers held
            let l1 = gamepad.leftShoulder.isPressed
            let r1 = gamepad.rightShoulder.isPressed
            let l2 = gamepad.leftTrigger.isPressed
            let r2 = gamepad.rightTrigger.isPressed
            let allFour = l1 && r1 && l2 && r2
            let configuredTurbo = UserDefaults.standard.integer(forKey: "controller_turbo_multiplier_percent")
            let turboPercent = (configuredTurbo > 0) ? configuredTurbo : 800
            let targetPercent = allFour ? turboPercent : 100
            let current = DOLConfigBridge.mainEmulationSpeedPercent()
            if current != targetPercent {
                DOLConfigBridge.setMainEmulationSpeedPercent(targetPercent)
            }

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
                    let base = TCButtonType.wiiInfrared.rawValue
                    let values: [Float] = [outY, outY, outX, outX]
                    for (i, v) in values.enumerated() {
                        TCManagerInterface.setAxisValueFor(base + i + 1, controller: 0, value: v)
                    }
                }

                if let ds = gamepad as? GCDualSenseGamepad {
                    process(button: ds.touchpadButton, xAxis: ds.touchpadPrimary.xAxis, yAxis: ds.touchpadPrimary.yAxis)
                } else if let ds4 = gamepad as? GCDualShockGamepad {
                    process(button: ds4.touchpadButton, xAxis: ds4.touchpadPrimary.xAxis, yAxis: ds4.touchpadPrimary.yAxis)
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
    }
}
