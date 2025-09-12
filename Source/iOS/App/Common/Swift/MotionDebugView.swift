// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import CoreMotion
import GameController

var lastShakeTime: TimeInterval = 0

/// Debug view for motion controls, gyro input, and touch mappings
struct MotionDebugView: View {
    @State private var isMotionEnabled = false
    @State private var motionData: MotionDebugData = MotionDebugData()
    @State private var touchControlsVisible = false
    @State private var currentIRMode = 0
    @State private var shakeDetectionEnabled = false
    @State private var debugLoggingEnabled = false
    @State private var refreshTimer: Timer?
    @State private var show3DView = true
    @State private var shakeHistory: [Double] = []
    @State private var motionManager: CMMotionManager?

    // Enhanced Motion Controls - Use @AppStorage for automatic UI updates
    @AppStorage("motion_enhanced_shake_detection") private var enhancedShakeEnabled: Bool = false
    @AppStorage("motion_enable_ir_cursor") private var gyroIREnabled: Bool = false
    @AppStorage("motion_use_yaw_for_horizontal") private var useYawForHorizontal: Bool = false
    @AppStorage("motion_invert_roll") private var invertRoll: Bool = false
    @AppStorage("motion_invert_pitch") private var invertPitch: Bool = false
    @AppStorage("motion_enable_full_6dof") private var fullMotionEnabled: Bool = false
    @AppStorage("motion_wiimote_imu_enabled") private var wiimoteIMUEnabled: Bool = false
    @AppStorage("motion_nunchuck_imu_enabled") private var nunchuckIMUEnabled: Bool = false

    // Debug settings
    @AppStorage("motion_debug_shake_enabled") private var debugShakeEnabled: Bool = false
    @AppStorage("motion_debug_logging") private var debugLogging: Bool = false

    /// Container for live motion sensor data
    private struct MotionDebugData {
        var gyroX: Double = 0.0
        var gyroY: Double = 0.0
        var gyroZ: Double = 0.0
        var accelX: Double = 0.0
        var accelY: Double = 0.0
        var accelZ: Double = 0.0
        var attitude: (roll: Double, pitch: Double, yaw: Double) = (0, 0, 0)
        var shakeDetected: Bool = false
        var shakeIntensity: Double = 0.0
        var motionActive: Bool = false
        var updateRate: Double = 60.0
        var lastUpdateTime: Date = Date()
        var totalAccelMagnitude: Double = 0.0
        var filteredAccelMagnitude: Double = 0.0
    }

