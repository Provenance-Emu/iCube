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

  // Shader compilation. Default Specialized(0) — matches the core default and the
  // iCube reset target (DOLConfigBridge.mm resetGameplayConfigKeys).
  @State private var shaderType: ShaderCompileType = .specialized
  @State private var compileBeforeStart: Bool = true

  var body: some View {
    List {
      Section {
        settingsNavCaption(
          destination: GraphicsBackendPickerView(selected: $backend),
          L("Renderer used to draw frames. Metal is the native, fastest path on this device; Vulkan runs via MoltenVK; OpenGL is the slow legacy fallback. Leave on Metal.")
        ) {
          Text("\(L("Backend")): \(backend.label)")
        }
        .onChange(of: backend) { _ in
          DOLConfigBridge.setGfxBackend(backend.backendKey)
          UserDefaults.standard.set(backend.backendKey, forKey: "ui_gfx_backend")
        }
        settingsNavCaption(
          destination: GraphicsAspectRatioView(selected: $aspect),
          L("Shape of the picture. Auto matches the game's native ratio; 4:3 and 16:9 force a fixed shape; Stretch fills the screen and may distort.")
        ) {
          Text("\(L("Aspect Ratio")): \(aspect.label)")
        }
        .onChange(of: aspect) { _ in DOLConfigBridge.setGfxAspectRatio(aspect.aspectRaw) }
        captionRow(
          Toggle(L("V-Sync"), isOn: $vSync)
            .onChange(of: vSync) { newValue in DOLConfigBridge.setGfxVSync(newValue) },
          L("Syncs presentation to the display refresh to remove tearing. On iOS the compositor already syncs, so this has little effect; leave ON."))
        captionRow(
          Toggle(L("Show Auto IR OSD"), isOn: $showAutoIrOSD)
            .onChange(of: showAutoIrOSD) { newValue in DOLConfigBridge.setGfxAutoIRShowOSD(newValue) },
          L("Shows the resolution Auto Internal Resolution picks each frame as an on-screen overlay. Diagnostic only."))
        captionRow(
          Toggle(L("Triple Buffering"), isOn: $tripleBuffering)
            .onChange(of: tripleBuffering) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_triple_buffering") },
          L("Adds a third frame buffer to smooth pacing at a small latency/memory cost. Default ON; turn off only if you want minimum latency."))
        captionRow(
          Toggle(L("Force scale 1.0 on non‑ProMotion"), isOn: $forceScaleOneNonProMotion)
            .onChange(of: forceScaleOneNonProMotion) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_force_scale_one_non_promo") },
          L("On non-ProMotion (non-120 Hz) devices, render at a 1.0 backing scale to save GPU/bandwidth. Helps on older devices; leave OFF on ProMotion displays."))
        captionRow(
          Toggle(L("Full screen (disable overscan compensation)"), isOn: $overscanFullscreen)
            .onChange(of: overscanFullscreen) { newValue in
              TVEmulationBridge.setOverscanFullscreenEnabled(newValue)
            },
          L("Disables system overscan scaling for edge-to-edge output. On iOS this applies when an external display is connected; on Apple TV it affects the main TV. Default OFF keeps safe margins; turn ON if you see letterboxing, OFF if edges clip."))
        captionRow(
          Toggle(L("Asynchronous Present"), isOn: $asyncPresent)
            .onChange(of: asyncPresent) { newValue in DOLConfigBridge.setGfxAsyncPresent(newValue) },
          L("Presents finished frames on a background thread so the CPU thread isn't blocked waiting on the display. Helps on the CPU-bound interpreter; default ON."))
        captionRow(
          Toggle(L("Enable Auto Internal Resolution"), isOn: $autoIR)
            .onChange(of: autoIR) { newValue in DOLConfigBridge.setGfxAutoIREnable(newValue) },
          L("Dynamically scales internal resolution between Min and Max to hold the Target FPS. Useful when scenes are GPU-bound; has no benefit when the CPU is the limit (the usual case on iCube)."))
        settingsNavCaption(
          destination: GraphicsTargetFPSView(selected: $targetFPS),
          L("Frame rate Auto Internal Resolution tries to hold by adjusting the render scale. Only used when Auto IR is on.")
        ) {
          Text("\(L("Target FPS")): \(targetFPS.label)")
        }
        .onChange(of: targetFPS) { _ in DOLConfigBridge.setGfxAutoIRTargetFPS(targetFPS.fpsValue) }
        settingsNavCaption(
          destination: GraphicsMinScaleView(selected: $minScale),
          L("Lowest internal resolution Auto IR will drop to when struggling. 1x is native GameCube/Wii resolution.")
        ) {
          Text("\(L("Min Scale")): \(minScale.label)")
        }
        .onChange(of: minScale) { _ in DOLConfigBridge.setGfxAutoIRMinScale(minScale.scaleValue) }
        settingsNavCaption(
          destination: GraphicsMaxScaleView(selected: $maxScale),
          L("Highest internal resolution Auto IR will raise to when there's headroom. Higher looks sharper but costs GPU.")
        ) {
          Text("\(L("Max Scale")): \(maxScale.label)")
        }
        .onChange(of: maxScale) { _ in DOLConfigBridge.setGfxAutoIRMaxScale(maxScale.scaleValue) }
#if os(iOS)
        captionRow(
          Picker(L("Frame Rate Cap"), selection: $frameCap) {
            Text(L("System Default")).tag(0)
            Text("30").tag(30)
            Text("60").tag(60)
            Text("90").tag(90)
            Text("120").tag(120)
          }
          .onChange(of: frameCap) { v in
            UserDefaults.standard.set(v, forKey: "ui_frame_cap")
            // Application is handled by the scene delegate where supported
          },
          L("Caps the display refresh the app requests. System Default lets the OS decide; lower caps can save power on the CPU-bound path."))
#endif
      }

#if os(iOS)
      Section(header: Text(L("Recording"))) {
        captionRow(
          Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
            .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") },
          L("Continuously buffers gameplay so you can save the last few seconds. May reduce performance; keep off on older devices."))
        captionRow(
          Toggle(L("Save Clips to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_to_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_to_photos") })),
          L("Also copy saved replay clips into your Photos library."))
        captionRow(
          Toggle(L("Save Only to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_only_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_only_photos") })),
          L("Save clips to Photos only, skipping the app's own storage."))
        captionRow(
          Picker(L("Clip Length"), selection: $clipSeconds) {
            Text("5s").tag(5)
            Text("10s").tag(10)
            Text("15s").tag(15)
            Text("30s").tag(30)
          }
          .onChange(of: clipSeconds) { v in UserDefaults.standard.set(v, forKey: "replaykit_clip_seconds") },
          L("How many seconds of gameplay each instant-replay clip captures."))
      }
