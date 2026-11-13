// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import simd

/// Builds Motion Test (Settings → Controllers → Motion): live motion-sensor readings, for checking
/// on real hardware that a controller's motion reaches the emulated Wii Remote the right way round.
///
/// One section per source, each with the same rows: the pose and the turn in words (what a tester
/// reads), the emulated Wii Remote's numbers, the sensor's raw numbers, and for a controller what
/// it says its sensors can do. Controllers first, then this device (iOS), then menu remotes.
///
/// Pure: state in, `MenuModel` out. Every row is an enabled no-op, because a tvOS list scrolls only
/// by focus and a disabled row takes none (as the hub's Help rows).
enum MotionTestModelBuilder {
  static func make(state: MotionTestState, platform: PlatformKind) -> MenuModel {
    let controllers = state.sources.filter { $0.kind == .controller }
    var sections = controllers.map { section(for: $0, footer: controllerFooter) }
    if controllers.isEmpty { sections.append(noControllersSection) }
    if platform == .ios { sections.append(deviceSection(state: state)) }
    sections += state.sources.filter { $0.kind == .menuRemote }.map { section(for: $0, footer: nil) }
    return MenuModel(sections: sections)
  }

  static let noControllersRowID = "no-motion-controllers"
  static let deviceSectionID = "motion-device"
  static let deviceUnavailableRowID = "device-unavailable"
  static var deviceHeader: String { L("This Device (Touchscreen)") }

  static func sectionID(_ source: MotionTestSource) -> String { "motion-" + source.id }
  static func poseRowID(_ source: MotionTestSource) -> String { source.id + "-pose" }
  static func turnRowID(_ source: MotionTestSource) -> String { source.id + "-turn" }
  static func remoteAccelerationRowID(_ source: MotionTestSource) -> String { source.id + "-remote-accel" }
  static func remoteGyroRowID(_ source: MotionTestSource) -> String { source.id + "-remote-gyro" }
  static func rawAccelerationRowID(_ source: MotionTestSource) -> String { source.id + "-raw-accel" }
  static func rawRotationRowID(_ source: MotionTestSource) -> String { source.id + "-raw-gyro" }
  static func capabilitiesRowID(_ source: MotionTestSource) -> String { source.id + "-capabilities" }
  static func activationRowID(_ source: MotionTestSource) -> String { source.id + "-activation" }

  // MARK: Sections

  private static var controllerFooter: String {
    L("Lying flat with its buttons up, a controller must read Flat, face up. If it reads something else, flip the matching switch under Motion Axes on that player's screen (Pointer & Motion). These readings are taken before those switches.")
  }

  private static var deviceFooter: String {
    L("The touchscreen plays as a Wii Remote pointing out of the back of the device. Held upright with the screen facing you it reads Flat, face up; lying on a table it reads Pointing at the floor. In a game, Recenter makes your grip level, and the touch pointer modes keep the remote level.")
  }

  private static var noControllersSection: MenuSection {
    MenuSection(id: "motion-controllers", header: L("Controllers"), items: [MenuItem(
      id: noControllersRowID, title: L("No controller with motion sensors"),
      subtitle: L("Connect one that has them, such as a DualSense."), icon: "gamecontroller", role: .action({}))])
  }

  private static func deviceSection(state: MotionTestState) -> MenuSection {
    let header = deviceHeader
    guard let device = state.device else {
      return MenuSection(id: deviceSectionID, header: header, items: [MenuItem(
        id: deviceUnavailableRowID,
        title: state.deviceMotionAvailable ? L("Waiting for the motion sensors…") : L("This device has no motion sensors"),
        icon: "iphone", role: .action({}))])
    }
    return MenuSection(id: deviceSectionID, header: header, footer: deviceFooter, items: rows(for: device))
  }

  private static func section(for source: MotionTestSource, footer: String?) -> MenuSection {
    MenuSection(id: sectionID(source), header: source.name, footer: footer, items: rows(for: source))
  }

