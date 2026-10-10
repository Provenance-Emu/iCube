// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Hacks, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct GraphicsHacksView: View {
  @State private var state = GraphicsHacksState()

  var body: some View {
    SettingsLeafScreen(model: GraphicsHacksModelBuilder.make(state: state, apply: apply), title: L("Hacks"), sync: sync)
  }

  private func sync() {
    var s = GraphicsHacksState()
    s.textureCacheSamples = GraphicsHacksState.normalizedTextureCacheSamples(DOLConfigBridge.gfxSafeTextureCacheColorSamples())
    s.bboxEnabled = DOLConfigBridge.gfxHackBboxEnable()
    s.bboxSyncMode = DOLConfigBridge.gfxBboxSyncMode()
    s.backendSupportsBbox = DOLConfigBridge.gfxBackendSupportsBoundingBox()
    s.efbAccess = DOLConfigBridge.gfxHackEfbAccessEnable()
    s.skipEfbToRam = DOLConfigBridge.gfxHackSkipEfbCopyToRam()
    s.skipXfbToRam = DOLConfigBridge.gfxHackSkipXfbCopyToRam()
    s.immediateXfb = DOLConfigBridge.gfxHackImmediateXfb()
    s.copyEfbScaled = DOLConfigBridge.gfxHackCopyEfbScaled()
    s.earlyXfbOutput = DOLConfigBridge.gfxHackEarlyXfbOutput()
    s.skipDuplicateXFBs = DOLConfigBridge.gfxHackSkipDuplicateXFBs()
    s.efbFormatChanges = DOLConfigBridge.gfxHackEfbEmulateFormatChanges()
    s.vertexRounding = DOLConfigBridge.gfxHackVertexRounding()
    s.forceProgressive = DOLConfigBridge.gfxHackForceProgressive()
    s.deferEfbCopies = DOLConfigBridge.gfxHackDeferEfbCopies()
    s.viSkipMode = DOLConfigBridge.gfxHackViSkipMode()
    s.fastTextureSampling = DOLConfigBridge.gfxHackFastTextureSampling()
    s.fastMath = DOLConfigBridge.gfxHackFastMath()
    s.useComputeEfbXfb = DOLConfigBridge.gfxUseComputeEfbXfb()
    s.useComputeVertexDecode = DOLConfigBridge.gfxUseComputeVertexDecode()
    s.noMipmapping = DOLConfigBridge.gfxHackNoMipmapping()
    s.gpuEfbPeekResolve = DOLConfigBridge.gfxHackGpuEfbPeekResolve()
    s.viDecimateInterlace = DOLConfigBridge.gfxHackViDecimateInterlace()
    state = s
  }

  private func apply(_ change: GraphicsHacksChange) {
    switch change {
    case .textureCacheSamples(let v): state.textureCacheSamples = v; DOLConfigBridge.setGfxSafeTextureCacheColorSamples(v)
    case .bboxEnabled(let v): state.bboxEnabled = v; DOLConfigBridge.setGfxHackBboxEnable(v)
    case .bboxSyncMode(let v): state.bboxSyncMode = v; DOLConfigBridge.setGfxBboxSyncMode(v)
    case .efbAccess(let v): state.efbAccess = v; DOLConfigBridge.setGfxHackEfbAccessEnable(v)
    case .skipEfbToRam(let v): state.skipEfbToRam = v; DOLConfigBridge.setGfxHackSkipEfbCopyToRam(v)
    case .skipXfbToRam(let v): state.skipXfbToRam = v; DOLConfigBridge.setGfxHackSkipXfbCopyToRam(v)
    case .immediateXfb(let v): state.immediateXfb = v; DOLConfigBridge.setGfxHackImmediateXfb(v)
    case .copyEfbScaled(let v): state.copyEfbScaled = v; DOLConfigBridge.setGfxHackCopyEfbScaled(v)
    case .earlyXfbOutput(let v): state.earlyXfbOutput = v; DOLConfigBridge.setGfxHackEarlyXfbOutput(v)
    case .skipDuplicateXFBs(let v): state.skipDuplicateXFBs = v; DOLConfigBridge.setGfxHackSkipDuplicateXFBs(v)
    case .efbFormatChanges(let v): state.efbFormatChanges = v; DOLConfigBridge.setGfxHackEfbEmulateFormatChanges(v)
    case .vertexRounding(let v): state.vertexRounding = v; DOLConfigBridge.setGfxHackVertexRounding(v)
    case .forceProgressive(let v): state.forceProgressive = v; DOLConfigBridge.setGfxHackForceProgressive(v)
    case .deferEfbCopies(let v): state.deferEfbCopies = v; DOLConfigBridge.setGfxHackDeferEfbCopies(v)
    case .viSkipMode(let v): state.viSkipMode = v; DOLConfigBridge.setGfxHackViSkipMode(v)
    case .fastTextureSampling(let v): state.fastTextureSampling = v; DOLConfigBridge.setGfxHackFastTextureSampling(v)
    case .fastMath(let v): state.fastMath = v; DOLConfigBridge.setGfxHackFastMath(v)
    case .useComputeEfbXfb(let v): state.useComputeEfbXfb = v; DOLConfigBridge.setGfxUseComputeEfbXfb(v)
    case .useComputeVertexDecode(let v): state.useComputeVertexDecode = v; DOLConfigBridge.setGfxUseComputeVertexDecode(v)
    case .noMipmapping(let v): state.noMipmapping = v; DOLConfigBridge.setGfxHackNoMipmapping(v)
    case .gpuEfbPeekResolve(let v): state.gpuEfbPeekResolve = v; DOLConfigBridge.setGfxHackGpuEfbPeekResolve(v)
    case .viDecimateInterlace(let v): state.viDecimateInterlace = v; DOLConfigBridge.setGfxHackViDecimateInterlace(v)
    }
  }
}
