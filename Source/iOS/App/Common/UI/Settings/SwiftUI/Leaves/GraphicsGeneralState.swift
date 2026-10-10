// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys behind the Video screen, named once for the Swift readers and writers (this screen, ReplayKitManager,
/// MainDisplaySceneDelegate). EmulationCoordinator.mm and DOLConfigBridge.mm repeat the same strings in Objective-C++.
enum GraphicsGeneralDefaultsKey {
  static let backend = "ui_gfx_backend"
  static let tripleBuffering = "gfx_triple_buffering"
  static let forceScaleOne = "gfx_force_scale_one_non_promo"
  static let overscanFullscreen = "gfx_overscan_fullscreen"
  static let frameCap = "ui_frame_cap"
  static let instantReplay = TopBarDefaultsKey.instantReplayEnabled
  static let saveToPhotos = "replaykit_save_to_photos"
  static let saveOnlyPhotos = "replaykit_save_only_photos"
  static let clipSeconds = "replaykit_clip_seconds"
}

/// Snapshot of Config and UserDefaults for the Video screen. Defaults match the old view's `@State` defaults, except
/// `tripleBuffering`, which is ON until the user turns it off (an unset key means ON).
struct GraphicsGeneralState: Equatable {
  var backend = GraphicsBackend.metal
  var aspect = AspectRatio.auto
  var vSync = false
  var showAutoIrOSD = false
  var tripleBuffering = true
  var forceScaleOneNonProMotion = false
  var overscanFullscreen = false
  var asyncPresent = false
  var autoIR = false
  var targetFPS = TargetFPS.fps60
  var minScale = InternalScale.x1_0
  var maxScale = InternalScale.x2_0
  var frameCap = GraphicsGeneralState.systemDefaultFrameCap
  var instantReplay = false
  var saveClipsToPhotos = false
  var saveOnlyToPhotos = false
  var clipSeconds = GraphicsGeneralState.defaultClipSeconds
  // Placeholder until sync() reads Config (the iCube default is Hybrid Ubershaders; the old view's @State also started at Specialized).
  var shaderType = ShaderCompileType.specialized
  var compileBeforeStart = true
  /// The frame cap and Recording rows are iOS only; the tvOS host leaves this false.
  var isIOS = true

  /// 0 = let the OS pick the display refresh.
  static let systemDefaultFrameCap = 0
  static let frameCapLadder = [systemDefaultFrameCap, 30, 60, 90, 120]
  static let clipSecondsLadder = [5, 10, 15, 30]
  static let defaultClipSeconds = 15

  /// Unset (0) or negative is the default length, as ReplayKitManager reads it; any other stored length is shown as stored.
  static func storedClipSeconds(_ stored: Int) -> Int {
    stored > 0 ? stored : defaultClipSeconds
  }

  /// The ladder, plus the stored value when it is not on it, so the row shows the raw value instead of a dash.
  static func options(_ ladder: [Int], including value: Int) -> [Int] {
    ladder.contains(value) ? ladder : (ladder + [value]).sorted()
  }

  /// The Metal/OGL/Vulkan key the screen shows: the user's saved choice when there is one, else what Config holds.
  static func effectiveBackendKey(defaults: String?, config: String) -> String {
    guard let defaults, !defaults.isEmpty else { return config }
    return defaults
  }
}

/// One user edit. The host applies it to its snapshot AND to Config / UserDefaults; the builder only emits it.
enum GraphicsGeneralChange: Equatable {
  case backend(GraphicsBackend)
  case aspect(AspectRatio)
  case vSync(Bool)
  case showAutoIrOSD(Bool)
  case tripleBuffering(Bool)
  case forceScaleOneNonProMotion(Bool)
  case overscanFullscreen(Bool)
  case asyncPresent(Bool)
  case autoIR(Bool)
  case targetFPS(TargetFPS)
  case minScale(InternalScale)
  case maxScale(InternalScale)
  case frameCap(Int)
  case instantReplay(Bool)
  case saveClipsToPhotos(Bool)
  case saveOnlyToPhotos(Bool)
  case clipSeconds(Int)
  case shaderType(ShaderCompileType)
  case compileBeforeStart(Bool)
}