#endif

      Section(header: Text(L("Shader Compilation"))) {
        settingsNavCaption(
          destination: GraphicsShaderTypeView(selected: $shaderType),
          L("Specialized (default) compiles each shader on first use — low GPU cost, may briefly stutter. Ubershader modes trade GPU power for fewer hitches. On the CPU-bound iCube path Specialized is recommended.")
        ) {
          Text("\(L("Type")): \(shaderType.label)")
        }
        .onChange(of: shaderType) { _ in DOLConfigBridge.setGfxShaderCompilationMode(shaderType.modeRaw) }
        captionRow(
          Toggle(L("Compile shaders before starting"), isOn: $compileBeforeStart)
            .onChange(of: compileBeforeStart) { newValue in DOLConfigBridge.setGfxWaitForShadersBeforeStarting(newValue) },
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

enum GraphicsBackend: CaseIterable { case metal, opengl, vulkan
  var label: String { switch self { case .metal: return L("Metal"); case .opengl: return L("OpenGL"); case .vulkan: return L("Vulkan") } }
  var backendKey: String { switch self { case .metal: return "Metal"; case .opengl: return "OGL"; case .vulkan: return "Vulkan" } }
  static func from(key: String) -> GraphicsBackend { switch key.lowercased() { case "ogl", "opengl": return .opengl; case "vulkan": return .vulkan; default: return .metal } }
}

enum AspectRatio: CaseIterable { case auto, stretch, _4_3, _16_9
  var label: String { switch self { case .auto: return L("Auto"); case .stretch: return L("Stretch to Window"); case ._4_3: return "4:3"; case ._16_9: return "16:9" } }
  var aspectRaw: Int { switch self { case .auto: return 0; case .stretch: return 3; case ._4_3: return 2; case ._16_9: return 1 } }
  static func from(raw: Int) -> AspectRatio { switch raw { case 1: return ._16_9; case 2: return ._4_3; case 3: return .stretch; default: return .auto } }
}

enum TargetFPS: CaseIterable { case unlimited, fps30, fps60, fps120
  var label: String { switch self { case .unlimited: return L("Unlimited"); case .fps30: return "30"; case .fps60: return "60"; case .fps120: return "120" } }
  var fpsValue: Int { switch self { case .unlimited: return 0; case .fps30: return 30; case .fps60: return 60; case .fps120: return 120 } }
  static func from(value: Int) -> TargetFPS { switch value { case 30: return .fps30; case 120: return .fps120; case 0: return .unlimited; default: return .fps60 } }
}

// Auto Internal Resolution min/max bounds. The core stores these as an integer EFB
// multiplier and clamps to >= 1 (AutoIRController.cpp), so only whole scales are valid.
// The old fractional options (0.5x/0.75x/1.25x/1.5x) all collapsed to 0 -> read back
// as 1.0x, i.e. they "self-reset"; they are dropped.
enum InternalScale: Int, CaseIterable { case x1_0 = 1, x2_0 = 2, x3_0 = 3, x4_0 = 4
  var label: String { switch self {
  case .x1_0: return "1x"
  case .x2_0: return "2x"
  case .x3_0: return "3x"
  case .x4_0: return "4x"
  }}
  var scaleValue: Int { rawValue }
  static func from(value: Int) -> InternalScale { InternalScale(rawValue: value) ?? .x1_0 }
}

// Mirrors Dolphin's ShaderCompilationMode (VideoConfig.h): Synchronous(0) is the
// "Specialized" mode in Dolphin's own UI; raw values must match the core 1:1 or the
// picker reads back a different option than it stored ("self-reset").
enum ShaderCompileType: CaseIterable { case specialized, exclusiveUber, hybridUber, skipDrawing
  var label: String { switch self {
  case .specialized: return L("Specialized")
  case .exclusiveUber: return L("Exclusive Ubershaders")
  case .hybridUber: return L("Hybrid Ubershaders")
  case .skipDrawing: return L("Skip Drawing")
  } }
  var modeRaw: Int { switch self { case .specialized: return 0; case .exclusiveUber: return 1; case .hybridUber: return 2; case .skipDrawing: return 3 } }
  static func from(raw: Int) -> ShaderCompileType { switch raw { case 1: return .exclusiveUber; case 2: return .hybridUber; case 3: return .skipDrawing; default: return .specialized } }
}

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

