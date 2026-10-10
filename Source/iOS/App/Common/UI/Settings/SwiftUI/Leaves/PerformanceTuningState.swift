// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys behind the Performance Tuning screen. The ObjC++ EmulationCoordinator reads the same strings.
enum PerformanceTuningDefaultsKey {
  static let adaptiveClock = "adaptive_clock_enable"
  static let vertexLoaderMode = "icube_vertex_loader_mode"
  static let cirProfile = "icube.cirProfile"
}

enum PerformanceTuningLimits {
  /// The emulated CPU and VI clock overrides, in percent.
  static let clockPercentRange: ClosedRange<Double> = 1 ... 400
}

/// How vertex data is decoded on the CPU. The raw value is what EmulationCoordinator reads at game launch.
enum VertexLoaderMode: Int, CaseIterable {
  case software = 0
  case neon = 1
  case compare = 2

  var label: String {
    switch self {
    case .software: return L("Software")
    case .neon: return L("NEON SIMD (default)")
    case .compare: return L("Compare (validate)")
    }
  }

  /// What an unset key means. The old `@AppStorage` supplied this default; a raw `integer(forKey:)` would read 0 (Software).
  static let `default` = VertexLoaderMode.neon

  /// An unset key is the default; a stored value is shown as it is (a value that matches no option shows a dash, as it did).
  static func storedRawValue(_ stored: Int?) -> Int { stored ?? Self.default.rawValue }
}

/// Snapshot of Config and UserDefaults for the Performance Tuning screen. Defaults match the old view's `@State` defaults.
/// `showValidation` is deliberately not here: it is host state, so a Config resync cannot collapse the section.
struct PerformanceTuningState: Equatable {
  var engine = CpuEngine.jitARM64
  /// True when the runtime acquired a JIT entitlement. On a jitless build the JIT engines are hidden and the core
  /// silently runs the Cached Interpreter.
  var jitAvailable = false
  var mmu = false
  var adaptiveClock = false
  var vertexLoaderMode = VertexLoaderMode.default.rawValue
  var pauseOnPanic = false
  var writeBackCache = false
  var disableICache = false
  var lowDCBZ = false
  var cachedInterpreterPrefetch = true
  var neonTextureDecode = true
  var cirPicLoadStore = true
  var cirSpecializedOps = true
  var cirSpecializedOpsValidate = false
  var cirSpecializedFpLs = false
  var cirSpecializedPsq = false
  var cirSpecializedFpArith = false
  var cirMicroOpFusion = false
  var cirMicroOpFusionValidate = false
  var cirDeadFlagElim = false
  var cirDeadFlagElimValidate = false
  var cirDeadFprfElim = false
  var cirDeadFprfElimValidate = false
  var cirPsqFastPath = false
  var cirPsqFastPathValidate = false
  var cirStoreLoopFF = false
  var cirStoreLoopFFValidate = false
  var cirCacheLoopFF = false
  var cirCacheLoopFFValidate = false
  var cirIrConstFusion = false
  var cirIrConstFusionValidate = false
  var cirPsNeon = false
  var cirPsNeonValidate = false
  var cirIrMicroOpFusion = false
  var cirIrMicroOpFusionValidate = false
  var cirIrDeadFlagElim = false
  var cirIrDeadFlagElimValidate = false
  var cirIrPicLoadStoreValidate = false
  var cirIrSpecializedOpsValidate = false
  var cirBlockLinking = false
  var cirBlockLinkingValidate = false
  var cirDynLinking = false
  var relaxedIdleDetection = false
  var fastForwardCtrIdle = false
  var syncOnSkipIdle = true
  var cirProfile = false
  var cpuClockEnabled = false
  var cpuClockPercent = 100
  /// Set while the adaptive clock or the running game's INI outranks the user's clock keys; the manual controls
  /// then show the user's own (Base) value, which applies again once the override clears.
  var cpuClockOverride = DOLConfigOverride.none
  var vbiEnabled = false
  var vbiPercent = 100
  var vbiOverride = DOLConfigOverride.none

  /// The engine that ACTUALLY runs. A stored JIT core runs as the Cached Interpreter on a jitless build, so the engine
  /// row and the optimisation sections follow that truth.
  var effectiveEngine: CpuEngine {
    if !jitAvailable && (engine == .jit64 || engine == .jitARM64) { return .cachedInterpreter }
    return engine
  }
  /// Optimisations apply only to the two Cached Interpreter engines.
  var showCIROpts: Bool { effectiveEngine == .cachedInterpreter }
  var showIROpts: Bool { effectiveEngine == .cachedInterpreterIR }
  var showEngineOpts: Bool { showCIROpts || showIROpts }
}

