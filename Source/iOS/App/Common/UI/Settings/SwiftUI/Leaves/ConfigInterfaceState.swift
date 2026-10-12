// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys behind the Interface screen. TVLibraryView reads the same two strings through `@AppStorage`.
enum ConfigInterfaceDefaultsKey {
  static let backgroundStyle = "library_background_style"
  static let showSubtitles = "library_show_subtitles"
  static let recordingWatermark = "recording_watermark"
  static let recordingCamera = "recording_camera_overlay"
}

/// Snapshot of Config and UserDefaults for the Interface screen. Defaults match the old view's `@State` / `@AppStorage` defaults.
struct ConfigInterfaceState: Equatable {
  var useNamesDB = false
  var useCovers = false
  var backgroundStyle = LibraryBackgroundStyle.gradient
  var showSubtitles = true
  var confirmOnStop = true
  var usePanicHandlers = true
  var osdMessages = true
  var recordingWatermark = true
  var recordingCamera = false

  /// `@AppStorage` supplied `true` for an unset key; `bool(forKey:)` would read false.
  static func storedShowSubtitles(_ stored: Bool?) -> Bool { stored ?? true }

  /// The watermark is on until the owner turns it off.
  static func storedRecordingWatermark(_ stored: Bool?) -> Bool { stored ?? true }
}

/// One user edit. The host applies it to its snapshot AND to Config / UserDefaults; the builder only emits it.
enum ConfigInterfaceChange: Equatable {
  case useNamesDB(Bool)
  case useCovers(Bool)
  case backgroundStyle(LibraryBackgroundStyle)
  case showSubtitles(Bool)
  case confirmOnStop(Bool)
  case usePanicHandlers(Bool)
  case osdMessages(Bool)
  case recordingWatermark(Bool)
  case recordingCamera(Bool)
}
