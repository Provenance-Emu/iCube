// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Graphics Advanced, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct GraphicsAdvancedView: View {
  @State private var state = GraphicsAdvancedState()

  var body: some View {
    SettingsLeafScreen(model: GraphicsAdvancedModelBuilder.make(state: state, apply: apply), title: L("Advanced"), sync: sync)
      .task { state.texturePackBytes = await TexturePackSize.bytesOnDisk() }
  }

  private func sync() {
    var s = GraphicsAdvancedState()
    // sync builds a fresh state, so the measured pack size would otherwise vanish on every Config change.
    s.texturePackBytes = state.texturePackBytes
    s.showFPS = DOLConfigBridge.gfxShowFPS()
    s.showVPS = DOLConfigBridge.gfxShowVPS()
    s.showSpeed = DOLConfigBridge.gfxShowSpeed()
    s.showFrameTimes = DOLConfigBridge.gfxShowFTimes()
    s.showVBlankTimes = DOLConfigBridge.gfxShowVTimes()
    s.showGraphs = DOLConfigBridge.gfxShowGraphs()
    s.logRenderTime = DOLConfigBridge.gfxLogRenderTimeToFile()
    s.speedColors = DOLConfigBridge.gfxShowSpeedColors()
    s.overlayStats = DOLConfigBridge.gfxOverlayStats()
    s.validationLayer = DOLConfigBridge.gfxEnableValidationLayer()
    s.hiresTextures = DOLConfigBridge.gfxHiresTextures()
    s.prefetchTextures = DOLConfigBridge.gfxCacheHiresTextures()
    s.disableEfbToVRAM = DOLConfigBridge.gfxHackDisableCopyToVRAM()
    s.graphicsMods = DOLConfigBridge.gfxModsEnable()
    s.cropPicture = DOLConfigBridge.gfxCrop()
    s.progressiveScan = DOLConfigBridge.sysconfProgressiveScan()
    s.fastDepth = DOLConfigBridge.gfxFastDepthCalc()
    s.pixelLighting = DOLConfigBridge.gfxEnablePixelLighting()
    s.backendMT = DOLConfigBridge.gfxBackendMultithreading()
    s.shaderCache = DOLConfigBridge.gfxShaderCache()
    s.saveTexCache = DOLConfigBridge.gfxSaveTextureCacheToState()
    s.preferVSForLines = DOLConfigBridge.gfxPreferVSForLinePointExpansion()
    s.cpuCull = DOLConfigBridge.gfxCpuCull()
    s.deferEfbInvalidation = DOLConfigBridge.gfxHackEfbDeferInvalidation()
    s.maxThreads = GraphicsAdvancedState.maxThreads(forProcessorCount: ProcessInfo.processInfo.processorCount)
    s.compilerThreads = GraphicsAdvancedState.threadCount(stored: DOLConfigBridge.gfxShaderCompilerThreads(), maxThreads: s.maxThreads)
    s.precompilerThreads = GraphicsAdvancedState.threadCount(stored: DOLConfigBridge.gfxShaderPrecompilerThreads(), maxThreads: s.maxThreads)
    s.usePresentDrawable = DOLConfigBridge.gfxMtlUsePresentDrawable()
    s.manuallyUploadBuffers = DOLConfigBridge.gfxMtlManuallyUploadBuffers()
    state = s
  }

  private func apply(_ change: GraphicsAdvancedChange) {
    switch change {
    case .flag(let flag, let v):
      state[keyPath: flag.keyPath] = v
      write(flag, v)
    case .compilerThreads(let v): state.compilerThreads = v; DOLConfigBridge.setGfxShaderCompilerThreads(v)
    case .precompilerThreads(let v): state.precompilerThreads = v; DOLConfigBridge.setGfxShaderPrecompilerThreads(v)
    case .presentDrawable(let v): state.usePresentDrawable = v; DOLConfigBridge.setGfxMtlUsePresentDrawable(v)
    case .manuallyUploadBuffers(let v): state.manuallyUploadBuffers = v; DOLConfigBridge.setGfxMtlManuallyUploadBuffers(v)
    }
  }

  private func write(_ flag: GraphicsAdvancedFlag, _ v: Bool) {
    switch flag {
    case .showFPS: DOLConfigBridge.setGfxShowFPS(v)
    case .showVPS: DOLConfigBridge.setGfxShowVPS(v)
    case .showSpeed: DOLConfigBridge.setGfxShowSpeed(v)
    case .showFrameTimes: DOLConfigBridge.setGfxShowFTimes(v)
    case .showVBlankTimes: DOLConfigBridge.setGfxShowVTimes(v)
    case .showGraphs: DOLConfigBridge.setGfxShowGraphs(v)
    case .logRenderTime: DOLConfigBridge.setGfxLogRenderTimeToFile(v)
    case .speedColors: DOLConfigBridge.setGfxShowSpeedColors(v)
    case .overlayStats: DOLConfigBridge.setGfxOverlayStats(v)
    case .validationLayer: DOLConfigBridge.setGfxEnableValidationLayer(v)
    case .hiresTextures: DOLConfigBridge.setGfxHiresTextures(v)
    case .prefetchTextures: DOLConfigBridge.setGfxCacheHiresTextures(v)
    case .disableEfbToVRAM: DOLConfigBridge.setGfxHackDisableCopyToVRAM(v)
    case .graphicsMods: DOLConfigBridge.setGfxModsEnable(v)
    case .cropPicture: DOLConfigBridge.setGfxCrop(v)
    case .progressiveScan: DOLConfigBridge.setSysconfProgressiveScan(v)
    case .fastDepth: DOLConfigBridge.setGfxFastDepthCalc(v)
    case .pixelLighting: DOLConfigBridge.setGfxEnablePixelLighting(v)
    case .backendMT: DOLConfigBridge.setGfxBackendMultithreading(v)
    case .shaderCache: DOLConfigBridge.setGfxShaderCache(v)
    case .saveTexCache: DOLConfigBridge.setGfxSaveTextureCacheToState(v)
    case .preferVSForLines: DOLConfigBridge.setGfxPreferVSForLinePointExpansion(v)
    case .cpuCull: DOLConfigBridge.setGfxCpuCull(v)
    case .deferEfbInvalidation: DOLConfigBridge.setGfxHackEfbDeferInvalidation(v)
    }
  }
}