  private static func rows(for source: MotionTestSource) -> [MenuItem] {
    let attitude = WiiRemoteAttitude(acceleration: source.remote.acceleration)
    var items = [
      MenuItem(
        id: poseRowID(source), title: attitude.pose.title, subtitle: tiltText(attitude), icon: "wand.and.rays",
        role: .action({})),
      turnRow(for: source),
      MenuItem(
        id: remoteAccelerationRowID(source), title: L("Wii Remote Accelerometer"),
        subtitle: String(
          format: L("Left %@ · Back %@ · Up %@ m/s²"),
          signed(source.remote.acceleration.x), signed(source.remote.acceleration.y), signed(source.remote.acceleration.z)),
        icon: "arrow.up.and.down", role: .action({})),
      MenuItem(
        id: remoteGyroRowID(source), title: L("Wii Remote Gyroscope"),
        subtitle: source.remote.angularVelocity.map {
          String(format: L("Pitch Down %@ · Roll Left %@ · Yaw Left %@ rad/s"), signed($0.x), signed($0.y), signed($0.z))
        } ?? L("Not reported"),
        icon: "arrow.triangle.2.circlepath", role: .action({})),
      MenuItem(
        id: rawAccelerationRowID(source), title: L("Raw Acceleration"),
        subtitle: String(
          format: L("X %@ · Y %@ · Z %@ g"),
          signed(source.acceleration.x), signed(source.acceleration.y), signed(source.acceleration.z)),
        icon: "sensor.tag.radiowaves.forward", role: .action({})),
      MenuItem(
        id: rawRotationRowID(source), title: L("Raw Rotation Rate"),
        subtitle: source.rotationRate.map {
          String(format: L("X %@ · Y %@ · Z %@ rad/s"), signed($0.x), signed($0.y), signed($0.z))
        } ?? L("Not reported"),
        icon: "sensor.tag.radiowaves.forward", role: .action({})),
    ]
    if let flags = source.flags {
      items.append(MenuItem(
        id: capabilitiesRowID(source), title: L("Sensor Reports"),
        subtitle: String(
          format: L("Rotation rate: %@ · Gravity and user acceleration: %@ · Attitude: %@"),
          yesNo(flags.hasRotationRate), yesNo(flags.hasGravityAndUserAcceleration), yesNo(flags.hasAttitude)),
        icon: "info.circle", role: .action({})))
      items.append(MenuItem(
        id: activationRowID(source), title: L("Sensor Activation"), subtitle: activationText(flags),
        icon: "power", role: .action({})))
    }
    return items
  }

  private static func turnRow(for source: MotionTestSource) -> MenuItem {
    let title = source.remote.angularVelocity.map { WiiRemoteTurn(angularVelocity: $0).title } ?? L("No gyroscope")
    return MenuItem(id: turnRowID(source), title: title, icon: "gyroscope", role: .action({}))
  }

  // MARK: Text

  /// "Pitch +20° · Roll +0°", nil when the reading says nothing about tilt.
  static func tiltText(_ attitude: WiiRemoteAttitude) -> String? {
    guard let pitch = attitude.pitchDegrees, let roll = attitude.rollDegrees else { return nil }
    return String(format: L("Pitch %@° · Roll %@°"), signed(pitch, decimals: 0), signed(roll, decimals: 0))
  }

  private static func activationText(_ flags: MotionSensorFlags) -> String {
    guard flags.sensorsRequireManualActivation else { return L("Automatic") }
    return flags.sensorsActive ? L("Manual, switched on") : L("Manual, switched off")
  }

  private static func yesNo(_ value: Bool) -> String { value ? L("Yes") : L("No") }

  /// A value with its sign always shown and a fixed number of decimals. A value that rounds to zero
  /// is "+0.00" whichever side it is on, so a resting axis does not flicker between "+" and "-".
  static func signed(_ value: Double, decimals: Int = 2) -> String {
    let scale = pow(10, Double(decimals))
    let rounded = (value * scale).rounded() / scale
    return String(format: "%+.\(decimals)f", rounded == 0 ? 0 : rounded)
  }
}
