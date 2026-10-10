// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

// MARK: - Graphics General (wired)

struct GraphicsGeneralView: View {
  @State private var backend: GraphicsBackend = .metal
  @State private var aspect: AspectRatio = .auto
  @State private var vSync: Bool = false
  @State private var showAutoIrOSD: Bool = false
  @State private var tripleBuffering: Bool = false // NSUserDefaults-backed
  @State private var forceScaleOneNonProMotion: Bool = false // NSUserDefaults-backed
  @State private var overscanFullscreen: Bool = false // NSUserDefaults-backed
  @State private var asyncPresent: Bool = false
  @State private var autoIR: Bool = false
  @State private var targetFPS: TargetFPS = .fps60
  @State private var minScale: InternalScale = .x1_0
  @State private var maxScale: InternalScale = .x2_0
  @State private var frameCap: Int = 0
#if os(iOS)
  @State private var instantReplay: Bool = false
  @State private var clipSeconds: Int = 15
#endif

  // Shader compilation. Default Hybrid Ubershaders(2) — matches the core default (GraphicsSettings.cpp) and the
  // iCube reset target (DOLConfigBridge.mm resetGameplayConfigKeys).
  @State private var shaderType: ShaderCompileType = .specialized
  @State private var compileBeforeStart: Bool = true

