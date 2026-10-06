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
  /// m/s^2 the core's IMUAccelerometer expects (see `wiimoteFrame`).
  static let gravityToMetersPerSecondSquared: Double = 9.80665

  // MARK: IMU mount

  /// The fixed turn (device frame) that makes the grip held at the last baseline read as a level
  /// Wii Remote: set together with `pointerBaseline`, so Recenter and a rotation re-take both.
  /// Only touched on the serial motion queue.
  private var imuMount: simd_quatd?
  /// Latest `CMDeviceMotion.gravity` (device frame, g), subtracted from the 200 Hz accelerometer in
  /// the touch pointer modes to keep only the player's own swings. Motion queue only.
  private var latestGravity: SIMD3<Double>?

  #if DEBUG
  /// While set, real CoreMotion samples are dropped so an injected pose (debug API) sticks.
  /// Motion queue only.
  private var debugPoseHeld = false
  #endif

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

    // Until the first sample arrives (and forever on a simulator, which has no motion hardware)
    // the remote rests level instead of keeping whatever the axes held before.
    operationQueue.addOperation {
      self.latestGravity = nil
      self.writeRestingIMU()
    }

    // Set the sensor update times
    // 200Hz is the Wiimote update interval
    let updateInterval: Double = 1.0 / 200.0
    motionManager.accelerometerUpdateInterval = updateInterval
    motionManager.gyroUpdateInterval = updateInterval
    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // Device motion for enhanced features

    // Register the handlers. These two are the ONLY writers of the IMU axes: the device-motion
    // handler below only records gravity and the baseline. Two writers at different rates (the
    // 6DOF path used to write from device motion too) interleave and make the remote jitter.
    motionManager.startAccelerometerUpdates(to: operationQueue) { data, error in
      guard let data, error == nil, !self.isDebugPoseHeld else { return }
      let acceleration = data.acceleration
      self.handleAccelerometer(SIMD3(acceleration.x, acceleration.y, acceleration.z))
    }

    motionManager.startGyroUpdates(to: operationQueue) { data, error in
      guard let data, error == nil, !self.isDebugPoseHeld else { return }
      let rate = data.rotationRate
      self.handleGyro(SIMD3(rate.x, rate.y, rate.z))
    }

    // Enhanced device motion updates for shake detection, the gyro IR cursor and the IMU baseline
    if motionManager.isDeviceMotionAvailable {
      motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: operationQueue) { motion, error in
        guard let motion, error == nil, !self.isDebugPoseHeld else { return }
        self.handleEnhancedMotionFeatures(DeviceMotionSample(motion))
      }
    }
  }

  private var isDebugPoseHeld: Bool {
    #if DEBUG
    return debugPoseHeld
    #else
    return false
    #endif
  }

  /// The accelerometer writes for one raw sample (CoreMotion's units and sign: g, reading the
  /// gravity vector at rest). Returns what was written, in the remote's frame (m/s^2).
  @discardableResult
  private func handleAccelerometer(_ acceleration: SIMD3<Double>) -> (wiimote: SIMD3<Double>, nunchuk: SIMD3<Double>) {
    let uiOrientation = orientation
    let policy = Self.currentIMUPolicy()
    let mount = imuMount(for: uiOrientation)
    let wiimote = Self.imuAcceleration(
      source: policy.wiimote, acceleration: acceleration, gravity: latestGravity, mount: mount, orientation: uiOrientation)
    let nunchuk = Self.imuAcceleration(
      source: policy.nunchuk, acceleration: acceleration, gravity: latestGravity, mount: mount, orientation: uiOrientation)
    writeAcceleration(wiimote: wiimote, nunchuk: nunchuk)
    return (wiimote, nunchuk)
  }

  /// The gyroscope writes for one raw sample (rad/s, device frame). Returns the remote's
  /// (pitch, roll, yaw) rates as written.
  @discardableResult
  private func handleGyro(_ rate: SIMD3<Double>) -> SIMD3<Double> {
    let uiOrientation = orientation
    // Rotation rates are the same whether or not gravity is fed through, but in the phone-tracking
    // modes they must turn with the same mount as the accelerometer or MotionPlus disagrees with it.
    let mount = Self.currentIMUPolicy().wiimote == .phone ? imuMount(for: uiOrientation) : nil
    let rates = Self.imuAngularVelocity(rate, mount: mount, orientation: uiOrientation)
    for (button, value) in Self.wiimoteGyroWrites(pitch: rates.x, roll: rates.y, yaw: rates.z) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
    return rates
  }

  private func writeAcceleration(wiimote: SIMD3<Double>, nunchuk: SIMD3<Double>) {
    for (button, value) in Self.wiimoteAccelWrites(x: wiimote.x, y: wiimote.y, z: wiimote.z) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
    for (button, value) in Self.nunchukAccelWrites(x: nunchuk.x, y: nunchuk.y, z: nunchuk.z) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
  }

  /// A level, motionless remote and Nunchuk. The axes keep their last value, so this is written
  /// whenever motion starts or stops (or the bound slot changes), not left to the last tilt.
  private func writeRestingIMU() {
    writeAcceleration(wiimote: Self.levelAcceleration, nunchuk: Self.levelAcceleration)
    for (button, value) in Self.wiimoteGyroWrites(pitch: 0, roll: 0, yaw: 0) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
  }

  /// The mount for the current orientation, or nil until a baseline exists for it (the static
  /// mapping applies until the next device-motion sample re-takes it).
  private func imuMount(for orientation: UIInterfaceOrientation) -> simd_quatd? {
    pointerBaselineOrientation == orientation ? imuMount : nil
  }

  /// One device-motion sample, as plain values so the debug API can feed the same path.
  struct DeviceMotionSample {
    var attitude: simd_quatd
    /// Device frame, g, pointing at the ground (CoreMotion's convention).
    var gravity: SIMD3<Double>
    var userAcceleration: SIMD3<Double>
    var rotationRate: SIMD3<Double>
    var roll = 0.0, pitch = 0.0, yaw = 0.0
    var timestamp: TimeInterval = 0

    init(attitude: simd_quatd, gravity: SIMD3<Double>, userAcceleration: SIMD3<Double>, rotationRate: SIMD3<Double>) {
      self.attitude = attitude
      self.gravity = gravity
      self.userAcceleration = userAcceleration
      self.rotationRate = rotationRate
    }

    init(_ motion: CMDeviceMotion) {
      let q = motion.attitude.quaternion
      self.init(
        attitude: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
        gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
        userAcceleration: SIMD3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
        rotationRate: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z))
      roll = motion.attitude.roll
      pitch = motion.attitude.pitch
      yaw = motion.attitude.yaw
      timestamp = motion.timestamp
    }
  }

  /// Handle enhanced motion features: shake detection, the IMU baseline and the gyro IR cursor.
  /// Returns the gyro pointer written, if any.
  @discardableResult
  private func handleEnhancedMotionFeatures(_ motion: DeviceMotionSample) -> (horizontal: Double, vertical: Double)? {
    // Shake statistics are always kept (they feed the debug view); the Wii Remote shake is only
    // fired when enhanced shake detection is on.
    let shake = updateShakeStatistics(userAcceleration: motion.userAcceleration)
    if shake.detected, MotionSettings.enhancedShakeDetection() {
      let currentTime = Date().timeIntervalSinceReferenceDate
      if (currentTime - lastShakeTime) > Self.shakeCooldown {
        triggerWiimoteShake()
        lastShakeTime = currentTime
      }
    }
    publishSample(motion: motion, shake: shake)
    latestGravity = motion.gravity

    let irMode = Int(DOLConfigBridge.mainTouchPadIRMode())
    if irMode == 0, lastIRMode != 0 {
      recenterPointer()
    }
    lastIRMode = irMode

    // The baseline is the pointer's center AND the IMU mount, taken from the same sample. It is
    // only consumed when the phone's attitude drives something (gyro pointer, 6DOF Nunchuk), so a
    // recenter request made in a touch mode waits for a mode that uses it.
    let uiOrientation = orientation
    if Self.currentIMUPolicy(irMode: irMode).tracksPhone {
      rebaselineIfNeeded(motion: motion, orientation: uiOrientation)
    }
    guard irMode == 0 else { return nil }
    return handleIRCursorMapping(attitude: motion.attitude, orientation: uiOrientation)
  }

  /// Rotating the UI turns the screen's axes against the device's, so recenter on whatever the
  /// player is holding now rather than reading the old turn along the new axes.
  /// `pointerBaselineOrientation` is set together with `pointerBaseline`, so nil means no baseline.
  private func rebaselineIfNeeded(motion: DeviceMotionSample, orientation: UIInterfaceOrientation) {
    guard Self.needsPointerRebaseline(
      recenterRequested: takeRecenterRequest(), baselineOrientation: pointerBaselineOrientation,
      orientation: orientation) else { return }
    pointerBaseline = motion.attitude
    pointerBaselineOrientation = orientation
    imuMount = Self.imuMount(gravity: motion.gravity, orientation: orientation)
    if UserDefaults.standard.bool(forKey: "input_debug") {
      NSLog("[MOTION] gyro pointer / IMU baseline orientation=%d", orientation.rawValue)
    }
  }

  /// Variance-based shake detection over the recent user-acceleration magnitude (gravity already
  /// removed by CoreMotion). A shake needs both high variance and a high current magnitude.
  private func updateShakeStatistics(userAcceleration: SIMD3<Double>) -> (intensity: Double, detected: Bool) {
    let magnitude = simd_length(userAcceleration)

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

  private func publishSample(motion: DeviceMotionSample, shake: (intensity: Double, detected: Bool)) {
    var sample = Sample()
    sample.roll = motion.roll
    sample.pitch = motion.pitch
    sample.yaw = motion.yaw
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

  /// Map device attitude to IR cursor movement. Returns the clamped pointer written, or nil
  /// without a baseline.
  @discardableResult
  private func handleIRCursorMapping(
    attitude: simd_quatd, orientation: UIInterfaceOrientation
  ) -> (horizontal: Double, vertical: Double)? {
    guard let baseline = pointerBaseline else { return nil }
    let debug = UserDefaults.standard.bool(forKey: "input_debug")

    // Read per sample, like the invert keys below, so a change applies without a restart.
    var (horizontalValue, verticalValue) = Self.gyroPointerOffsets(
      current: attitude, baseline: baseline, orientation: orientation,
      useYawForHorizontal: MotionSettings.useYawForHorizontal(), gain: MotionSettings.gyroPointerSensitivity())

    if MotionSettings.invertRoll() { horizontalValue = -horizontalValue }
    if MotionSettings.invertPitch() { verticalValue = -verticalValue }

    gyroPointerSampleCount += 1
    if debug, gyroPointerSampleCount % Self.gyroPointerLogInterval == 0 {
      NSLog("[MOTION] gyro pointer h=%.3f v=%.3f (before clamp)", horizontalValue, verticalValue)
    }

    // Clamping to [-1, 1] happens inside irCursorWrites so it stays covered by the
    // pure unit tests below, alongside the sign/single-sided derivation.
    for (button, value) in Self.irCursorWrites(horizontal: horizontalValue, vertical: verticalValue) {
      TCManagerInterface.setAxisValueFor(button.rawValue, controller: port, value: value)
    }
    return (max(-1, min(1, horizontalValue)), max(-1, min(1, verticalValue)))
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
      // Otherwise the remote stays frozen at its last tilt.
      operationQueue.addOperation { self.writeRestingIMU() }
    }
  }

  @objc func setPort(_ port: Int) {
    guard port != self.port else { return }
    self.port = port
    // The new slot has never seen a sample: rest it until the next one.
    if motionEnabled {
      operationQueue.addOperation { self.writeRestingIMU() }
    }
  }

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
  //
  // THE WII REMOTE'S FRAME. The core's IMU groups read `x = Left - Right`,
  // `y = Backward - Forward`, `z = Up - Down` (IMUAccelerometer.cpp, IMUGyroscope.cpp), and
  // a level remote at rest reads (0, 0, +1 g) (WiimoteEmu.cpp `GetTotalAcceleration`'s
  // default). Upstream Android (DolphinSensorEventListener.kt + getNegativeAxes) feeds its
  // phone axes so that state = (-x, -y, +z) for both the accelerometer and the gyroscope,
  // with the phone lying face up and its top edge toward the TV: so +x is the remote's LEFT,
  // +y its BACK (toward the player), +z its TOP (button face), a right-handed frame, with
  // the accelerometer reading proper acceleration (+1 g up at rest) and the gyroscope
  // right-handed angular velocity about those same axes.
  //
  // THE NEUTRAL GRIP. The player holds the phone like a remote aimed at the TV with the
  // screen facing them: the remote's front is out of the phone's BACK, its top is the
  // screen's current up edge and its right the screen's right, in every interface orientation.
  //
  // COREMOTION'S SIGN. CMAccelerometerData / CMDeviceMotion acceleration reports the gravity
  // vector at rest (face up reads z = -1 g), the negative of proper acceleration; rotation
  // rates are right-handed like Android's. Measured on the core's 10-bit accelerometer
  // (512 = 0 g) through the old pass-through mapping: face down raw z = +1 read (512,513,616),
  // the level remote that kept SMG2's pointer; upright portrait raw y = -1 read (521,616,511),
  // a remote pointing at the floor, and SMG2 hid the pointer.

  /// Where the phone's motion comes from for one IMU.
  enum IMUSource: Equatable {
    /// A level remote at rest plus the player's own acceleration (gravity removed): the phone's
    /// tilt never reaches the game, but swings and shakes do.
    case level
    /// The phone's full acceleration (gravity included) through the baseline mount: the remote
    /// tilts with the phone.
    case phone
  }

  struct IMUPolicy: Equatable {
    var wiimote: IMUSource
    var nunchuk: IMUSource

    var tracksPhone: Bool { wiimote == .phone || nunchuk == .phone }
  }

  /// Which IMU follows the phone's tilt.
  ///
  /// - Touch pointer modes (follow 1, drag 2, the default): the pointer comes from the screen, so
  ///   the phone's orientation must never decide whether a game shows it. Games hide the pointer
  ///   when the remote reads as aimed at the floor or ceiling, which is how every normal grip read
  ///   before this policy existed. This holds even with Full 6DOF and Wii Remote motion on: both
  ///   are ON by default (`MotionSettings.defaults`), and that 6DOF path was how most players got
  ///   the bug, so in a touch mode they cannot tilt the remote.
  /// - Gyro pointer (0): the phone IS the remote, so the Wii Remote tracks it (baseline-relative).
  /// - The Nunchuk tracks the phone only with Full 6DOF and Nunchuk motion on (off by default); its
  ///   tilt never hides the pointer.
  static func imuPolicy(irMode: Int, full6DOF: Bool, nunchukIMU: Bool) -> IMUPolicy {
    IMUPolicy(
      wiimote: irMode == 0 ? .phone : .level,
      nunchuk: full6DOF && nunchukIMU ? .phone : .level)
  }

  static func currentIMUPolicy(irMode: Int = Int(DOLConfigBridge.mainTouchPadIRMode())) -> IMUPolicy {
    imuPolicy(irMode: irMode, full6DOF: MotionSettings.full6DOF(), nunchukIMU: MotionSettings.nunchukIMU())
  }

  /// What a level remote at rest reads, m/s^2.
  static let levelAcceleration = SIMD3<Double>(0, 0, gravityToMetersPerSecondSquared)

  /// A device-frame vector expressed in the remote's (left, back, top) frame for the neutral grip
  /// in `orientation`. Unknown folds into portrait.
  static func wiimoteFrame(_ vector: SIMD3<Double>, orientation: UIInterfaceOrientation) -> SIMD3<Double> {
    let axes = screenAxes(for: orientation)
    return SIMD3(-simd_dot(vector, axes.right), simd_dot(vector, axes.out), simd_dot(vector, axes.up))
  }

  /// CoreMotion acceleration (g, gravity-vector sign) as proper acceleration in m/s^2.
  static func properAcceleration(_ coreMotion: SIMD3<Double>) -> SIMD3<Double> {
    -coreMotion * gravityToMetersPerSecondSquared
  }

  /// The turn (device frame) that carries the "up" of the grip held at the baseline onto the
  /// screen's up edge, so that grip reads as a level remote and every later move tilts the remote
  /// by the same amount, as if it were rigidly strapped to the phone. The shortest such turn adds
  /// no yaw, and turning about the true vertical afterwards changes nothing.
  ///
  /// `gravity` is `CMDeviceMotion.gravity` at the baseline (device frame, toward the ground).
  static func imuMount(gravity: SIMD3<Double>, orientation: UIInterfaceOrientation) -> simd_quatd {
    let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    let length = simd_length(gravity)
    guard length > 1e-6 else { return identity }
    let up = -gravity / length
    let axes = screenAxes(for: orientation)
    // Upside down (the screen's up edge at the floor): any perpendicular axis works; flip about
    // the screen's right so the turn stays a pure pitch.
    if simd_dot(up, axes.up) < -0.9999 {
      return simd_quatd(angle: .pi, axis: axes.right)
    }
    return simd_quatd(from: up, to: axes.up)
  }

  /// The accelerometer reading for one IMU, in the remote's frame (m/s^2).
  ///
  /// - `acceleration`: raw CoreMotion acceleration (g, gravity included, gravity-vector sign).
  /// - `gravity`: the latest `CMDeviceMotion.gravity`, nil before the first device-motion sample.
  /// - `mount`: the baseline mount (`imuMount`), nil for the static neutral grip.
  static func imuAcceleration(
    source: IMUSource, acceleration: SIMD3<Double>, gravity: SIMD3<Double>?, mount: simd_quatd?,
    orientation: UIInterfaceOrientation
  ) -> SIMD3<Double> {
    switch source {
    case .phone:
      let proper = properAcceleration(acceleration)
      return wiimoteFrame(mount?.act(proper) ?? proper, orientation: orientation)
    case .level:
      // Without a gravity estimate there is no telling swing from tilt: rest level.
      guard let gravity else { return levelAcceleration }
      return levelAcceleration + wiimoteFrame(properAcceleration(acceleration - gravity), orientation: orientation)
    }
  }

  /// A device-frame rotation rate (rad/s) as the remote's (pitch, roll, yaw) rates, i.e.
  /// right-handed about its (left, back, top) axes, through the same mount as the accelerometer.
  static func imuAngularVelocity(
    _ rate: SIMD3<Double>, mount: simd_quatd?, orientation: UIInterfaceOrientation
  ) -> SIMD3<Double> {
    wiimoteFrame(mount?.act(rate) ?? rate, orientation: orientation)
  }

  #if DEBUG

  // MARK: - Debug pose injection

  /// Attitude (CoreMotion reference frame: X right, Y away from the player, Z up) of the phone in
  /// the neutral grip for `orientation`, reclined by `reclineDegrees` (top edge away from the
  /// player; 90 = face up, -90 = face down).
  static func debugHeldAttitude(orientation: UIInterfaceOrientation, reclineDegrees: Double) -> simd_quatd {
    let axes = screenAxes(for: orientation)
    let device = simd_double3x3(columns: (axes.right, axes.up, axes.out))
    let world = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)))
    let upright = simd_quatd(world * device.transpose)
    return simd_quatd(angle: -reclineDegrees * .pi / 180, axis: SIMD3(1, 0, 0)) * upright
  }

  /// Feeds one pose through the real sample handlers (device motion, then accelerometer and
  /// gyro) on the motion queue and holds it against real samples until `debugReleasePose()`.
  func debugInjectPose(
    attitude: simd_quatd, userAcceleration: SIMD3<Double>, rotationRate: SIMD3<Double>,
    orientation: UIInterfaceOrientation?, recenter: Bool
  ) -> [String: Any] {
    var result: [String: Any] = [:]
    operationQueue.addOperations([BlockOperation {
      self.debugPoseHeld = true
      if let orientation { self.orientation = orientation }
      if recenter { self.recenterPointer() }
      let gravity = attitude.inverse.act(SIMD3(0, 0, -1))
      let pointer = self.handleEnhancedMotionFeatures(DeviceMotionSample(
        attitude: attitude, gravity: gravity, userAcceleration: userAcceleration, rotationRate: rotationRate))
      let accel = self.handleAccelerometer(gravity + userAcceleration)
      let gyro = self.handleGyro(rotationRate)
      result = [
        "port": self.port,
        "orientation": self.orientation.rawValue,
        "irMode": Int(DOLConfigBridge.mainTouchPadIRMode()),
        "policy": ["wiimote": "\(Self.currentIMUPolicy().wiimote)", "nunchuk": "\(Self.currentIMUPolicy().nunchuk)"],
        "deviceGravity": [gravity.x, gravity.y, gravity.z],
        "wiimoteAccel": [accel.wiimote.x, accel.wiimote.y, accel.wiimote.z],
        "wiimoteAccel10bit": Self.debugAccel10Bit(accel.wiimote),
        "nunchukAccel": [accel.nunchuk.x, accel.nunchuk.y, accel.nunchuk.z],
        "wiimoteGyro": [gyro.x, gyro.y, gyro.z],
        "gyroPointer": pointer.map { [$0.horizontal, $0.vertical] } as Any,
      ]
    }], waitUntilFinished: true)
    return result
  }

  /// Writes `acceleration` (m/s^2, remote frame) to the Wii Remote's axes as-is, bypassing every
  /// mapping, and holds it: reproduces what an older mapping wrote for a pose.
  func debugWriteRawWiimoteAcceleration(_ acceleration: SIMD3<Double>) -> [String: Any] {
    operationQueue.addOperations([BlockOperation {
      self.debugPoseHeld = true
      for (button, value) in Self.wiimoteAccelWrites(x: acceleration.x, y: acceleration.y, z: acceleration.z) {
        TCManagerInterface.setAxisValueFor(button.rawValue, controller: self.port, value: value)
      }
    }], waitUntilFinished: true)
    return ["wiimoteAccel": [acceleration.x, acceleration.y, acceleration.z],
            "wiimoteAccel10bit": Self.debugAccel10Bit(acceleration)]
  }

  /// Presses touch-controller buttons (`TCButtonType` raw values) on the slot motion is bound to,
  /// releasing them after `holdSeconds`: drives a game's menus on a simulator, where nobody can
  /// press A and B together on the overlay.
  func debugPressButtons(_ buttons: [Int], holdSeconds: TimeInterval) -> [String: Any] {
    let port = port
    for button in buttons {
      TCManagerInterface.setButtonStateFor(button, controller: port, state: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
      for button in buttons {
        TCManagerInterface.setButtonStateFor(button, controller: port, state: false)
      }
    }
    return ["port": port, "buttons": buttons]
  }

  /// Lets real samples through again and rests the remote level.
  func debugReleasePose() {
    operationQueue.addOperations([BlockOperation {
      self.debugPoseHeld = false
      self.writeRestingIMU()
    }], waitUntilFinished: true)
  }

  /// The core's 10-bit reading (Wii Remote calibration: 512 = 0 g, 616 = 1 g), for comparing with
  /// the accelerometer bytes a game sees.
  private static func debugAccel10Bit(_ acceleration: SIMD3<Double>) -> [Int] {
    let scaled = acceleration * (616 - 512) / gravityToMetersPerSecondSquared
    return [scaled.x, scaled.y, scaled.z].map { max(0, min(1023, Int(($0 + 512).rounded()))) }
  }
  #endif

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
