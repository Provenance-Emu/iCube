// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import UIKit

/// The live inputs of `PointerSourceResolver`: the connected menu remote's motion, the pointer mode,
/// the stored override and the device model. With `LiveControllerHubReader` (which supplies Wii
/// Remote 1's device and the pads), the only pointer-source code that reads `GCController`.
@MainActor
enum PointerSourceLive {
  /// A connected menu remote (the Siri Remote) reports a gyroscope. Unverified on hardware: the
  /// second-generation Siri Remote is expected to report none, so the remote source is offered only
  /// when this is true at runtime.
  static func remoteHasMotion() -> Bool {
    #if DEBUG
    if let fake = FakePointerCapabilities.current { return fake == .remoteMotion }
    #endif
    return GCController.controllers().contains { $0.isMenuRemote && $0.motion?.hasRotationRate == true }
  }

  /// "iPhone" / "iPad" / "Apple TV".
  static var deviceModel: String { UIDevice.current.model }

  static func model(wiimote1Qualifier: String, pads: [ConnectedPadState]) -> PointerSourceModel {
    PointerSourceModel.make(
      player1: .from(qualifier: wiimote1Qualifier, pads: pads), remoteHasMotion: remoteHasMotion(),
      platform: .current, preferredMode: PointerModeController.shared.mode,
      userOverride: PointerSourceOverrideStore().value, deviceModel: deviceModel)
  }

  /// Everything read now: Wii Remote 1's bound device and the connected pads.
  static func current() -> PointerSourceModel {
    let reader = LiveControllerHubReader()
    return model(wiimote1Qualifier: reader.boundQualifier(forWiimote: 1), pads: reader.connectedPads())
  }
}

#if DEBUG
/// `-ICubeFakePointerCapabilities <remote-motion|pad-gyro|pad-touchpad|none>` (DEBUG builds only):
/// the hub's reader reports a stand-in pad on Wii Remote 1 with these capabilities, and
/// `remote-motion` adds a stand-in Siri Remote that reports motion. The tvOS simulator has no
/// remote gyro and no pads, so this is how the pointer rows get screenshotted.
enum FakePointerCapabilities: String {
  case remoteMotion = "remote-motion"
  case padGyro = "pad-gyro"
  case padTouchpad = "pad-touchpad"
  case none

  static let launchArgument = "-ICubeFakePointerCapabilities"

  static let current: FakePointerCapabilities? = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: launchArgument), args.indices.contains(index + 1) else { return nil }
    return FakePointerCapabilities(rawValue: args[index + 1])
  }()

  /// The stand-in pad Wii Remote 1 reports while it has no device of its own.
  var padQualifier: String { "MFi/9/Stand-in Controller" }

  var pads: [ConnectedPadState] {
    var pad = ConnectedPadState(
      qualifier: padQualifier, name: "Stand-in Controller", batteryPercent: nil, isCharging: false, playerLabel: "P1")
    pad.hasGyro = self == .padGyro
    pad.hasTouchpad = self == .padTouchpad
    var pads = [pad]
    if self == .remoteMotion {
      pads.append(ConnectedPadState(
        qualifier: "MFi/8/Siri Remote", name: "Siri Remote", batteryPercent: nil, isCharging: false, playerLabel: nil,
        isMenuRemote: true))
    }
    return pads
  }
}
#endif