  var body: some View {
    List {
      Section {
        settingsNavCaption(
          destination: GraphicsBackendPickerView(selected: $backend.onSet { newBackend in
            DOLConfigBridge.setGfxBackend(newBackend.backendKey)
            UserDefaults.standard.set(newBackend.backendKey, forKey: "ui_gfx_backend")
          }),
          L("Renderer used to draw frames. Metal is the native, fastest path on this device; Vulkan runs via MoltenVK; OpenGL is the slow legacy fallback. Leave on Metal.")
        ) {
          Text("\(L("Backend")): \(backend.label)")
        }
        settingsNavCaption(
          destination: GraphicsAspectRatioView(selected: $aspect.onSet { DOLConfigBridge.setGfxAspectRatio($0.aspectRaw) }),
          L("Shape of the picture. Auto matches the game's native ratio; 4:3 and 16:9 force a fixed shape; Stretch fills the screen and may distort.")
        ) {
          Text("\(L("Aspect Ratio")): \(aspect.label)")
        }
        captionRow(
          Toggle(L("V-Sync"), isOn: $vSync.onSet { newValue in DOLConfigBridge.setGfxVSync(newValue) }),
          L("Syncs presentation to the display refresh to remove tearing. On iOS the compositor already syncs, so this has little effect; leave ON."))
        captionRow(
          Toggle(L("Show Auto IR OSD"), isOn: $showAutoIrOSD.onSet { newValue in DOLConfigBridge.setGfxAutoIRShowOSD(newValue) }),
          L("Shows the resolution Auto Internal Resolution picks each frame as an on-screen overlay. Diagnostic only."))
        captionRow(
          Toggle(L("Triple Buffering"), isOn: $tripleBuffering.onSet { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_triple_buffering") }),
          L("Adds a third frame buffer to smooth pacing at a small latency/memory cost. Default ON; turn off only if you want minimum latency."))
        captionRow(
          Toggle(L("Force scale 1.0 on non‑ProMotion"), isOn: $forceScaleOneNonProMotion.onSet { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_force_scale_one_non_promo") }),
          L("On non-ProMotion (non-120 Hz) devices, render at a 1.0 backing scale to save GPU/bandwidth. Helps on older devices; leave OFF on ProMotion displays."))
        captionRow(
          Toggle(L("Full screen (disable overscan compensation)"), isOn: $overscanFullscreen.onSet { newValue in
            TVEmulationBridge.setOverscanFullscreenEnabled(newValue)
          }),
          L("Disables system overscan scaling for edge-to-edge output. On iOS this applies when an external display is connected; on Apple TV it affects the main TV. Default OFF keeps safe margins; turn ON if you see letterboxing, OFF if edges clip."))
        captionRow(
          Toggle(L("Asynchronous Present"), isOn: $asyncPresent.onSet { newValue in DOLConfigBridge.setGfxAsyncPresent(newValue) }),
          L("Presents finished frames on a background thread so the CPU thread isn't blocked waiting on the display. Helps on the CPU-bound interpreter; default ON."))
        captionRow(
          Toggle(L("Enable Auto Internal Resolution"), isOn: $autoIR.onSet { newValue in DOLConfigBridge.setGfxAutoIREnable(newValue) }),
          L("Dynamically scales internal resolution between Min and Max to hold the Target FPS. Useful when scenes are GPU-bound; has no benefit when the CPU is the limit (the usual case on iCube)."))
        settingsNavCaption(
          destination: GraphicsTargetFPSView(selected: $targetFPS.onSet { DOLConfigBridge.setGfxAutoIRTargetFPS($0.fpsValue) }),
          L("Frame rate Auto Internal Resolution tries to hold by adjusting the render scale. Only used when Auto IR is on.")
        ) {
          Text("\(L("Target FPS")): \(targetFPS.label)")
        }
        settingsNavCaption(
          destination: GraphicsMinScaleView(selected: $minScale.onSet { DOLConfigBridge.setGfxAutoIRMinScale($0.scaleValue) }),
          L("Lowest internal resolution Auto IR will drop to when struggling. 1x is native GameCube/Wii resolution.")
        ) {
          Text("\(L("Min Scale")): \(minScale.label)")
        }
        settingsNavCaption(
          destination: GraphicsMaxScaleView(selected: $maxScale.onSet { DOLConfigBridge.setGfxAutoIRMaxScale($0.scaleValue) }),
          L("Highest internal resolution Auto IR will raise to when there's headroom. Higher looks sharper but costs GPU.")
        ) {
          Text("\(L("Max Scale")): \(maxScale.label)")
        }
#if os(iOS)
        captionRow(
          Picker(L("Frame Rate Cap"), selection: $frameCap.onSet { v in
            UserDefaults.standard.set(v, forKey: "ui_frame_cap")
            // Application is handled by the scene delegate where supported
          }) {
            Text(L("System Default")).tag(0)
            Text("30").tag(30)
            Text("60").tag(60)
            Text("90").tag(90)
            Text("120").tag(120)
          },
          L("Caps the display refresh the app requests. System Default lets the OS decide; lower caps can save power on the CPU-bound path."))
#endif
      }

#if os(iOS)
      Section(header: Text(L("Recording"))) {
        captionRow(
          Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay.onSet { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") }),
          L("Continuously buffers gameplay so you can save the last few seconds. May reduce performance; keep off on older devices."))
        captionRow(
          Toggle(L("Save Clips to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_to_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_to_photos") })),
          L("Also copy saved replay clips into your Photos library."))
        captionRow(
          Toggle(L("Save Only to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_only_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_only_photos") })),
          L("Save clips to Photos only, skipping the app's own storage."))
        captionRow(
          Picker(L("Clip Length"), selection: $clipSeconds.onSet { v in UserDefaults.standard.set(v, forKey: "replaykit_clip_seconds") }) {
            Text("5s").tag(5)
            Text("10s").tag(10)
            Text("15s").tag(15)
            Text("30s").tag(30)
          },
          L("How many seconds of gameplay each instant-replay clip captures."))
      }
#endif

      Section(header: Text(L("Shader Compilation"))) {
        settingsNavCaption(
          destination: GraphicsShaderTypeView(selected: $shaderType.onSet { DOLConfigBridge.setGfxShaderCompilationMode($0.modeRaw) }),
          L("Hybrid Ubershaders (default) draw new materials with a generic shader while the exact one compiles in the background, so nothing stutters on first sight. Specialized has the lowest GPU cost but can hitch when a shader is new. Exclusive Ubershaders always use the generic shader and measured about 5% slower.")
        ) {
          Text("\(L("Type")): \(shaderType.label)")
        }
        captionRow(
          Toggle(L("Compile shaders before starting"), isOn: $compileBeforeStart.onSet { newValue in DOLConfigBridge.setGfxWaitForShadersBeforeStarting(newValue) }),
          L("Pre-builds the shader cache before the game starts: longer initial load, smoother first run. Recommended ON."))
      }
    }
    .navigationTitle(L("General"))
    .configSynced { syncFromConfig() }
    .onAppear { frameCap = UserDefaults.standard.integer(forKey: "ui_frame_cap") }
#if os(iOS)
    .onAppear {
      instantReplay = UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled")
      let s = UserDefaults.standard.integer(forKey: "replaykit_clip_seconds"); clipSeconds = (s > 0 ? s : 15)
    }
#endif
  }

  /// Inline secondary-text description under a control. Forwards to the canonical
  /// file-scope `settingsCaption`.
  @ViewBuilder
  private func captionRow<Content: View>(_ content: Content, _ caption: String) -> some View {
    settingsCaption(content, caption)
  }

  private func syncFromConfig() {
    let keyFromConfig = DOLConfigBridge.gfxBackend()
    let keyFromDefaults = UserDefaults.standard.string(forKey: "ui_gfx_backend")
    let effectiveKey = (keyFromDefaults?.isEmpty == false) ? keyFromDefaults! : keyFromConfig
    backend = GraphicsBackend.from(key: effectiveKey)
    if effectiveKey != keyFromConfig { DOLConfigBridge.setGfxBackend(effectiveKey) }
    vSync = DOLConfigBridge.gfxVSync()
    aspect = AspectRatio.from(raw: DOLConfigBridge.gfxAspectRatio())
    asyncPresent = DOLConfigBridge.gfxAsyncPresent()
    autoIR = DOLConfigBridge.gfxAutoIREnable()
    showAutoIrOSD = DOLConfigBridge.gfxAutoIRShowOSD()
    targetFPS = TargetFPS.from(value: DOLConfigBridge.gfxAutoIRTargetFPS())
    minScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMinScale())
    maxScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMaxScale())
    shaderType = ShaderCompileType.from(raw: DOLConfigBridge.gfxShaderCompilationMode())
    compileBeforeStart = DOLConfigBridge.gfxWaitForShadersBeforeStarting()
    // NSUserDefaults-backed toggles
    if UserDefaults.standard.object(forKey: "gfx_triple_buffering") != nil { tripleBuffering = UserDefaults.standard.bool(forKey: "gfx_triple_buffering") } else { tripleBuffering = true }
    forceScaleOneNonProMotion = UserDefaults.standard.bool(forKey: "gfx_force_scale_one_non_promo")
    overscanFullscreen = UserDefaults.standard.bool(forKey: "gfx_overscan_fullscreen")
  }
}

