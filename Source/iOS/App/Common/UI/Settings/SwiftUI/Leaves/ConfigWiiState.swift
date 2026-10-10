// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Value ranges of the two Wii Remote sliders (the SYSCONF's own limits).
enum ConfigWiiLimits {
  static let sensorBarSensitivity: ClosedRange<Double> = 1 ... 5
  static let speakerVolume: ClosedRange<Double> = 0 ... 7
}

/// Snapshot of Config for the Wii screen. Defaults match the old view's `@State` defaults.
struct ConfigWiiState: Equatable {
  var pal60 = false
  var widescreen = false
  var screensaver = false
  /// English.
  var language = 1
  /// Stereo.
  var soundMode = 1
  /// Bottom.
  var sensorBarPosition = 0
  var sensorBarSensitivity = 2
  var speakerVolume = 4
  var wiimoteRumble = true
  var touchpadIRFollowWithoutClick = false
  var skylanderPortal = false
  var keyboard = false
  var wiilink = false
  var sdFolderSync = false
}

/// The UserDefaults key the touchpad IR setting is stored under; defined once so the host's read and write cannot drift.
enum ConfigWiiDefaultsKey {
  static let touchpadIRFollowWithoutClick = "touchpad_ir_follow_without_click"
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigWiiChange: Equatable {
  case pal60(Bool)
  case widescreen(Bool)
  case screensaver(Bool)
  case language(Int)
  case soundMode(Int)
  case sensorBarPosition(Int)
  case sensorBarSensitivity(Int)
  case speakerVolume(Int)
  case wiimoteRumble(Bool)
  case touchpadIRFollowWithoutClick(Bool)
  case skylanderPortal(Bool)
  case keyboard(Bool)
  case wiilink(Bool)
  case sdFolderSync(Bool)
}
