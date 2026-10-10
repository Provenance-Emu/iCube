// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Performance Tuning, on the menu engine. `sync()` reads Config and UserDefaults into the snapshot and writes nothing;
/// `apply(_:)` is the only writer. `showValidation` is host state so a Config resync cannot collapse the section.
struct PerformanceTuningView: View {
  @State private var state = PerformanceTuningState()
  @State private var showValidation = false

  var body: some View {
    SettingsLeafScreen(model: PerformanceTuningModelBuilder.make(state: state, showValidation: showValidation, apply: apply),
                       title: L("Performance Tuning"), sync: sync)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = PerformanceTuningState()
    s.jitAvailable = JitManager.shared().acquiredJit
    s.engine = CpuEngine.from(raw: DOLConfigBridge.mainCpuCore())
    s.mmu = DOLConfigBridge.mainMMU()
    s.adaptiveClock = defaults.bool(forKey: PerformanceTuningDefaultsKey.adaptiveClock)
    s.vertexLoaderMode = VertexLoaderMode.storedRawValue(defaults.object(forKey: PerformanceTuningDefaultsKey.vertexLoaderMode) as? Int)
    s.pauseOnPanic = DOLConfigBridge.mainPauseOnPanic()
    s.writeBackCache = DOLConfigBridge.mainAccurateCpuCache()
    s.disableICache = DOLConfigBridge.mainDisableICache()
    s.lowDCBZ = DOLConfigBridge.mainLowDCBZHack()
    s.cachedInterpreterPrefetch = DOLConfigBridge.mainCachedInterpreterPrefetch()
    s.neonTextureDecode = DOLConfigBridge.gfxHackNeonTextureDecode()
    s.cirPicLoadStore = DOLConfigBridge.cirPicLoadStore()
    s.cirSpecializedOps = DOLConfigBridge.cirSpecializedOps()
    s.cirSpecializedOpsValidate = DOLConfigBridge.cirSpecializedOpsValidate()
    s.cirSpecializedFpLs = DOLConfigBridge.cirSpecializedFpLs()
    s.cirSpecializedPsq = DOLConfigBridge.cirSpecializedPsq()
    s.cirSpecializedFpArith = DOLConfigBridge.cirSpecializedFpArith()
    s.cirMicroOpFusion = DOLConfigBridge.cirMicroOpFusion()
    s.cirMicroOpFusionValidate = DOLConfigBridge.cirMicroOpFusionValidate()
    s.cirDeadFlagElim = DOLConfigBridge.cirDeadFlagElim()
    s.cirDeadFlagElimValidate = DOLConfigBridge.cirDeadFlagElimValidate()
    s.cirDeadFprfElim = DOLConfigBridge.cirDeadFprfElim()
    s.cirDeadFprfElimValidate = DOLConfigBridge.cirDeadFprfElimValidate()
    s.cirPsqFastPath = DOLConfigBridge.cirPsqFastPath()
    s.cirPsqFastPathValidate = DOLConfigBridge.cirPsqFastPathValidate()
    s.cirStoreLoopFF = DOLConfigBridge.cirStoreLoopFF()
    s.cirStoreLoopFFValidate = DOLConfigBridge.cirStoreLoopFFValidate()
    s.cirCacheLoopFF = DOLConfigBridge.cirCacheLoopFF()
    s.cirCacheLoopFFValidate = DOLConfigBridge.cirCacheLoopFFValidate()
    s.cirIrConstFusion = DOLConfigBridge.cirIrConstFusion()
    s.cirIrConstFusionValidate = DOLConfigBridge.cirIrConstFusionValidate()
    s.cirPsNeon = DOLConfigBridge.cirPsNeon()
    s.cirPsNeonValidate = DOLConfigBridge.cirPsNeonValidate()
    s.cirIrMicroOpFusion = DOLConfigBridge.cirIrMicroOpFusion()
    s.cirIrMicroOpFusionValidate = DOLConfigBridge.cirIrMicroOpFusionValidate()
    s.cirIrDeadFlagElim = DOLConfigBridge.cirIrDeadFlagElim()
    s.cirIrDeadFlagElimValidate = DOLConfigBridge.cirIrDeadFlagElimValidate()
    s.cirIrPicLoadStoreValidate = DOLConfigBridge.cirIrPicLoadStoreValidate()
    s.cirIrSpecializedOpsValidate = DOLConfigBridge.cirIrSpecializedOpsValidate()
    s.cirBlockLinking = DOLConfigBridge.cirBlockLinking()
    s.cirDynLinking = DOLConfigBridge.cirDynLinking()
    s.cirBlockLinkingValidate = DOLConfigBridge.cirBlockLinkingValidate()
    s.relaxedIdleDetection = DOLConfigBridge.mainRelaxedIdleDetection()
    s.fastForwardCtrIdle = DOLConfigBridge.mainFastForwardCtrIdle()
    s.syncOnSkipIdle = DOLConfigBridge.mainSyncOnSkipIdle()
    s.cirProfile = defaults.bool(forKey: PerformanceTuningDefaultsKey.cirProfile)
    // The user's own clocks (Base), not the adaptive clock's CurrentRun value: these rows edit Base.
    s.cpuClockEnabled = DOLConfigBridge.mainOverclockEnableBase()
    s.cpuClockPercent = DOLConfigBridge.mainOverclockPercentBase()
    s.vbiEnabled = DOLConfigBridge.mainViOverclockEnableBase()
    s.vbiPercent = DOLConfigBridge.mainViOverclockPercentBase()
    // Does the adaptive clock or the running game outrank these clock keys?
    s.cpuClockOverride = DOLConfigBridge.overclockOverride()
    s.vbiOverride = DOLConfigBridge.viOverclockOverride()
    state = s
  }