    var body: some View {
        List {
                        // MARK: - Motion Status Section
            Section(header: Text("Motion Status")) {
                HStack {
                    Text("Motion Enabled")
                    Spacer()
                    Toggle("", isOn: $isMotionEnabled)
                        .onChange(of: isMotionEnabled) { enabled in
                            TCDeviceMotion.shared.setMotionEnabled(enabled)
                            if enabled {
                                startMotionMonitoring()
                            }
                        }
                }

                HStack {
                    Text("Core Motion Available")
                    Spacer()
                    Image(systemName: (motionManager?.isDeviceMotionAvailable ?? false) ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor((motionManager?.isDeviceMotionAvailable ?? false) ? .green : .red)
                }

                HStack {
                    Text("TCDeviceMotion Active")
                    Spacer()
                    Image(systemName: motionData.motionActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(motionData.motionActive ? .green : .red)
                }

                HStack {
                    Text("Update Rate")
                    Spacer()
                    Text(String(format: "%.1f Hz", motionData.updateRate))
                        .foregroundStyle(.secondary)
                }

                if motionManager?.isDeviceMotionAvailable == false {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Device Motion not available")
                            .foregroundColor(.orange)
                    }
                }
            }

            // MARK: - IR Mode Configuration
            Section(header: Text("IR Pointer Configuration")) {
                HStack {
                    Text("Current IR Mode")
                    Spacer()
                    Text(irModeLabel(currentIRMode))
                        .foregroundStyle(.secondary)
                }

                Button("Cycle IR Mode") {
                    currentIRMode = (currentIRMode + 1) % 3
                    DOLConfigBridge.setMainTouchPadIRMode(currentIRMode)
                    TCDeviceMotion.shared.setMotionEnabled(currentIRMode == 0 && isMotionEnabled)
                }

                HStack {
                    Text("Touch Controls Visible")
                    Spacer()
                    Image(systemName: touchControlsVisible ? "eye.fill" : "eye.slash.fill")
                        .foregroundColor(touchControlsVisible ? .blue : .gray)
                }
            }

            // MARK: - Interactive Swimming Dolphin
            Section(header: Text("🐬 Swimming Dolphin Visualizer")) {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.1), Color.cyan.opacity(0.2)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(height: 100)

                        Image("DolphinLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees(motionData.attitude.roll * 180 / .pi))
                            .offset(
                                x: motionData.attitude.yaw * 80,
                                y: -motionData.attitude.pitch * 40
                            )
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: motionData.attitude.roll)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: motionData.attitude.yaw)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: motionData.attitude.pitch)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("Tilt your device to see the dolphin swim around! 🌊")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 4)
            }

            // MARK: - Live Gyroscope Data
            Section(header: Text("Gyroscope (rad/s)")) {
                MotionValueRow(label: "X (Roll)", value: motionData.gyroX, range: -5...5)
                MotionValueRow(label: "Y (Pitch)", value: motionData.gyroY, range: -5...5)
                MotionValueRow(label: "Z (Yaw)", value: motionData.gyroZ, range: -5...5)
            }

            // MARK: - Live Accelerometer Data
            Section(header: Text("Accelerometer (g)")) {
                MotionValueRow(label: "X", value: motionData.accelX, range: -4...4)
                MotionValueRow(label: "Y", value: motionData.accelY, range: -4...4)
                MotionValueRow(label: "Z", value: motionData.accelZ, range: -4...4)
            }

            // MARK: - Device Attitude
            Section(header: Text("Device Attitude (degrees)")) {
                MotionValueRow(
                    label: useYawForHorizontal ? "Roll" : "Roll (IR H)",
                    value: motionData.attitude.roll * 180 / .pi,
                    range: -180...180,
                    isActive: !useYawForHorizontal && gyroIREnabled
                )
                MotionValueRow(
                    label: "Pitch (IR V)",
                    value: motionData.attitude.pitch * 180 / .pi,
                    range: -90...90,
                    isActive: gyroIREnabled
                )
                MotionValueRow(
                    label: useYawForHorizontal ? "Yaw (IR H)" : "Yaw",
                    value: motionData.attitude.yaw * 180 / .pi,
                    range: -180...180,
                    isActive: useYawForHorizontal && gyroIREnabled
                )
            }

            // MARK: - 3D Visualization
            Section(header: HStack {
                Text("3D Device Orientation")
                Spacer()
                Toggle("", isOn: $show3DView)
                    .labelsHidden()
            }) {
                if show3DView {
                    Device3DView(
                        roll: motionData.attitude.roll,
                        pitch: motionData.attitude.pitch,
                        yaw: motionData.attitude.yaw,
                        accelX: motionData.accelX,
                        accelY: motionData.accelY,
                        accelZ: motionData.accelZ,
                        shakeIntensity: motionData.shakeIntensity
                    )
                    .frame(height: 200)
                }
            }

                        // MARK: - Shake Detection
            Section(header: Text("Shake Detection")) {
                HStack {
                    Text("Shake Detected")
                    Spacer()
                    Circle()
                        .fill(motionData.shakeDetected ? Color.red : Color.clear)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(Color.red, lineWidth: 2)
                        )
                        .scaleEffect(motionData.shakeDetected ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: motionData.shakeDetected)
                }

                HStack {
                    Text("Shake Intensity")
                    Spacer()
                    Text(String(format: "%.2f", motionData.shakeIntensity))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(motionData.shakeIntensity > 2.0 ? .red : .primary)
                }

                HStack {
                    Text("Total Acceleration")
                    Spacer()
                    Text(String(format: "%.2f g", motionData.totalAccelMagnitude))
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Filtered Acceleration")
                    Spacer()
                    Text(String(format: "%.2f g", motionData.filteredAccelMagnitude))
                        .font(.system(.body, design: .monospaced))
                }

                Toggle("Enable Shake Detection", isOn: $debugShakeEnabled)
                    .onChange(of: debugShakeEnabled) { enabled in
                        NSLog("[MOTION_DEBUG] Shake detection enabled: %@", enabled ? "YES" : "NO")
                    }
            }

                        // MARK: - Motion Control Settings
            Section(header: Text("Enhanced Motion Controls")) {
                Toggle("Enable Enhanced Shake Detection", isOn: $enhancedShakeEnabled)

                Toggle("Enable Gyro IR Cursor", isOn: $gyroIREnabled)

                Toggle("Use Yaw for Horizontal Movement", isOn: $useYawForHorizontal)

                Toggle("Invert Roll/Yaw (Left/Right)", isOn: $invertRoll)

                Toggle("Invert Pitch (Up/Down)", isOn: $invertPitch)
            }

            // MARK: - Full 6DOF Motion Settings
            Section(header: Text("Full 6DOF Motion Controls")) {
                Toggle("Enable Full 6DOF Motion", isOn: $fullMotionEnabled)

                if fullMotionEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maps all 6 degrees of freedom to Wiimote/Nunchuck")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Enable Wiimote IMU", isOn: $wiimoteIMUEnabled)

                        Toggle("Enable Nunchuck IMU", isOn: $nunchuckIMUEnabled)

                        Text("Note: Only applies when gyro IR cursor is disabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.leading)
                }
            }

            // MARK: - Debug Controls
            Section(header: Text("Debug Controls")) {
                Toggle("Debug Logging", isOn: $debugLogging)
                    .onChange(of: debugLogging) { enabled in
                        NSLog("[MOTION_DEBUG] Debug logging enabled: %@", enabled ? "YES" : "NO")
                    }

                Button("Test Wii Remote Shake") {
                    // Simulate a shake event for testing
                    testShakeEvent()
                }

                Button("Reset Motion System") {
                    resetMotionSystem()
                }

                Button("Reset IR Cursor to Center") {
                    resetIRCursor()
                }

                Button("Log Current State") {
                    logCurrentMotionState()
                }

                Button("Apply Recommended Settings") {
                    applyRecommendedSettings()
                }
            }

            // MARK: - Connection Status
            Section(header: Text("Controller Status")) {
                ForEach(GCController.controllers().indices, id: \.self) { index in
                    let controller = GCController.controllers()[index]
                    HStack {
                        Text("Controller \(index + 1)")
                        Spacer()
                        Text(controller.vendorName ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                if GCController.controllers().isEmpty {
                                  CompactDolphinError(message: "No external controllers connected")
                  .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Motion Debug")
        .onAppear {
            setupDebugView()
            startMotionMonitoring()
        }
        .onDisappear {
            stopMotionMonitoring()
        }
        // CRITICAL: Restart motion system when settings change
        .onChange(of: enhancedShakeEnabled) { _ in restartMotionSystemIfRunning() }
        .onChange(of: gyroIREnabled) { _ in restartMotionSystemIfRunning() }
        .onChange(of: useYawForHorizontal) { _ in restartMotionSystemIfRunning() }
        .onChange(of: invertRoll) { _ in restartMotionSystemIfRunning() }
        .onChange(of: invertPitch) { _ in restartMotionSystemIfRunning() }
        .onChange(of: fullMotionEnabled) { _ in restartMotionSystemIfRunning() }
        .onChange(of: wiimoteIMUEnabled) { _ in restartMotionSystemIfRunning() }
        .onChange(of: nunchuckIMUEnabled) { _ in restartMotionSystemIfRunning() }
    }

    // MARK: - Helper Methods

    private func irModeLabel(_ mode: Int) -> String {
        switch mode {
        case 0: return "Gyro"
        case 1: return "Follow"
        case 2: return "Drag"
        default: return "Unknown"
        }
    }

        private func setupDebugView() {
        // Sync current state from system
        isMotionEnabled = TCDeviceMotion.shared.motionEnabled
        currentIRMode = DOLConfigBridge.mainTouchPadIRMode()
        debugLoggingEnabled = UserDefaults.standard.bool(forKey: "motion_debug_logging")
        shakeDetectionEnabled = UserDefaults.standard.bool(forKey: "motion_debug_shake_enabled")

        // Check if touch controls are currently visible
        touchControlsVisible = ControllerManager.shared.overlayVisible

        // Initialize our own motion manager for accurate readings
        if motionManager == nil {
            motionManager = CMMotionManager()
        }

        NSLog("[MOTION_DEBUG] Debug view setup complete - IR Mode: %d, Motion: %@, Core Motion Available: %@",
              currentIRMode, isMotionEnabled ? "ON" : "OFF",
              motionManager?.isDeviceMotionAvailable == true ? "YES" : "NO")
    }

    private func startMotionMonitoring() {
        // Initialize Core Motion manager
        motionManager = CMMotionManager()

        guard let motionManager = motionManager else { return }

        // Configure update intervals
        motionManager.deviceMotionUpdateInterval = 1.0/60.0 // 60Hz
        motionManager.gyroUpdateInterval = 1.0/60.0
        motionManager.accelerometerUpdateInterval = 1.0/60.0

        // Start device motion updates if available
        if motionManager.isDeviceMotionAvailable {
            motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
            NSLog("[MOTION_DEBUG] Started Core Motion device motion updates")
        }

        // Start gyroscope updates if available
        if motionManager.isGyroAvailable {
            motionManager.startGyroUpdates()
            NSLog("[MOTION_DEBUG] Started gyroscope updates")
        }

        // Start accelerometer updates if available
        if motionManager.isAccelerometerAvailable {
            motionManager.startAccelerometerUpdates()
            NSLog("[MOTION_DEBUG] Started accelerometer updates")
        }

        // Timer to update UI
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
            updateMotionData()
        }
    }

    private func stopMotionMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Stop Core Motion updates
        motionManager?.stopDeviceMotionUpdates()
        motionManager?.stopGyroUpdates()
        motionManager?.stopAccelerometerUpdates()
        motionManager = nil

        NSLog("[MOTION_DEBUG] Stopped Core Motion updates")
    }

    private func updateMotionData() {
        // Get motion data from TCDeviceMotion if available
        let motionManager = TCDeviceMotion.shared

        // Update basic status
        let now = Date()
        let deltaTime = now.timeIntervalSince(motionData.lastUpdateTime)
        motionData.updateRate = deltaTime > 0 ? 1.0 / deltaTime : 0
        motionData.lastUpdateTime = now
        motionData.motionActive = motionManager.motionEnabled

        // Get real sensor data from Core Motion
        updateRealMotionData()

                // Calculate acceleration magnitudes
        motionData.totalAccelMagnitude = sqrt(motionData.accelX * motionData.accelX +
                                            motionData.accelY * motionData.accelY +
                                            motionData.accelZ * motionData.accelZ)

        // Improved shake detection algorithm
        updateShakeDetection()

        // Log debug info if enabled
        if debugLoggingEnabled && Int(now.timeIntervalSince1970) % 2 == 0 {
            NSLog("[MOTION_DEBUG] Gyro: (%.3f, %.3f, %.3f) Accel: (%.3f, %.3f, %.3f)",
                  motionData.gyroX, motionData.gyroY, motionData.gyroZ,
                  motionData.accelX, motionData.accelY, motionData.accelZ)
        }
    }

    /// Gets real motion data from Core Motion sensors
    private func updateRealMotionData() {
        guard let motionManager = motionManager else { return }

        // Get device motion data (includes attitude and user acceleration)
        if let deviceMotion = motionManager.deviceMotion {
            // Attitude (device orientation in space)
            let attitude = deviceMotion.attitude
            motionData.attitude.roll = attitude.roll
            motionData.attitude.pitch = attitude.pitch
            motionData.attitude.yaw = attitude.yaw

            // User acceleration (device acceleration minus gravity)
            let userAccel = deviceMotion.userAcceleration
            motionData.accelX = userAccel.x
            motionData.accelY = userAccel.y
            motionData.accelZ = userAccel.z
        }

        // Get raw gyroscope data
        if let gyroData = motionManager.gyroData {
            let rotationRate = gyroData.rotationRate
            motionData.gyroX = rotationRate.x
            motionData.gyroY = rotationRate.y
            motionData.gyroZ = rotationRate.z
        }

        // Fallback: if device motion isn't available, use raw accelerometer
        if motionManager.deviceMotion == nil, let accelData = motionManager.accelerometerData {
            let acceleration = accelData.acceleration
            motionData.accelX = acceleration.x
            motionData.accelY = acceleration.y
            motionData.accelZ = acceleration.z
        }

        // Log raw values occasionally for debugging
        if debugLoggingEnabled && Int(Date().timeIntervalSince1970) % 3 == 0 {
            NSLog("[MOTION_DEBUG] Raw - Gyro: (%.3f, %.3f, %.3f) UserAccel: (%.3f, %.3f, %.3f) Attitude: R=%.1f° P=%.1f° Y=%.1f°",
                  motionData.gyroX, motionData.gyroY, motionData.gyroZ,
                  motionData.accelX, motionData.accelY, motionData.accelZ,
                  motionData.attitude.roll * 180 / .pi,
                  motionData.attitude.pitch * 180 / .pi,
                  motionData.attitude.yaw * 180 / .pi)
        }
    }

    private func testShakeEvent() {
        NSLog("[MOTION_DEBUG] Simulating shake event for testing")
        // Simulate high shake intensity for visual feedback
        motionData.shakeDetected = true
        motionData.shakeIntensity = 5.0

        // Trigger Wiimote shake if enabled
        if debugShakeEnabled {
            triggerWiimoteShake()
        }

        // Reset after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            motionData.shakeDetected = false
            motionData.shakeIntensity = 0.0
        }
    }

    private func resetMotionSystem() {
        NSLog("[MOTION_DEBUG] Resetting motion system")
        TCDeviceMotion.shared.setMotionEnabled(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            TCDeviceMotion.shared.setMotionEnabled(isMotionEnabled)
            TCDeviceMotion.shared.statusBarOrientationChanged()
        }
    }

    private func resetIRCursor() {
        NSLog("[MOTION_DEBUG] Resetting IR cursor to center")
        if TVEmulationBridge.isRunning() {
            // Send notification to reset cursor - the core will handle it
            NotificationCenter.default.post(
                name: Notification.Name("DOLResetIRCursor"),
                object: nil
            )
        }
    }

        private func logCurrentMotionState() {
        NSLog("[MOTION_DEBUG] === Current Motion State ===")
        NSLog("[MOTION_DEBUG] Motion Enabled: %@", isMotionEnabled ? "YES" : "NO")
        NSLog("[MOTION_DEBUG] IR Mode: %d (%@)", currentIRMode, irModeLabel(currentIRMode))
        NSLog("[MOTION_DEBUG] Touch Controls: %@", touchControlsVisible ? "VISIBLE" : "HIDDEN")
        NSLog("[MOTION_DEBUG] Controllers Connected: %d", GCController.controllers().count)
        NSLog("[MOTION_DEBUG] Current Gyro: (%.3f, %.3f, %.3f)",
              motionData.gyroX, motionData.gyroY, motionData.gyroZ)
        NSLog("[MOTION_DEBUG] Current Accel: (%.3f, %.3f, %.3f)",
              motionData.accelX, motionData.accelY, motionData.accelZ)
        NSLog("[MOTION_DEBUG] Attitude: Roll=%.1f° Pitch=%.1f° Yaw=%.1f°",
              motionData.attitude.roll * 180 / .pi,
              motionData.attitude.pitch * 180 / .pi,
              motionData.attitude.yaw * 180 / .pi)
        NSLog("[MOTION_DEBUG] Shake Intensity: %.3f", motionData.shakeIntensity)
        NSLog("[MOTION_DEBUG] ========================")
    }

        /// Improved shake detection using real user acceleration variance over time
    private func updateShakeDetection() {
        // Calculate user acceleration magnitude (gravity already removed by Core Motion)
        let userAccelMagnitude = sqrt(motionData.accelX * motionData.accelX +
                                    motionData.accelY * motionData.accelY +
                                    motionData.accelZ * motionData.accelZ)

        // Store total acceleration for display (including gravity estimate)
        motionData.totalAccelMagnitude = userAccelMagnitude + 1.0 // Add gravity estimate for display

        // Add to history for variance calculation
        shakeHistory.append(userAccelMagnitude)
        if shakeHistory.count > 15 { // Keep last 15 samples (about 1/2 second at 30fps)
            shakeHistory.removeFirst()
        }

        // Calculate variance in acceleration
        if shakeHistory.count >= 8 {
            let mean = shakeHistory.reduce(0, +) / Double(shakeHistory.count)
            let variance = shakeHistory.reduce(0) { acc, val in
                acc + pow(val - mean, 2)
            } / Double(shakeHistory.count)

            let standardDeviation = sqrt(variance)
            motionData.shakeIntensity = standardDeviation * 20 // Scale for better visualization

            // Detect shake when standard deviation is high AND peak acceleration is above threshold
            let varianceThreshold = 0.15 // Tuned for user acceleration (no gravity)
            let accelerationThreshold = 0.8 // Lower threshold since gravity is removed

            let hasHighVariance = standardDeviation > varianceThreshold
            let hasHighAcceleration = userAccelMagnitude > accelerationThreshold

            motionData.shakeDetected = hasHighVariance && hasHighAcceleration

            if motionData.shakeDetected && debugShakeEnabled {
                // Trigger Wiimote shake in Dolphin (same as core implementation)
                let currentTime = Date().timeIntervalSinceReferenceDate
                let shakeCooldown: TimeInterval = 0.5

                if (currentTime - lastShakeTime) > shakeCooldown {
                    triggerWiimoteShake()
                    lastShakeTime = currentTime
                }
            }

            // Debug logging for shake detection tuning
            if debugLoggingEnabled && (motionData.shakeDetected || userAccelMagnitude > 0.5) {
                NSLog("[MOTION_DEBUG] Shake - UserAccel: %.3f StdDev: %.3f Detected: %@",
                      userAccelMagnitude, standardDeviation, motionData.shakeDetected ? "YES" : "NO")
            }
        }

        // Low-pass filter for smoother acceleration display
        let filterAlpha = 0.2
        motionData.filteredAccelMagnitude = filterAlpha * userAccelMagnitude +
                                           (1 - filterAlpha) * motionData.filteredAccelMagnitude
    }

    /// Triggers a shake event in the Dolphin Wiimote emulation
    private func triggerWiimoteShake() {
        NSLog("[MOTION_DEBUG] Triggering Wiimote shake event")

        // Send shake events to TCManagerInterface (same as the core uses)
        let port = 4 // Wiimote port
        let shakeDuration: Float = 0.1

        // Trigger shake on all axes for maximum game compatibility
        TCManagerInterface.setButtonStateFor(132, controller: port, state: true)
        TCManagerInterface.setButtonStateFor(132, controller: port, state: true) // wiiShakeX
        TCManagerInterface.setButtonStateFor(133, controller: port, state: true) // wiiShakeY
        TCManagerInterface.setButtonStateFor(134, controller: port, state: true) // wiiShakeZ

        // Release after short duration
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(shakeDuration)) {
            TCManagerInterface.setButtonStateFor(132, controller: port, state: false) // wiiShakeX
            TCManagerInterface.setButtonStateFor(133, controller: port, state: false) // wiiShakeY
            TCManagerInterface.setButtonStateFor(134, controller: port, state: false) // wiiShakeZ
        }
    }

        /// Restart the motion system when settings change during gameplay
    private func restartMotionSystemIfRunning() {
        NSLog("[MOTION_DEBUG] Settings changed - restarting motion system")

        // Restart our debug motion monitoring
        stopMotionMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startMotionMonitoring()
        }

        // Restart the core's motion system if it's running
        if TVEmulationBridge.isRunning() {
            // Signal the core to restart motion updates with new settings
            // This will also reset the IR cursor to center
            NotificationCenter.default.post(
                name: Notification.Name("DOLMotionSettingsChanged"),
                object: nil
            )
        }
    }

    private func applyRecommendedSettings() {
        // Set improved defaults based on user feedback
        enhancedShakeEnabled = true
        gyroIREnabled = true
        fullMotionEnabled = true
        useYawForHorizontal = false // Use roll by default
        wiimoteIMUEnabled = true
        nunchuckIMUEnabled = false
        invertRoll = false
        invertPitch = false
        NSLog("[MOTION_DEBUG] Applied recommended enhanced motion controls settings")
    }
}