// MARK: - Graphics enums and pickers (tvOS-friendly)

struct GraphicsBackendPickerView: View {
  @Binding var selected: GraphicsBackend
  var body: some View {
    List {
      ForEach(Array(GraphicsBackend.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxBackend(value.backendKey) }
      }
    }
    .navigationTitle(L("Backend"))
  }
}

struct GraphicsAspectRatioView: View {
  @Binding var selected: AspectRatio
  var body: some View {
    List {
      ForEach(Array(AspectRatio.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAspectRatio(value.aspectRaw) }
      }
    }
    .navigationTitle(L("Aspect Ratio"))
  }
}

struct GraphicsTargetFPSView: View {
  @Binding var selected: TargetFPS
  var body: some View {
    List {
      ForEach(Array(TargetFPS.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRTargetFPS(value.fpsValue) }
      }
    }
    .navigationTitle(L("Target FPS"))
    .toolbar { HelpButton(helpKey:
                            "Controls how fast emulation runs relative to the original hardware.<br><br>Values higher than 100% will emulate faster than the original hardware can run, if your hardware is able to keep up. Values lower than 100% will slow emulation instead. Unlimited will emulate as fast as your hardware is able to.<br><br><dolphin_emphasis>If unsure, select 100%.</dolphin_emphasis>") }
  }
}

struct GraphicsMinScaleView: View {
  @Binding var selected: InternalScale
  var body: some View {
    List {
      ForEach(Array(InternalScale.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRMinScale(value.scaleValue) }
      }
    }
    .navigationTitle(L("Min Scale"))
  }
}

struct GraphicsMaxScaleView: View {
  @Binding var selected: InternalScale
  var body: some View {
    List {
      ForEach(Array(InternalScale.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRMaxScale(value.scaleValue) }
      }
    }
    .navigationTitle(L("Max Scale"))
  }
}

struct GraphicsShaderTypeView: View {
  @Binding var selected: ShaderCompileType
  var body: some View {
    List {
      ForEach(Array(ShaderCompileType.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxShaderCompilationMode(value.modeRaw) }
      }
    }
    .navigationTitle(L("Shader Type"))
  }
}
