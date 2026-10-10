// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Enhancements, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct GraphicsEnhancementsView: View {
  @State private var state = GraphicsEnhancementsState()

  var body: some View {
    SettingsLeafScreen(model: GraphicsEnhancementsModelBuilder.make(state: state, apply: apply), title: L("Enhancements"), sync: sync)
  }

  private func sync() {
    var s = GraphicsEnhancementsState()
    s.efbMaxScale = max(1, DOLConfigBridge.gfxEfbMaxScale())
    // The user's own scale (Base), never an Auto-IR / thermal CurrentRun override: this row edits Base.
    s.efbScale = DOLConfigBridge.gfxEfbScaleBase()
    s.efbOverride = DOLConfigBridge.efbScaleOverride()
    s.anisotropy = GraphicsEnhancementsState.normalizedAnisotropy(DOLConfigBridge.gfxEnhanceAnisotropySamples())
    s.msaa = GraphicsEnhancementsState.normalizedMsaa(DOLConfigBridge.gfxMsaa())
    s.ssaa = DOLConfigBridge.gfxSsaa()
    s.outputResampling = DOLConfigBridge.gfxEnhanceOutputResampling()
    s.trueColor = DOLConfigBridge.gfxEnhanceForceTrueColor()
    s.disableCopyFilter = DOLConfigBridge.gfxEnhanceDisableCopyFilter()
    s.widescreenHack = DOLConfigBridge.gfxWidescreenHack()
    s.disableFog = DOLConfigBridge.gfxDisableFog()
    s.gpuTextureDecoding = DOLConfigBridge.gfxEnableGPUTextureDecoding()
    s.arbitraryMipmapDetection = DOLConfigBridge.gfxEnhanceArbitraryMipmapDetection()
    s.arbitraryMipmapThreshold = Double(DOLConfigBridge.gfxEnhanceArbitraryMipmapDetectionThreshold())
    s.hdrOutput = DOLConfigBridge.gfxEnhanceHDROutput()
    state = s
  }

  private func apply(_ change: GraphicsEnhancementsChange) {
    // Decided against the snapshot as it was before this change.
    let effects = GraphicsEnhancementsState.sideEffects(of: change, in: state)
    switch change {
    case .efbScale(let v): state.efbScale = v; DOLConfigBridge.setGfxEfbScale(v)
    case .anisotropy(let v): state.anisotropy = v; DOLConfigBridge.setGfxEnhanceAnisotropySamples(v)
    case .msaa(let v): state.msaa = v; DOLConfigBridge.setGfxMsaa(v)
    case .ssaa(let v): state.ssaa = v; DOLConfigBridge.setGfxSsaa(v)
    case .outputResampling(let v): state.outputResampling = v; DOLConfigBridge.setGfxEnhanceOutputResampling(v)
    case .trueColor(let v): state.trueColor = v; DOLConfigBridge.setGfxEnhanceForceTrueColor(v)
    case .disableCopyFilter(let v): state.disableCopyFilter = v; DOLConfigBridge.setGfxEnhanceDisableCopyFilter(v)
    case .widescreenHack(let v): state.widescreenHack = v; DOLConfigBridge.setGfxWidescreenHack(v)
    case .hdrOutput(let v): state.hdrOutput = v; DOLConfigBridge.setGfxEnhanceHDROutput(v)
    case .gpuTextureDecoding(let v): state.gpuTextureDecoding = v; DOLConfigBridge.setGfxEnableGPUTextureDecoding(v)
    case .disableFog(let v): state.disableFog = v; DOLConfigBridge.setGfxDisableFog(v)
    case .arbitraryMipmapDetection(let v): state.arbitraryMipmapDetection = v; DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetection(v)
    case .arbitraryMipmapThreshold(let v): state.arbitraryMipmapThreshold = v; DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float(v))
    }
    for effect in effects {
      switch effect {
      case .autoIROff: DOLConfigBridge.setGfxAutoIREnable(false)
      case .clearSSAA: state.ssaa = false; DOLConfigBridge.setGfxSsaa(false)
      }
    }
  }
}
