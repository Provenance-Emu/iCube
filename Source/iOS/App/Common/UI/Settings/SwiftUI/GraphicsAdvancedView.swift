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

struct GraphicsAdvancedView: View {
  @State private var fastDepth: Bool = true
  @State private var pixelLighting: Bool = false
  @State private var backendMT: Bool = true
  @State private var shaderCache: Bool = true
  @State private var saveTexCache: Bool = false
  @State private var preferVSForLines: Bool = false
  @State private var cpuCull: Bool = false
  // Performance Statistics
  @State private var showFPS: Bool = false
  @State private var showVPS: Bool = false
  @State private var showSpeed: Bool = false
  @State private var showFrameTimes: Bool = false
  @State private var showVBlankTimes: Bool = false
  @State private var showGraphs: Bool = false
  @State private var logRenderTime: Bool = false
  @State private var speedColors: Bool = false
  // Debugging
  @State private var overlayStats: Bool = false
  @State private var validationLayer: Bool = false
  // Utility (Custom Textures / Mods / VRAM copy)
  @State private var hiresTextures: Bool = false
  @State private var prefetchTextures: Bool = false
  @State private var disableEfbToVRAM: Bool = false
  @State private var graphicsMods: Bool = false
  // Misc
  @State private var cropPicture: Bool = false
  @State private var progressiveScan: Bool = false
  // Shader Threads
  @State private var compilerThreads: Int = 1
  @State private var precompilerThreads: Int = 1
  @State private var maxThreads: Int = 2
  // Experimental
  @State private var deferEfbInvalidation: Bool = false
  // Metal present/upload strategy (TriState: 0=Off, 1=On, 2=Auto)
  @State private var usePresentDrawable: Int = 2
  @State private var manuallyUploadBuffers: Int = 2
  var body: some View {
    List {
      Section(header: Text(L("Performance Statistics")), footer: Text(L("These overlays can also be toggled in-game from the pause menu."))) {
        settingsCaption(
          Toggle(L("Show FPS"), isOn: $showFPS).onChange(of: showFPS) { _ in DOLConfigBridge.setGfxShowFPS(showFPS) },
          L("Frames per second actually presented to the display."))
        settingsCaption(
          Toggle(L("Show VPS"), isOn: $showVPS).onChange(of: showVPS) { _ in DOLConfigBridge.setGfxShowVPS(showVPS) },
          L("Emulated video interrupts per second — the game's internal frame rate."))
        settingsCaption(
          Toggle(L("Show Speed"), isOn: $showSpeed).onChange(of: showSpeed) { _ in DOLConfigBridge.setGfxShowSpeed(showSpeed) },
          L("Emulation speed as a percentage of full speed."))
        settingsCaption(
          Toggle(L("Show Frame Times"), isOn: $showFrameTimes).onChange(of: showFrameTimes) { _ in DOLConfigBridge.setGfxShowFTimes(showFrameTimes) },
          L("Per-frame render time in milliseconds. Useful for spotting hitches."))
        settingsCaption(
          Toggle(L("Show VBlank Times"), isOn: $showVBlankTimes).onChange(of: showVBlankTimes) { _ in DOLConfigBridge.setGfxShowVTimes(showVBlankTimes) },
          L("Time between emulated vertical-blank interrupts."))
        settingsCaption(
          Toggle(L("Show Graphs"), isOn: $showGraphs).onChange(of: showGraphs) { _ in DOLConfigBridge.setGfxShowGraphs(showGraphs) },
          L("Draws the timing stats as live graphs instead of numbers."))
        settingsCaption(
          Toggle(L("Log Render Time to File"), isOn: $logRenderTime).onChange(of: logRenderTime) { _ in DOLConfigBridge.setGfxLogRenderTimeToFile(logRenderTime) },
          L("Writes per-frame render times to a log file for offline analysis."))
        settingsCaption(
          Toggle(L("Speed Colors"), isOn: $speedColors).onChange(of: speedColors) { _ in DOLConfigBridge.setGfxShowSpeedColors(speedColors) },
          L("Color-codes the speed readout (green = full speed, red = slow)."))
      }

      Section(header: Text(L("Debugging"))) {
        settingsCaption(
          Toggle(L("Overlay Stats"), isOn: $overlayStats).onChange(of: overlayStats) { _ in DOLConfigBridge.setGfxOverlayStats(overlayStats) },
          L("Detailed rendering statistics overlay for developers."))
        settingsCaption(
          Toggle(L("API Validation Layer"), isOn: $validationLayer).onChange(of: validationLayer) { _ in DOLConfigBridge.setGfxEnableValidationLayer(validationLayer) },
          L("Extra graphics-API error checking. For debugging only — reduces performance. Leave off."))
      }

      Section(header: Text(L("Shader Threads"))) {
        settingsCaption(
          HStack {
            Text(L("Compiler Threads"))
            Spacer()
#if os(tvOS)
            TVIntStepper(value: $compilerThreads, range: 1...maxThreads, step: 1)
#else
            Stepper(value: $compilerThreads, in: 1...maxThreads) { Text("\(compilerThreads)") }
#endif
          }
          .onChange(of: compilerThreads) { v in DOLConfigBridge.setGfxShaderCompilerThreads(v) },
          L("CPU threads used to compile shaders on demand. More can reduce stutter but competes with the emulated CPU. 2–4 is a good range."))
        settingsCaption(
          HStack {
            Text(L("Precompiler Threads"))
            Spacer()
#if os(tvOS)
            TVIntStepper(value: $precompilerThreads, range: 1...maxThreads, step: 1)
#else
            Stepper(value: $precompilerThreads, in: 1...maxThreads) { Text("\(precompilerThreads)") }
#endif
          }
          .onChange(of: precompilerThreads) { v in DOLConfigBridge.setGfxShaderPrecompilerThreads(v) },
          L("Threads used to pre-build shaders before a game starts."))
      }

      Section(header: Text(L("Utility"))) {
        settingsCaption(
          Toggle(L("Load Custom Textures"), isOn: $hiresTextures).onChange(of: hiresTextures) { _ in DOLConfigBridge.setGfxHiresTextures(hiresTextures) },
          L("Loads installed high-resolution texture packs in place of the originals."))
        settingsCaption(
          Toggle(L("Prefetch Custom Textures"), isOn: $prefetchTextures)
            .disabled(!hiresTextures)
            .onChange(of: prefetchTextures) { _ in DOLConfigBridge.setGfxCacheHiresTextures(prefetchTextures) },
          L("Loads all custom textures into memory up front for smoother play, at higher memory use."))
        settingsCaption(
          Toggle(L("Disable EFB Copy to VRAM"), isOn: $disableEfbToVRAM).onChange(of: disableEfbToVRAM) { _ in DOLConfigBridge.setGfxHackDisableCopyToVRAM(disableEfbToVRAM) },
          L("Forces framebuffer copies through RAM instead of VRAM. Slower; only for rare compatibility cases."))
        settingsCaption(
          Toggle(L("Enable Graphics Mods"), isOn: $graphicsMods).onChange(of: graphicsMods) { _ in DOLConfigBridge.setGfxModsEnable(graphicsMods) },
          L("Enables community-created graphics mods for supported games."))
      }

      Section(header: Text(L("Misc"))) {
        settingsCaption(
          Toggle(L("Crop"), isOn: $cropPicture).onChange(of: cropPicture) { _ in DOLConfigBridge.setGfxCrop(cropPicture) },
          L("Crops the black borders some games render around the picture."))
        settingsCaption(
          Toggle(L("Progressive Scan"), isOn: $progressiveScan).onChange(of: progressiveScan) { _ in DOLConfigBridge.setSysconfProgressiveScan(progressiveScan) },
          L("Enables 480p progressive output for games that support it, reducing flicker."))
      }

      Section(header: Text(L("Rendering"))) {
        settingsCaption(
          Toggle(L("Fast Depth Calculation"), isOn: $fastDepth).onChange(of: fastDepth) { DOLConfigBridge.setGfxFastDepthCalc($0) },
          L("Uses a faster, less precise depth formula. Small speed win; can cause depth glitches in a few games. Recommended on."))
        settingsCaption(
          Toggle(L("Per-Pixel Lighting"), isOn: $pixelLighting).onChange(of: pixelLighting) { DOLConfigBridge.setGfxEnablePixelLighting($0) },
          L("Computes lighting per pixel for smoother shading, at a GPU cost. Off matches original hardware."))
        settingsCaption(
          Toggle(L("Backend Multithreading"), isOn: $backendMT).onChange(of: backendMT) { DOLConfigBridge.setGfxBackendMultithreading($0) },
          L("Lets the Metal video backend record/submit draw commands on a worker thread (host-side rendering optimization; unrelated to emulation threading)."))
        settingsCaption(
          Toggle(L("Enable Shader Cache"), isOn: $shaderCache).onChange(of: shaderCache) { DOLConfigBridge.setGfxShaderCache($0) },
          L("Saves compiled shaders to disk so they aren't rebuilt every launch. Recommended on."))
        settingsCaption(
          Toggle(L("Save Texture Cache to State"), isOn: $saveTexCache).onChange(of: saveTexCache) { DOLConfigBridge.setGfxSaveTextureCacheToState($0) },
          L("Includes the texture cache in save states for more accurate restores, at larger state files."))
        settingsCaption(
          Toggle(L("Prefer Vertex Shader for Line/Point Expansion"), isOn: $preferVSForLines).onChange(of: preferVSForLines) { DOLConfigBridge.setGfxPreferVSForLinePointExpansion($0) },
          L("Expands lines and points in a vertex shader instead of a geometry shader. Can be faster on some GPUs."))
        settingsCaption(
          Toggle(L("CPU Culling"), isOn: $cpuCull).onChange(of: cpuCull) { DOLConfigBridge.setGfxCpuCull($0) },
          L("Culls off-screen geometry on the CPU. Usually a net loss on the CPU-bound path; leave off unless GPU-limited."))
      }

      Section(header: Text(L("Experimental")), footer: Text(L("⚠️ Experimental — may cause instability or glitches in some games."))) {
        settingsCaption(
          Toggle(L("Defer EFB Cache Invalidation"), isOn: $deferEfbInvalidation).onChange(of: deferEfbInvalidation) { _ in DOLConfigBridge.setGfxHackEfbDeferInvalidation(deferEfbInvalidation) },
          L("Delays invalidating cached framebuffer copies. Can speed things up but may show stale graphics."))
        settingsNavCaption(
          destination: MetalTriStatePicker(selected: $usePresentDrawable, title: L("Use Present Drawable"),
                                            setter: { DOLConfigBridge.setGfxMtlUsePresentDrawable($0) }),
          L("Metal present path. Auto uses the presentDrawable path when VSync is active (correct for most). Force On/Off to A/B present latency vs stability.")
        ) {
          Text("\(L("Use Present Drawable")): \(metalTriStateLabel(usePresentDrawable))")
        }
        .onChange(of: usePresentDrawable) { DOLConfigBridge.setGfxMtlUsePresentDrawable($0) }
        settingsNavCaption(
          destination: MetalTriStatePicker(selected: $manuallyUploadBuffers, title: L("Manually Upload Buffers"),
                                            setter: { DOLConfigBridge.setGfxMtlManuallyUploadBuffers($0) }),
          L("Metal buffer upload strategy (managed vs shared). Auto detects unified memory and is correct on Apple Silicon; override only for benchmarking.")
        ) {
          Text("\(L("Manually Upload Buffers")): \(metalTriStateLabel(manuallyUploadBuffers))")
        }
        .onChange(of: manuallyUploadBuffers) { DOLConfigBridge.setGfxMtlManuallyUploadBuffers($0) }
      }
    }
    .navigationTitle(L("Advanced"))
    .configSynced { sync() }
  }
  private func metalTriStateLabel(_ v: Int) -> String { switch v { case 0: return L("Off"); case 1: return L("On"); default: return L("Auto") } }
  private func sync() {
    fastDepth = DOLConfigBridge.gfxFastDepthCalc()
    pixelLighting = DOLConfigBridge.gfxEnablePixelLighting()
    backendMT = DOLConfigBridge.gfxBackendMultithreading()
    shaderCache = DOLConfigBridge.gfxShaderCache()
    saveTexCache = DOLConfigBridge.gfxSaveTextureCacheToState()
    preferVSForLines = DOLConfigBridge.gfxPreferVSForLinePointExpansion()
    cpuCull = DOLConfigBridge.gfxCpuCull()
    // Performance Statistics
    showFPS = DOLConfigBridge.gfxShowFPS()
    showVPS = DOLConfigBridge.gfxShowVPS()
    showSpeed = DOLConfigBridge.gfxShowSpeed()
    showFrameTimes = DOLConfigBridge.gfxShowFTimes()
    showVBlankTimes = DOLConfigBridge.gfxShowVTimes()
    showGraphs = DOLConfigBridge.gfxShowGraphs()
    logRenderTime = DOLConfigBridge.gfxLogRenderTimeToFile()
    speedColors = DOLConfigBridge.gfxShowSpeedColors()
    // Debugging
    overlayStats = DOLConfigBridge.gfxOverlayStats()
    validationLayer = DOLConfigBridge.gfxEnableValidationLayer()
    // Utility
    hiresTextures = DOLConfigBridge.gfxHiresTextures()
    prefetchTextures = DOLConfigBridge.gfxCacheHiresTextures()
    disableEfbToVRAM = DOLConfigBridge.gfxHackDisableCopyToVRAM()
    graphicsMods = DOLConfigBridge.gfxModsEnable()
    // Misc
    cropPicture = DOLConfigBridge.gfxCrop()
    progressiveScan = DOLConfigBridge.sysconfProgressiveScan()
    // Shader threads
    let cores = max(2, ProcessInfo.processInfo.processorCount)
    maxThreads = max(1, cores - 1)
    let ct = DOLConfigBridge.gfxShaderCompilerThreads()
    compilerThreads = (ct <= 0) ? min(2, maxThreads) : ct
    let pt = DOLConfigBridge.gfxShaderPrecompilerThreads()
    precompilerThreads = (pt <= 0) ? min(2, maxThreads) : pt
    // Experimental
    deferEfbInvalidation = DOLConfigBridge.gfxHackEfbDeferInvalidation()
    usePresentDrawable = DOLConfigBridge.gfxMtlUsePresentDrawable()
    manuallyUploadBuffers = DOLConfigBridge.gfxMtlManuallyUploadBuffers()
  }
}

// NOTE: The per-port Type→Configure flow (ControllersPortView / ControllersTypePicker)
// was removed — ControllerSetupView's per-row Device picker now activates the port
// (no separate Type step) and "Customize Buttons…" drills into ControllersMappingView.