/// 3D visualization of device orientation and motion
struct Device3DView: View {
    let roll: Double
    let pitch: Double
    let yaw: Double
    let accelX: Double
    let accelY: Double
    let accelZ: Double
    let shakeIntensity: Double

    // Camera control state
    @State private var cameraRotationX: Double = 0.2 // Initial slight tilt
    @State private var cameraRotationY: Double = 0.0
    @State private var cameraZoom: Double = 1.0
    @State private var lastDragValue: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let phoneWidth: CGFloat = 60
            let phoneHeight: CGFloat = 120
            let phoneDepth: CGFloat = 8

            // Draw background grid
            drawBackground(context: context, size: size)

                        // Calculate 3D phone corners with rotation and camera transform
            // Fix coordinate system - swap roll and pitch for correct visualization
            let corners = calculatePhoneCorners(
                width: phoneWidth,
                height: phoneHeight,
                depth: phoneDepth,
                roll: pitch,  // Use pitch for roll axis
                pitch: roll,  // Use roll for pitch axis
                yaw: yaw,
                cameraRotationX: cameraRotationX,
                cameraRotationY: cameraRotationY,
                cameraZoom: cameraZoom
            )

            // Draw 3D phone
            drawPhone(context: context, center: center, corners: corners, shakeIntensity: shakeIntensity)

