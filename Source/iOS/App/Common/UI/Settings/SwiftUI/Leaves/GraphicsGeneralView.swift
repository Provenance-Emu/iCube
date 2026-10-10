// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Video, on the menu engine. `sync()` reads Config and UserDefaults into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct GraphicsGeneralView: View {
  @State private var state = GraphicsGeneralState()

  var body: some View {
    SettingsLeafScreen(model: GraphicsGeneralModelBuilder.make(state: state, apply: apply), title: L("Video"), sync: sync)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = GraphicsGeneralState()
    #if !os(iOS)
    s.isIOS = false
    #endif
    // Display only: a stored backend that Config disagrees with is shown, never written back from here.
    s.backend = GraphicsBackend.from(key: GraphicsGeneralState.effectiveBackendKey(defaults: defaults.string(forKey: GraphicsGeneralDefaultsKey.backend), config: DOLConfigBridge.gfxBackend()))
    s.vSync = DOLConfigBridge.gfxVSync()
    s.aspect = AspectRatio.from(raw: DOLConfigBridge.gfxAspectRatio())
    s.asyncPresent = DOLConfigBridge.gfxAsyncPresent()
    s.autoIR = DOLConfigBridge.gfxAutoIREnable()
    s.showAutoIrOSD = DOLConfigBridge.gfxAutoIRShowOSD()
    s.targetFPS = TargetFPS.from(value: DOLConfigBridge.gfxAutoIRTargetFPS())
    s.minScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMinScale())
    s.maxScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMaxScale())
    s.shaderType = ShaderCompileType.from(raw: DOLConfigBridge.gfxShaderCompilationMode())
    s.compileBeforeStart = DOLConfigBridge.gfxWaitForShadersBeforeStarting()
    s.tripleBuffering = defaults.object(forKey: GraphicsGeneralDefaultsKey.tripleBuffering) as? Bool ?? true
    s.forceScaleOneNonProMotion = defaults.bool(forKey: GraphicsGeneralDefaultsKey.forceScaleOne)
    s.overscanFullscreen = defaults.bool(forKey: GraphicsGeneralDefaultsKey.overscanFullscreen)
    s.frameCap = defaults.integer(forKey: GraphicsGeneralDefaultsKey.frameCap)
    s.instantReplay = defaults.bool(forKey: GraphicsGeneralDefaultsKey.instantReplay)
    s.saveClipsToPhotos = defaults.bool(forKey: GraphicsGeneralDefaultsKey.saveToPhotos)
    s.saveOnlyToPhotos = defaults.bool(forKey: GraphicsGeneralDefaultsKey.saveOnlyPhotos)
    s.clipSeconds = GraphicsGeneralState.storedClipSeconds(defaults.integer(forKey: GraphicsGeneralDefaultsKey.clipSeconds))
    state = s
  }

  private func apply(_ change: GraphicsGeneralChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .backend(let v):
      state.backend = v
      DOLConfigBridge.setGfxBackend(v.backendKey)
      defaults.set(v.backendKey, forKey: GraphicsGeneralDefaultsKey.backend)
    case .aspect(let v): state.aspect = v; DOLConfigBridge.setGfxAspectRatio(v.aspectRaw)
    case .vSync(let v): state.vSync = v; DOLConfigBridge.setGfxVSync(v)
    case .showAutoIrOSD(let v): state.showAutoIrOSD = v; DOLConfigBridge.setGfxAutoIRShowOSD(v)
    case .tripleBuffering(let v): state.tripleBuffering = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.tripleBuffering)
    case .forceScaleOneNonProMotion(let v): state.forceScaleOneNonProMotion = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.forceScaleOne)
    case .overscanFullscreen(let v): state.overscanFullscreen = v; TVEmulationBridge.setOverscanFullscreenEnabled(v)
    case .asyncPresent(let v): state.asyncPresent = v; DOLConfigBridge.setGfxAsyncPresent(v)
    case .autoIR(let v): state.autoIR = v; DOLConfigBridge.setGfxAutoIREnable(v)
    case .targetFPS(let v): state.targetFPS = v; DOLConfigBridge.setGfxAutoIRTargetFPS(v.fpsValue)
    case .minScale(let v): state.minScale = v; DOLConfigBridge.setGfxAutoIRMinScale(v.scaleValue)
    case .maxScale(let v): state.maxScale = v; DOLConfigBridge.setGfxAutoIRMaxScale(v.scaleValue)
    // The scene delegate applies the cap where supported.
    case .frameCap(let v): state.frameCap = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.frameCap)
    case .instantReplay(let v): state.instantReplay = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.instantReplay)
    case .saveClipsToPhotos(let v): state.saveClipsToPhotos = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.saveToPhotos)
    case .saveOnlyToPhotos(let v): state.saveOnlyToPhotos = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.saveOnlyPhotos)
    case .clipSeconds(let v): state.clipSeconds = v; defaults.set(v, forKey: GraphicsGeneralDefaultsKey.clipSeconds)
    case .shaderType(let v): state.shaderType = v; DOLConfigBridge.setGfxShaderCompilationMode(v.modeRaw)
    case .compileBeforeStart(let v): state.compileBeforeStart = v; DOLConfigBridge.setGfxWaitForShadersBeforeStarting(v)
    }
  }
}
