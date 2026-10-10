// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Internal-resolution picks with a fixed meaning; every other value is the scale itself (2x ... max).
enum EfbScaleChoice: Int {
  /// Fit the window (Auto-IR territory).
  case auto = 0
  case native = 1
}

/// The MSAA sample ladder the UI offers; raw values are the sample counts Config stores.
enum MsaaSamples: Int, CaseIterable {
  case none = 1
  case x2 = 2
  case x4 = 4
  case x8 = 8
}

/// OutputResamplingMode as Config stores it.
enum OutputResamplingChoice: Int, CaseIterable {
  case standard = 0
  case bilinear = 1
  case bSpline = 2
  case mitchellNetravali = 3
  case catmullRom = 4
  case sharpBilinear = 5
  case areaSampling = 6
}

/// Snapshot of Config for the Enhancements screen. Defaults match the old view's `@State` defaults.
struct GraphicsEnhancementsState: Equatable {
  var anisotropy = 1
  var msaa = MsaaSamples.none.rawValue
  var ssaa = false
  var outputResampling = OutputResamplingChoice.standard.rawValue
  var trueColor = true
  var disableCopyFilter = true
  var efbScale = EfbScaleChoice.native.rawValue
  var efbMaxScale = 6
  /// Set while Auto-IR / thermal (CurrentRun) or the running game's INI outranks the user's own scale.
  var efbOverride: DOLConfigOverride = .none
  var widescreenHack = false
  var disableFog = false
  var arbitraryMipmapDetection = false
  var arbitraryMipmapThreshold = 0.5
  var hdrOutput = false
  var gpuTextureDecoding = false

  /// Anisotropy sample counts the picker offers.
  static let anisotropyLadder = [1, 2, 4, 8, 16]
  /// The threshold is the average per-pixel/per-channel percent diff between an expected blurred mipmap and the received
  /// one (default 14.0; ~4.5 is just below clearly-arbitrary), so it spans 0 ... 30.
  static let mipmapThresholdRange = 0.0 ... 30.0
  static let mipmapThresholdStep = 0.1

  /// Snap an arbitrary stored MSAA sample count to the fixed UI ladder (1/2/4/8).
  static func normalizedMsaa(_ samples: Int) -> Int {
    switch samples {
    case ..<2: return MsaaSamples.none.rawValue
    case 2 ... 3: return MsaaSamples.x2.rawValue
    case 4 ... 7: return MsaaSamples.x4.rawValue
    default: return MsaaSamples.x8.rawValue
    }
  }

  /// A stored sample count between ladder steps shows as the step below it (never a dash).
  static func normalizedAnisotropy(_ samples: Int) -> Int {
    anisotropyLadder.last { $0 <= samples } ?? anisotropyLadder[0]
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum GraphicsEnhancementsChange: Equatable {
  case efbScale(Int)
  case anisotropy(Int)
  case msaa(Int)
  case ssaa(Bool)
  case outputResampling(Int)
  case trueColor(Bool)
  case disableCopyFilter(Bool)
  case widescreenHack(Bool)
  case hdrOutput(Bool)
  case gpuTextureDecoding(Bool)
  case disableFog(Bool)
  case arbitraryMipmapDetection(Bool)
  case arbitraryMipmapThreshold(Double)
}

/// What a change implies beyond writing its own key. Pure so the rules are tested; the host performs them.
enum GraphicsEnhancementsSideEffect: Equatable {
  /// Picking a fixed scale means the user wants that exact IR; Auto-IR also drives GFX_EFB_SCALE, so leaving it on makes the two fight.
  case autoIROff
  /// Desktop parity: SSAA only applies when MSAA > 1.
  case clearSSAA
}

extension GraphicsEnhancementsState {
  static func sideEffects(of change: GraphicsEnhancementsChange, in state: GraphicsEnhancementsState) -> [GraphicsEnhancementsSideEffect] {
    switch change {
    case .efbScale(let scale) where scale != EfbScaleChoice.auto.rawValue: return [.autoIROff]
    case .msaa(let samples) where samples <= MsaaSamples.none.rawValue && state.ssaa: return [.clearSSAA]
    default: return []
    }
  }
}
