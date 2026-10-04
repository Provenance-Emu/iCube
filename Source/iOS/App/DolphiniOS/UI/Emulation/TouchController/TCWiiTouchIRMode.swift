// Copyright 2024 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The touch side of the Wii pointer; raw values match `PointerMode`. In `.gyro` the touch surfaces
/// are inert and `TCDeviceMotion` drives the pointer.
@objc enum TCWiiTouchIRMode: Int {
  case gyro = 0
  case follow = 1
  case drag = 2
}