                        // Draw acceleration vectors (with camera transform)
            // Fix coordinate system - swap X and Y acceleration to match visual orientation
            drawAccelerationVectors(
                context: context,
                center: center,
                accelX: accelY,  // Use accelY for X-axis vector
                accelY: accelX,  // Use accelX for Y-axis vector
                accelZ: accelZ,
                cameraRotationX: cameraRotationX,
                cameraRotationY: cameraRotationY,
                cameraZoom: cameraZoom
            )

            // Draw orientation labels (with corrected coordinate system)
            drawOrientationInfo(context: context, size: size, roll: pitch, pitch: roll, yaw: yaw)
        }
        .background(Color.black.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .gesture(
            SimultaneousGesture(
                // Pinch to zoom
                MagnificationGesture()
                    .onChanged { value in
                        withAnimation(.interactiveSpring(response: 0.1)) {
                            cameraZoom = max(0.5, min(3.0, value))
                        }
                    },
                                // Drag to rotate camera
                DragGesture()
                    .onChanged { value in
                        let sensitivity: Double = 0.01
                        let deltaX = value.translation.width - lastDragValue.width
                        let deltaY = value.translation.height - lastDragValue.height

                        cameraRotationY += Double(deltaX) * sensitivity
                        cameraRotationX += Double(deltaY) * sensitivity

                        // Clamp camera rotation
                        cameraRotationX = max(-1.5, min(1.5, cameraRotationX))

                        lastDragValue = value.translation
                    }
                    .onEnded { _ in
                        lastDragValue = .zero
                    }
            )
        )
        .overlay(alignment: .topTrailing) {
            // Camera controls info
            VStack(alignment: .trailing, spacing: 2) {
                Text("Pinch: Zoom")
                Text("Drag: Rotate")
                Text("Zoom: \(String(format: "%.1fx", cameraZoom))")

                Divider()
                    .background(.white.opacity(0.3))
                    .frame(height: 1)

                Button("Reset Camera") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        cameraRotationX = 0.2
                        cameraRotationY = 0.0
                        cameraZoom = 1.0
                    }
                }
                .font(.caption2)
                .foregroundColor(.blue.opacity(0.8))
                .padding(.vertical, 2)
            }
            .font(.caption2)
            .padding(8)
            .background(.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .foregroundColor(.white.opacity(0.7))
        }
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        let gridSpacing: CGFloat = 20

        context.stroke(
            Path { path in
                for x in stride(from: 0, through: size.width, by: gridSpacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: gridSpacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            },
            with: .color(.gray.opacity(0.2)),
            lineWidth: 0.5
        )
    }

        private func calculatePhoneCorners(width: CGFloat, height: CGFloat, depth: CGFloat,
                                     roll: Double, pitch: Double, yaw: Double,
                                     cameraRotationX: Double, cameraRotationY: Double, cameraZoom: Double) -> [CGPoint] {
        // Define 8 corners of the phone in 3D space
        let corners3D: [(x: Double, y: Double, z: Double)] = [
            (-Double(width/2), -Double(height/2), -Double(depth/2)), // front bottom left
            (Double(width/2), -Double(height/2), -Double(depth/2)),  // front bottom right
            (Double(width/2), Double(height/2), -Double(depth/2)),   // front top right
            (-Double(width/2), Double(height/2), -Double(depth/2)),  // front top left
            (-Double(width/2), -Double(height/2), Double(depth/2)),  // back bottom left
            (Double(width/2), -Double(height/2), Double(depth/2)),   // back bottom right
            (Double(width/2), Double(height/2), Double(depth/2)),    // back top right
            (-Double(width/2), Double(height/2), Double(depth/2))    // back top left
        ]

        // Apply transformations: device rotation first, then camera rotation
        return corners3D.map { corner in
            // 1. Apply device rotation (phone's actual orientation)
            let (x1, y1, z1) = rotatePoint3D(corner, roll: roll, pitch: pitch, yaw: yaw)

            // 2. Apply camera rotation (user's viewing angle)
            let (x2, y2, z2) = applyCameraRotation(x: x1, y: y1, z: z1,
                                                  cameraRotationX: cameraRotationX,
                                                  cameraRotationY: cameraRotationY)

            // 3. Project to 2D with zoom
            return projectTo2D(x: x2, y: y2, z: z2, zoom: cameraZoom)
        }
    }

    private func rotatePoint3D(_ point: (x: Double, y: Double, z: Double),
                               roll: Double, pitch: Double, yaw: Double) -> (x: Double, y: Double, z: Double) {
        let (x, y, z) = point

        // Roll (rotation around X-axis)
        let y1 = y * cos(roll) - z * sin(roll)
        let z1 = y * sin(roll) + z * cos(roll)

        // Pitch (rotation around Y-axis)
        let x2 = x * cos(pitch) + z1 * sin(pitch)
        let z2 = -x * sin(pitch) + z1 * cos(pitch)

        // Yaw (rotation around Z-axis)
        let x3 = x2 * cos(yaw) - y1 * sin(yaw)
        let y3 = x2 * sin(yaw) + y1 * cos(yaw)

        return (x3, y3, z2)
    }

    private func applyCameraRotation(x: Double, y: Double, z: Double,
                                   cameraRotationX: Double, cameraRotationY: Double) -> (x: Double, y: Double, z: Double) {
        // Apply camera rotation around Y-axis first (horizontal pan)
        let x1 = x * cos(cameraRotationY) + z * sin(cameraRotationY)
        let z1 = -x * sin(cameraRotationY) + z * cos(cameraRotationY)

        // Then apply camera rotation around X-axis (vertical tilt)
        let y2 = y * cos(cameraRotationX) - z1 * sin(cameraRotationX)
        let z2 = y * sin(cameraRotationX) + z1 * cos(cameraRotationX)

        return (x1, y2, z2)
    }

    private func projectTo2D(x: Double, y: Double, z: Double, zoom: Double) -> CGPoint {
        // Perspective projection with zoom
        let perspective: Double = 200
        let scale = (perspective / (perspective + z + 100)) * zoom
        return CGPoint(x: x * scale, y: y * scale)
    }

    private func drawPhone(context: GraphicsContext, center: CGPoint, corners: [CGPoint], shakeIntensity: Double) {
        let offsetCorners = corners.map { corner in
            CGPoint(x: center.x + corner.x, y: center.y + corner.y)
        }

        // Phone color based on shake intensity
        let phoneColor = shakeIntensity > 1.0 ? Color.red.opacity(0.8) : Color.blue.opacity(0.8)
        let edgeColor = Color.white.opacity(0.9)

        // Draw phone faces (simplified to front and visible edges)
        context.fill(
            Path { path in
                // Front face
                path.move(to: offsetCorners[0])
                path.addLine(to: offsetCorners[1])
                path.addLine(to: offsetCorners[2])
                path.addLine(to: offsetCorners[3])
                path.closeSubpath()
            },
            with: .color(phoneColor)
        )

        // Draw edges for 3D effect
        context.stroke(
            Path { path in
                // Front face outline
                path.move(to: offsetCorners[0])
                path.addLine(to: offsetCorners[1])
                path.addLine(to: offsetCorners[2])
                path.addLine(to: offsetCorners[3])
                path.closeSubpath()

                // Depth lines to back face
                for i in 0..<4 {
                    path.move(to: offsetCorners[i])
                    path.addLine(to: offsetCorners[i + 4])
                }
            },
            with: .color(edgeColor),
            lineWidth: 2.0
        )

        // Draw phone screen (smaller rectangle on front face)
        let screenInset: CGFloat = 8
        context.fill(
            Path { path in
                let screenCorners = [
                    CGPoint(x: offsetCorners[0].x + screenInset, y: offsetCorners[0].y + screenInset),
                    CGPoint(x: offsetCorners[1].x - screenInset, y: offsetCorners[1].y + screenInset),
                    CGPoint(x: offsetCorners[2].x - screenInset, y: offsetCorners[2].y - screenInset),
                    CGPoint(x: offsetCorners[3].x + screenInset, y: offsetCorners[3].y - screenInset)
                ]

                path.move(to: screenCorners[0])
                path.addLine(to: screenCorners[1])
                path.addLine(to: screenCorners[2])
                path.addLine(to: screenCorners[3])
                path.closeSubpath()
            },
            with: .color(.black.opacity(0.8))
        )
    }

        private func drawAccelerationVectors(context: GraphicsContext, center: CGPoint,
                                       accelX: Double, accelY: Double, accelZ: Double,
                                       cameraRotationX: Double, cameraRotationY: Double, cameraZoom: Double) {
        let vectorScale: Double = 30.0

        // Define acceleration vectors in 3D space
        let vectors: [(accel: Double, direction: (x: Double, y: Double, z: Double), color: Color, label: String)] = [
            (accelX, (1.0, 0.0, 0.0), .red, "X"),    // X-axis
            (accelY, (0.0, 1.0, 0.0), .green, "Y"),  // Y-axis
            (accelZ, (0.0, 0.0, 1.0), .blue, "Z")    // Z-axis
        ]

        for vector in vectors {
            if abs(vector.accel) > 0.1 {
                // Calculate 3D endpoint
                let endX = vector.direction.x * vector.accel * vectorScale
                let endY = vector.direction.y * vector.accel * vectorScale
                let endZ = vector.direction.z * vector.accel * vectorScale

                // Apply camera rotation to the vector endpoint
                let (transformedX, transformedY, transformedZ) = applyCameraRotation(
                    x: endX, y: endY, z: endZ,
                    cameraRotationX: cameraRotationX,
                    cameraRotationY: cameraRotationY
                )

                // Project to 2D
                let endPoint2D = projectTo2D(x: transformedX, y: transformedY, z: transformedZ, zoom: cameraZoom)
                let screenEndPoint = CGPoint(x: center.x + endPoint2D.x, y: center.y + endPoint2D.y)

                drawVector(context: context, from: center, to: screenEndPoint, color: vector.color, label: vector.label)
            }
        }
    }

    private func drawVector(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color, label: String) {
        // Draw vector line
        context.stroke(
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            },
            with: .color(color),
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )

        // Draw arrowhead
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLength: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 6

        let arrowPoint1 = CGPoint(
            x: to.x - arrowLength * cos(angle - arrowAngle),
            y: to.y - arrowLength * sin(angle - arrowAngle)
        )
        let arrowPoint2 = CGPoint(
            x: to.x - arrowLength * cos(angle + arrowAngle),
            y: to.y - arrowLength * sin(angle + arrowAngle)
        )

        context.fill(
            Path { path in
                path.move(to: to)
                path.addLine(to: arrowPoint1)
                path.addLine(to: arrowPoint2)
                path.closeSubpath()
            },
            with: .color(color)
        )

        // Draw label
        let labelOffset: CGFloat = 15
        let labelPoint = CGPoint(
            x: to.x + labelOffset * cos(angle),
            y: to.y + labelOffset * sin(angle)
        )

        context.draw(
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(color),
            at: labelPoint
        )
    }

    private func drawOrientationInfo(context: GraphicsContext, size: CGSize,
                                   roll: Double, pitch: Double, yaw: Double) {
        let infoText = Text("R: \(Int(roll * 180 / .pi))° P: \(Int(pitch * 180 / .pi))° Y: \(Int(yaw * 180 / .pi))°")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)

        context.draw(infoText, at: CGPoint(x: 10, y: size.height - 10), anchor: .bottomLeading)
    }
}

/// Helper view for displaying motion values with visual indicators
private struct MotionValueRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundColor(isActive ? .blue : .primary)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer()
                HStack(spacing: 4) {
                    if isActive {
                        Image(systemName: "gyroscope")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                    Text(String(format: "%.3f", value))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(isActive ? .blue : colorForValue(value))
                        .fontWeight(isActive ? .medium : .regular)
                }
            }

            // Visual bar indicator
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)

                    Rectangle()
                        .fill(isActive ? .blue : colorForValue(value))
                        .frame(width: max(0, CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width),
                               height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, isActive ? 2 : 0)
        .background(isActive ? .blue.opacity(0.1) : .clear)
        .cornerRadius(isActive ? 6 : 0)
    }

    private func colorForValue(_ value: Double) -> Color {
        let normalized = abs(value) / max(abs(range.lowerBound), abs(range.upperBound))
        if normalized < 0.3 {
            return .green
        } else if normalized < 0.7 {
            return .orange
        } else {
            return .red
        }
    }
}

#if DEBUG
struct MotionDebugView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            MotionDebugView()
        }
    }
}
#endif