  private func apply(_ change: PerformanceTuningChange) {
    switch change {
    case .flag(let flag, let value):
      state[keyPath: flag.keyPath] = value
      write(flag, value)
    case .cpuEngine(let v): state.engine = v; DOLConfigBridge.setMainCpuCore(v.rawValue)
    case .vertexLoaderMode(let v): state.vertexLoaderMode = v; UserDefaults.standard.set(v, forKey: PerformanceTuningDefaultsKey.vertexLoaderMode)
    case .cpuClockPercent(let v): state.cpuClockPercent = v; DOLConfigBridge.setMainOverclockPercent(v)
    case .vbiPercent(let v): state.vbiPercent = v; DOLConfigBridge.setMainViOverclockPercent(v)
    case .showValidation(let v): showValidation = v
    case .resetOptimizationsToRecommended:
      // Deletes the optimization keys so each follows the compiled default (MainSettings.cpp).
      DOLConfigBridge.resetCirOptimizationsToDefaults()
      sync()
    }
  }

  /// One Bool setting to its Config key or UserDefault.
  private func write(_ flag: PerformanceTuningFlag, _ v: Bool) {
    switch flag {
    case .mmu: DOLConfigBridge.setMainMMU(v)
    case .pauseOnPanic: DOLConfigBridge.setMainPauseOnPanic(v)
    case .writeBackCache: DOLConfigBridge.setMainAccurateCpuCache(v)
    case .disableICache: DOLConfigBridge.setMainDisableICache(v)
    case .lowDCBZ: DOLConfigBridge.setMainLowDCBZHack(v)
    case .cachedInterpreterPrefetch: DOLConfigBridge.setMainCachedInterpreterPrefetch(v)
    case .neonTextureDecode: DOLConfigBridge.setGfxHackNeonTextureDecode(v)
    case .relaxedIdleDetection: DOLConfigBridge.setMainRelaxedIdleDetection(v)
    case .fastForwardCtrIdle: DOLConfigBridge.setMainFastForwardCtrIdle(v)
    case .syncOnSkipIdle: DOLConfigBridge.setMainSyncOnSkipIdle(v)
    case .adaptiveClock: UserDefaults.standard.set(v, forKey: PerformanceTuningDefaultsKey.adaptiveClock)
    case .cpuClockEnabled: DOLConfigBridge.setMainOverclockEnable(v)
    case .vbiEnabled: DOLConfigBridge.setMainViOverclockEnable(v)
    case .cirProfile: UserDefaults.standard.set(v, forKey: PerformanceTuningDefaultsKey.cirProfile)
    case .cirPicLoadStore: DOLConfigBridge.setCirPicLoadStore(v)
    case .cirSpecializedOps: DOLConfigBridge.setCirSpecializedOps(v)
    case .cirSpecializedOpsValidate: DOLConfigBridge.setCirSpecializedOpsValidate(v)
    case .cirSpecializedFpLs: DOLConfigBridge.setCirSpecializedFpLs(v)
    case .cirSpecializedPsq: DOLConfigBridge.setCirSpecializedPsq(v)
    case .cirSpecializedFpArith: DOLConfigBridge.setCirSpecializedFpArith(v)
    case .cirMicroOpFusion: DOLConfigBridge.setCirMicroOpFusion(v)
    case .cirMicroOpFusionValidate: DOLConfigBridge.setCirMicroOpFusionValidate(v)
    case .cirDeadFlagElim: DOLConfigBridge.setCirDeadFlagElim(v)
    case .cirDeadFlagElimValidate: DOLConfigBridge.setCirDeadFlagElimValidate(v)
    case .cirDeadFprfElim: DOLConfigBridge.setCirDeadFprfElim(v)
    case .cirDeadFprfElimValidate: DOLConfigBridge.setCirDeadFprfElimValidate(v)
    case .cirPsqFastPath: DOLConfigBridge.setCirPsqFastPath(v)
    case .cirPsqFastPathValidate: DOLConfigBridge.setCirPsqFastPathValidate(v)
    case .cirStoreLoopFF: DOLConfigBridge.setCirStoreLoopFF(v)
    case .cirStoreLoopFFValidate: DOLConfigBridge.setCirStoreLoopFFValidate(v)
    case .cirCacheLoopFF: DOLConfigBridge.setCirCacheLoopFF(v)
    case .cirCacheLoopFFValidate: DOLConfigBridge.setCirCacheLoopFFValidate(v)
    case .cirIrConstFusion: DOLConfigBridge.setCirIrConstFusion(v)
    case .cirIrConstFusionValidate: DOLConfigBridge.setCirIrConstFusionValidate(v)
    case .cirPsNeon: DOLConfigBridge.setCirPsNeon(v)
    case .cirPsNeonValidate: DOLConfigBridge.setCirPsNeonValidate(v)
    case .cirIrMicroOpFusion: DOLConfigBridge.setCirIrMicroOpFusion(v)
    case .cirIrMicroOpFusionValidate: DOLConfigBridge.setCirIrMicroOpFusionValidate(v)
    case .cirIrDeadFlagElim: DOLConfigBridge.setCirIrDeadFlagElim(v)
    case .cirIrDeadFlagElimValidate: DOLConfigBridge.setCirIrDeadFlagElimValidate(v)
    case .cirIrPicLoadStoreValidate: DOLConfigBridge.setCirIrPicLoadStoreValidate(v)
    case .cirIrSpecializedOpsValidate: DOLConfigBridge.setCirIrSpecializedOpsValidate(v)
    case .cirBlockLinking: DOLConfigBridge.setCirBlockLinking(v)
    case .cirBlockLinkingValidate: DOLConfigBridge.setCirBlockLinkingValidate(v)
    case .cirDynLinking: DOLConfigBridge.setCirDynLinking(v)
    }
  }
}
