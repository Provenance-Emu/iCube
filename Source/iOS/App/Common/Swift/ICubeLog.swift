// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import os

/// Unified-logging categories for app code. `.debug` is dropped in release builds by the system, and
/// interpolated values are private by default, so paths and game names stay out of a sysdiagnose.
enum ICubeLog {
  static let subsystem = "com.joemattiello.iCube"
  static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}