/// Every Bool setting on the screen, named like the old `@State` var. One case per row keeps `Change` from growing 45 cases.
enum PerformanceTuningFlag: CaseIterable {
  case mmu, pauseOnPanic, writeBackCache, disableICache, lowDCBZ
  case cachedInterpreterPrefetch, neonTextureDecode
  case relaxedIdleDetection, fastForwardCtrIdle, syncOnSkipIdle
  case adaptiveClock, cpuClockEnabled, vbiEnabled, cirProfile
  case cirPicLoadStore, cirSpecializedOps, cirSpecializedOpsValidate
  case cirSpecializedFpLs, cirSpecializedPsq, cirSpecializedFpArith
  case cirMicroOpFusion, cirMicroOpFusionValidate
  case cirDeadFlagElim, cirDeadFlagElimValidate
  case cirDeadFprfElim, cirDeadFprfElimValidate
  case cirPsqFastPath, cirPsqFastPathValidate
  case cirStoreLoopFF, cirStoreLoopFFValidate
  case cirCacheLoopFF, cirCacheLoopFFValidate
  case cirIrConstFusion, cirIrConstFusionValidate
  case cirPsNeon, cirPsNeonValidate
  case cirIrMicroOpFusion, cirIrMicroOpFusionValidate
  case cirIrDeadFlagElim, cirIrDeadFlagElimValidate
  case cirIrPicLoadStoreValidate, cirIrSpecializedOpsValidate
  case cirBlockLinking, cirBlockLinkingValidate, cirDynLinking

  var keyPath: WritableKeyPath<PerformanceTuningState, Bool> {
    switch self {
    case .mmu: return \.mmu
    case .pauseOnPanic: return \.pauseOnPanic
    case .writeBackCache: return \.writeBackCache
    case .disableICache: return \.disableICache
    case .lowDCBZ: return \.lowDCBZ
    case .cachedInterpreterPrefetch: return \.cachedInterpreterPrefetch
    case .neonTextureDecode: return \.neonTextureDecode
    case .relaxedIdleDetection: return \.relaxedIdleDetection
    case .fastForwardCtrIdle: return \.fastForwardCtrIdle
    case .syncOnSkipIdle: return \.syncOnSkipIdle
    case .adaptiveClock: return \.adaptiveClock
    case .cpuClockEnabled: return \.cpuClockEnabled
    case .vbiEnabled: return \.vbiEnabled
    case .cirProfile: return \.cirProfile
    case .cirPicLoadStore: return \.cirPicLoadStore
    case .cirSpecializedOps: return \.cirSpecializedOps
    case .cirSpecializedOpsValidate: return \.cirSpecializedOpsValidate
    case .cirSpecializedFpLs: return \.cirSpecializedFpLs
    case .cirSpecializedPsq: return \.cirSpecializedPsq
    case .cirSpecializedFpArith: return \.cirSpecializedFpArith
    case .cirMicroOpFusion: return \.cirMicroOpFusion
    case .cirMicroOpFusionValidate: return \.cirMicroOpFusionValidate
    case .cirDeadFlagElim: return \.cirDeadFlagElim
    case .cirDeadFlagElimValidate: return \.cirDeadFlagElimValidate
    case .cirDeadFprfElim: return \.cirDeadFprfElim
    case .cirDeadFprfElimValidate: return \.cirDeadFprfElimValidate
    case .cirPsqFastPath: return \.cirPsqFastPath
    case .cirPsqFastPathValidate: return \.cirPsqFastPathValidate
    case .cirStoreLoopFF: return \.cirStoreLoopFF
    case .cirStoreLoopFFValidate: return \.cirStoreLoopFFValidate
    case .cirCacheLoopFF: return \.cirCacheLoopFF
    case .cirCacheLoopFFValidate: return \.cirCacheLoopFFValidate
    case .cirIrConstFusion: return \.cirIrConstFusion
    case .cirIrConstFusionValidate: return \.cirIrConstFusionValidate
    case .cirPsNeon: return \.cirPsNeon
    case .cirPsNeonValidate: return \.cirPsNeonValidate
    case .cirIrMicroOpFusion: return \.cirIrMicroOpFusion
    case .cirIrMicroOpFusionValidate: return \.cirIrMicroOpFusionValidate
    case .cirIrDeadFlagElim: return \.cirIrDeadFlagElim
    case .cirIrDeadFlagElimValidate: return \.cirIrDeadFlagElimValidate
    case .cirIrPicLoadStoreValidate: return \.cirIrPicLoadStoreValidate
    case .cirIrSpecializedOpsValidate: return \.cirIrSpecializedOpsValidate
    case .cirBlockLinking: return \.cirBlockLinking
    case .cirBlockLinkingValidate: return \.cirBlockLinkingValidate
    case .cirDynLinking: return \.cirDynLinking
    }
  }
}

/// One user edit. The host applies it to its snapshot AND to Config / UserDefaults; the builder only emits it.
enum PerformanceTuningChange: Equatable {
  case flag(PerformanceTuningFlag, Bool)
  case cpuEngine(CpuEngine)
  case vertexLoaderMode(Int)
  case cpuClockPercent(Int)
  case vbiPercent(Int)
  /// Host @State only; never Config.
  case showValidation(Bool)
  case resetOptimizationsToRecommended
}
