// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsGeneralModelBuilder {
  static func make(state: GraphicsGeneralState, apply: @escaping (GraphicsGeneralChange) -> Void) -> MenuModel {
    var general = [
      SettingsRow.cycle("backend", L("Backend"), GraphicsBackend.allCases.map { ($0.label, $0) }, state.backend,
            L("Renderer used to draw frames. Metal is the native, fastest path on this device; Vulkan runs via MoltenVK; OpenGL is the slow legacy fallback. Leave on Metal."),
            set: { apply(.backend($0)) }),
      SettingsRow.cycle("aspect-ratio", L("Aspect Ratio"), AspectRatio.allCases.map { ($0.label, $0) }, state.aspect,
            L("Shape of the picture. Auto matches the game's native ratio; 4:3 and 16:9 force a fixed shape; Stretch fills the screen and may distort."),
            set: { apply(.aspect($0)) }),
      SettingsRow.toggle("vsync", L("V-Sync"), state.vSync,
             L("Syncs presentation to the display refresh to remove tearing. On iOS the compositor already syncs, so this has little effect; leave ON."),
             set: { apply(.vSync($0)) }),
      SettingsRow.toggle("auto-ir-osd", L("Show Auto IR OSD"), state.showAutoIrOSD,
             L("Shows the resolution Auto Internal Resolution picks each frame as an on-screen overlay. Diagnostic only."),
             set: { apply(.showAutoIrOSD($0)) }),
      SettingsRow.toggle("triple-buffering", L("Triple Buffering"), state.tripleBuffering,
             L("Adds a third frame buffer to smooth pacing at a small latency/memory cost. Default ON; turn off only if you want minimum latency."),
             set: { apply(.tripleBuffering($0)) }),
      SettingsRow.toggle("force-scale-one", L("Force scale 1.0 on non‑ProMotion"), state.forceScaleOneNonProMotion,
             L("On non-ProMotion (non-120 Hz) devices, render at a 1.0 backing scale to save GPU/bandwidth. Helps on older devices; leave OFF on ProMotion displays."),
             set: { apply(.forceScaleOneNonProMotion($0)) }),
      SettingsRow.toggle("overscan-fullscreen", L("Full screen (disable overscan compensation)"), state.overscanFullscreen,
             L("Disables system overscan scaling for edge-to-edge output. On iOS this applies when an external display is connected; on Apple TV it affects the main TV. Default OFF keeps safe margins; turn ON if you see letterboxing, OFF if edges clip."),
             set: { apply(.overscanFullscreen($0)) }),
      SettingsRow.toggle("async-present", L("Asynchronous Present"), state.asyncPresent,
             L("Presents finished frames on a background thread so the CPU thread isn't blocked waiting on the display. Helps on the CPU-bound interpreter; default ON."),
             set: { apply(.asyncPresent($0)) }),
      SettingsRow.toggle("auto-ir", L("Enable Auto Internal Resolution"), state.autoIR,
             L("Dynamically scales internal resolution between Min and Max to hold the Target FPS. Useful when scenes are GPU-bound; has no benefit when the CPU is the limit (the usual case on iCube)."),
             set: { apply(.autoIR($0)) }),
      SettingsRow.cycle("target-fps", L("Target FPS"), TargetFPS.allCases.map { ($0.label, $0) }, state.targetFPS,
            L("Frame rate Auto Internal Resolution tries to hold by adjusting the render scale. Only used when Auto IR is on."),
            set: { apply(.targetFPS($0)) }),
      SettingsRow.cycle("min-scale", L("Min Scale"), InternalScale.allCases.map { ($0.label, $0) }, state.minScale,
            L("Lowest internal resolution Auto IR will drop to when struggling. 1x is native GameCube/Wii resolution."),
            set: { apply(.minScale($0)) }),
      SettingsRow.cycle("max-scale", L("Max Scale"), InternalScale.allCases.map { ($0.label, $0) }, state.maxScale,
            L("Highest internal resolution Auto IR will raise to when there's headroom. Higher looks sharper but costs GPU."),
            set: { apply(.maxScale($0)) }),
    ]
    if state.isIOS {
      general.append(
        SettingsRow.cycle("frame-cap", L("Frame Rate Cap"), GraphicsGeneralState.options(GraphicsGeneralState.frameCapLadder, including: state.frameCap).map { (frameCapTitle($0), $0) }, state.frameCap,
              L("Caps the display refresh the app requests. System Default lets the OS decide; lower caps can save power on the CPU-bound path."),
              set: { apply(.frameCap($0)) }))
    }
    var sections = [MenuSection(id: "general", items: general)]

    if state.isIOS {
      sections.append(MenuSection(id: "recording", header: L("Recording"), items: [
        SettingsRow.toggle("instant-replay", L("Enable ReplayKit Instant Replay"), state.instantReplay,
               L("Continuously buffers gameplay so you can save the last few seconds. May reduce performance; keep off on older devices."),
               set: { apply(.instantReplay($0)) }),
        SettingsRow.toggle("save-clips-photos", L("Save Clips to Photos"), state.saveClipsToPhotos,
               L("Also copy saved replay clips into your Photos library."),
               set: { apply(.saveClipsToPhotos($0)) }),
        SettingsRow.toggle("save-only-photos", L("Save Only to Photos"), state.saveOnlyToPhotos,
               L("Save clips to Photos only, skipping the app's own storage."),
               set: { apply(.saveOnlyToPhotos($0)) }),
        SettingsRow.cycle("clip-length", L("Clip Length"), GraphicsGeneralState.options(GraphicsGeneralState.clipSecondsLadder, including: state.clipSeconds).map { (seconds($0), $0) }, state.clipSeconds,
              L("How many seconds of gameplay each instant-replay clip captures."),
              set: { apply(.clipSeconds($0)) }),
      ]))
    }

    sections.append(MenuSection(id: "shader-compilation", header: L("Shader Compilation"), items: [
      SettingsRow.cycle("shader-compile-type", L("Type"), ShaderCompileType.allCases.map { ($0.label, $0) }, state.shaderType,
            L("Hybrid Ubershaders (default) draw new materials with a generic shader while the exact one compiles in the background, so nothing stutters on first sight. Specialized has the lowest GPU cost but can hitch when a shader is new. Exclusive Ubershaders always use the generic shader and measured about 5% slower."),
            set: { apply(.shaderType($0)) }),
      SettingsRow.toggle("compile-before-start", L("Compile shaders before starting"), state.compileBeforeStart,
             L("Pre-builds the shader cache before the game starts: longer initial load, smoother first run. Recommended ON."),
             set: { apply(.compileBeforeStart($0)) }),
    ]))

    return MenuModel(sections: sections)
  }

  /// "5s"; the one place a clip length becomes a label.
  private static func seconds(_ value: Int) -> String { "\(value)s" }

  private static func frameCapTitle(_ cap: Int) -> String {
    cap == GraphicsGeneralState.systemDefaultFrameCap ? L("System Default") : "\(cap)"
  }
}
