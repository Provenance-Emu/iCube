// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of the motion UserDefaults for the Enhanced Motion screen. Defaults match the old view's `@AppStorage` defaults;
/// `full6DOF` is on so the default state (which search uses) contains the Nunchuk row.
struct EnhancedMotionState: Equatable {
  var horizontalMotionMode = HorizontalMotionMode.roll
  var wiimoteIMU = true
  var full6DOF = true
  var nunchukIMU = false
}

/// One user edit. The host applies it to its snapshot AND to UserDefaults; the builder only emits it.
enum EnhancedMotionChange: Equatable {
  case horizontalMotion(HorizontalMotionMode)
  case wiimoteIMU(Bool)
  case full6DOF(Bool)
  case nunchukIMU(Bool)
  case applyRecommended
}
