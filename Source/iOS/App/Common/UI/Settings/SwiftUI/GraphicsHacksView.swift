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

struct GraphicsHacksView: View {
  @State private var efbAccess: Bool = false
  @State private var skipEfbToRam: Bool = true
  @State private var skipXfbToRam: Bool = true
  @State private var immediateXfb: Bool = false
  @State private var copyEfbScaled: Bool = true
  @State private var efbFormatChanges: Bool = false
  @State private var vertexRounding: Bool = false
  @State private var forceProgressive: Bool = true
  @State private var deferEfbCopies: Bool = true
  @State private var viSkipMode: Int = 2 // TriState::Auto on Apple
  @State private var fastTextureSampling: Bool = true
  @State private var fastMath: Bool = true
  @State private var useComputeEfbXfb: Bool = false
  @State private var useComputeVertexDecode: Bool = false
  @State private var noMipmapping: Bool = false
  @State private var earlyXfbOutput: Bool = true
  @State private var skipDuplicateXFBs: Bool = true
  @State private var viDecimateInterlace: Bool = false
  @State private var bboxEnabled: Bool = false
  @State private var bboxSyncMode: Int = 0 // 0=Latched (perf default), 1=Force Sync
  @State private var gpuEfbPeekResolve: Bool = false
  @State private var textureCacheSamples: Int = 128
  @State private var backendSupportsBbox: Bool = true
  @State private var helpMessage: String = ""
  @State private var showHelp: Bool = false

  /// Defer EFB Copies is unavailable when both EFB and XFB copies stay on the GPU (DolphinQt parity).
  private var deferEfbCopiesEnabled: Bool {
    !(skipEfbToRam && skipXfbToRam)
  }

  /// Skip Duplicate XFBs is redundant when Immediate XFB or VI Skip already handles presentation.
  private var skipDuplicateXFBsEnabled: Bool {
    !immediateXfb && viSkipMode == 0
  }

  var body: some View {
    List {
      Section(header: Text(L("General Hacks"))) {
        settingsNavCaption(
          destination: TextureCacheAccuracyPicker(selected: $textureCacheSamples),
          L("Adjusts how strictly the GPU tracks texture updates from RAM. Safer is slower but avoids garbled text in some games.")
        ) {
          Text("\(L("Texture Cache Accuracy")): \(textureCacheAccuracyLabel(textureCacheSamples))")
        }
        .onChange(of: textureCacheSamples) { DOLConfigBridge.setGfxSafeTextureCacheColorSamples($0) }
        settingsCaption(
          Toggle(L("Bounding Box Emulation"), isOn: $bboxEnabled)
            .disabled(!backendSupportsBbox)
            .onChange(of: bboxEnabled) { DOLConfigBridge.setGfxHackBboxEnable($0) },
          backendSupportsBbox
            ? L("Emulates GameCube/Wii bounding-box tests on the GPU. Required by some games; leave off unless needed.")
            : L("The current graphics backend does not support bounding box emulation on this device."))
        settingsNavCaption(
          destination: BBoxSyncModePicker(selected: $bboxSyncMode),
          L("How iCube delivers bounding-box values. Latched serves a 1-frame-stale snapshot with no CPU stall (faster). Force Sync blocks for exact same-frame values — try it if a game's bbox-driven effects (some 2D/UI culling) look wrong.")
        ) {
          Text("\(L("Bounding Box Sync")): \(bboxSyncLabel(bboxSyncMode))")
        }
        .disabled(!bboxEnabled || !backendSupportsBbox)
        .onChange(of: bboxSyncMode) { DOLConfigBridge.setGfxBboxSyncMode($0) }
        settingsCaption(
          Toggle(L("Enable EFB Access"), isOn: $efbAccess)
            .onChange(of: efbAccess) { DOLConfigBridge.setGfxHackEfbAccessEnable($0) },
          L("Lets the CPU read back the framebuffer. Required by some effects but costly; many games run fine and faster with it off."))
        settingsCaption(
          Toggle(L("Skip EFB Copy to RAM"), isOn: $skipEfbToRam)
            .onChange(of: skipEfbToRam) { DOLConfigBridge.setGfxHackSkipEfbCopyToRam($0) },
          L("Keeps embedded-framebuffer copies on the GPU instead of system RAM. Faster; breaks a few effects. Recommended on."))
        settingsCaption(
          Toggle(L("Skip XFB Copy to RAM"), isOn: $skipXfbToRam)
            .onChange(of: skipXfbToRam) { DOLConfigBridge.setGfxHackSkipXfbCopyToRam($0) },
          L("Keeps the external framebuffer on the GPU. Faster; can break games that read the final image."))
        settingsCaption(
          Toggle(L("Immediate XFB"), isOn: $immediateXfb)
            .onChange(of: immediateXfb) { DOLConfigBridge.setGfxHackImmediateXfb($0) },
          L("Presents frames the moment they're drawn — lower latency, but can cause flicker or tearing in some games."))
        settingsCaption(
          Toggle(L("Copy EFB Scaled"), isOn: $copyEfbScaled)
            .onChange(of: copyEfbScaled) { DOLConfigBridge.setGfxHackCopyEfbScaled($0) },
          L("Copies the framebuffer at the higher internal resolution rather than native. Keeps upscaled detail; recommended on."))
        settingsCaption(
          Toggle(L("Early XFB Output"), isOn: $earlyXfbOutput)
            .onChange(of: earlyXfbOutput) { DOLConfigBridge.setGfxHackEarlyXfbOutput($0) },
          L("Outputs the frame earlier in the pipeline for lower latency. Recommended on; turn off if a game shows glitches."))
        settingsCaption(
          Toggle(L("Skip Duplicate XFBs"), isOn: $skipDuplicateXFBs)
            .disabled(!skipDuplicateXFBsEnabled)
            .onChange(of: skipDuplicateXFBs) { DOLConfigBridge.setGfxHackSkipDuplicateXFBs($0) },
          skipDuplicateXFBsEnabled
            ? L("Avoids re-presenting identical frames, saving GPU work. Recommended on.")
            : L("Unavailable while Immediate XFB or VI Skip is enabled — duplicate frames are already handled."))
        settingsCaption(
          Toggle(L("Emulate EFB Format Changes"), isOn: $efbFormatChanges)
            .onChange(of: efbFormatChanges) { DOLConfigBridge.setGfxHackEfbEmulateFormatChanges($0) },
          L("Emulates pixel-format changes some games rely on. Needed for correct colors/effects in those games; small cost."))
        settingsCaption(
          Toggle(L("Vertex Rounding"), isOn: $vertexRounding)
            .onChange(of: vertexRounding) { DOLConfigBridge.setGfxHackVertexRounding($0) },
          L("Rounds vertex positions to reduce seams between tiles at higher resolutions. Only helps above 1x; leave off at 1x."))
        settingsCaption(
          Toggle(L("Force Progressive Scan"), isOn: $forceProgressive)
            .onChange(of: forceProgressive) { DOLConfigBridge.setGfxHackForceProgressive($0) },
          L("Forces 480p output where games allow it, for a cleaner image."))
        settingsCaption(
          Toggle(L("Defer EFB Copies"), isOn: $deferEfbCopies)
            .disabled(!deferEfbCopiesEnabled)
            .onChange(of: deferEfbCopies) { DOLConfigBridge.setGfxHackDeferEfbCopies($0) },
          deferEfbCopiesEnabled
            ? L("Batches framebuffer copies to reduce overhead. Faster in most games; recommended on.")
            : L("Unavailable while both EFB and XFB copies stay on the GPU — there is no RAM copy to defer."))
        settingsNavCaption(
          destination: ViSkipModePicker(selected: $viSkipMode),
          L("Skips video-interrupt frames to gain speed. Auto is the safe choice; On is more aggressive but can cause flicker.")
        ) {
          Text("\(L("VI Skip Mode")): \(viSkipLabel(viSkipMode))")
        }
        .onChange(of: viSkipMode) { DOLConfigBridge.setGfxHackViSkipMode($0) }
        settingsCaption(
          Toggle(L("Fast Texture Sampling"), isOn: $fastTextureSampling)
            .onChange(of: fastTextureSampling) { DOLConfigBridge.setGfxHackFastTextureSampling($0) },
          L("Uses faster, less precise texture sampling. Small speed win; rarely causes minor texture artifacts. Recommended on."))
        settingsCaption(
          Toggle(L("Fast Math (Metal Shaders)"), isOn: $fastMath)
            .onChange(of: fastMath) { DOLConfigBridge.setGfxHackFastMath($0) },
          L("Lets Metal shaders use fast, relaxed-precision math. Can speed up the GPU; may cause subtle rendering differences."))
        // iCube native-Metal moat: routes EFB/XFB color/depth resolve, blit, scale and
        // gamma through Metal compute kernels instead of the stock raster path. Wired into
        // the Metal backend (TryCompute* overrides) and gated on GFX_USE_COMPUTE_EFBXFB.
        settingsCaption(
          Toggle(L("Use Compute for EFB/XFB"), isOn: $useComputeEfbXfb)
            .onChange(of: useComputeEfbXfb) { DOLConfigBridge.setGfxUseComputeEfbXfb($0) },
          L("Native-Metal compute acceleration for EFB/XFB. Experimental GPU perf knob; OFF by default. Applies on next launch."))
        settingsCaption(
          Toggle(L("Use Compute for Vertex Decode"), isOn: $useComputeVertexDecode)
            .onChange(of: useComputeVertexDecode) { DOLConfigBridge.setGfxUseComputeVertexDecode($0) },
          L("Offload vertex decoding to a Metal compute shader (CPU→GPU). Experimental — currently only position-only-float formats use the GPU path (others fall back to CPU), so most games see little change yet. OFF by default. Applies on next launch."))
        settingsCaption(
          Toggle(L("No Mipmapping (iOS)"), isOn: $noMipmapping)
            .onChange(of: noMipmapping) { DOLConfigBridge.setGfxHackNoMipmapping($0) },
          L("Disables mipmaps. Saves a little memory/bandwidth but makes distant textures shimmer. Leave off normally."))
        settingsCaption(
          Toggle(L("GPU EFB Peek Resolve"), isOn: $gpuEfbPeekResolve)
            .onChange(of: gpuEfbPeekResolve) { DOLConfigBridge.setGfxHackGpuEfbPeekResolve($0) },
          L("Experimental: resolves EFB peek reads on the GPU instead of a CPU readback. May reduce CPU-thread stalls for games that read the framebuffer; OFF by default. Verify visuals per game."))
      }
      Section {
        settingsCaption(
          Toggle(L("Interlaced Field Decimation"), isOn: $viDecimateInterlace)
            .onChange(of: viDecimateInterlace) { DOLConfigBridge.setGfxHackViDecimateInterlace($0) },
          L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."))
      }
    }
    .navigationTitle(L("Hacks"))
    .configSynced { sync() }
    .sheet(isPresented: $showHelp) {
      NavigationView {
        ScrollView { Text(helpMessage).padding() }
          .navigationTitle(L("Help"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showHelp = false } } }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidStartNotification"))) { _ in sync() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidEndNotification"))) { _ in sync() }
#if os(iOS)
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in sync() }
#endif
  }
  private func sync() {
    efbAccess = DOLConfigBridge.gfxHackEfbAccessEnable()
    skipEfbToRam = DOLConfigBridge.gfxHackSkipEfbCopyToRam()
    skipXfbToRam = DOLConfigBridge.gfxHackSkipXfbCopyToRam()
    immediateXfb = DOLConfigBridge.gfxHackImmediateXfb()
    copyEfbScaled = DOLConfigBridge.gfxHackCopyEfbScaled()
    efbFormatChanges = DOLConfigBridge.gfxHackEfbEmulateFormatChanges()
    vertexRounding = DOLConfigBridge.gfxHackVertexRounding()
    forceProgressive = DOLConfigBridge.gfxHackForceProgressive()
    deferEfbCopies = DOLConfigBridge.gfxHackDeferEfbCopies()
    viSkipMode = DOLConfigBridge.gfxHackViSkipMode()
    fastTextureSampling = DOLConfigBridge.gfxHackFastTextureSampling()
    fastMath = DOLConfigBridge.gfxHackFastMath()
    useComputeEfbXfb = DOLConfigBridge.gfxUseComputeEfbXfb()
    useComputeVertexDecode = DOLConfigBridge.gfxUseComputeVertexDecode()
    noMipmapping = DOLConfigBridge.gfxHackNoMipmapping()
    earlyXfbOutput = DOLConfigBridge.gfxHackEarlyXfbOutput()
    skipDuplicateXFBs = DOLConfigBridge.gfxHackSkipDuplicateXFBs()
    viDecimateInterlace = DOLConfigBridge.gfxHackViDecimateInterlace()
    bboxEnabled = DOLConfigBridge.gfxHackBboxEnable()
    bboxSyncMode = DOLConfigBridge.gfxBboxSyncMode()
    gpuEfbPeekResolve = DOLConfigBridge.gfxHackGpuEfbPeekResolve()
    backendSupportsBbox = DOLConfigBridge.gfxBackendSupportsBoundingBox()
    textureCacheSamples = normalizedTextureCacheSamples(DOLConfigBridge.gfxSafeTextureCacheColorSamples())
  }
  private func textureCacheAccuracyLabel(_ samples: Int) -> String {
    switch samples {
    case 512: return L("Safe")
    case 0: return L("Fast")
    default: return L("Default")
    }
  }
  private func normalizedTextureCacheSamples(_ samples: Int) -> Int {
    switch samples {
    case 512, 0: return samples
    default: return 128
    }
  }
  private func viSkipLabel(_ v: Int) -> String { switch v { case 1: return L("On"); case 2: return L("Auto"); default: return L("Off") } }
  private func bboxSyncLabel(_ v: Int) -> String { switch v { case 1: return L("Force Sync"); default: return L("Latched") } }
  // MARK: - Help UI & Text
  private func labelWithInfo(_ title: String, action: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button(action: action) { Image(systemName: "info.circle") }
        .buttonStyle(.plain)
    }
  }

  private func helpTextEfbAccess() -> String {
    L("Allows the emulated CPU to read the Embedded Framebuffer (EFB).\n\nTurning it off can help performance but breaks effects that read the EFB (heat haze, soft particles, lens flares, some UI).\n\niOS note: when a game does use EFB reads, those reads run on the CPU thread — the bottleneck — so this can matter here; but disabling it breaks visuals. Leave ON unless a game both needs the speed and tolerates the breakage.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextSkipEfbToRam() -> String {
    L("Skips copying EFB contents to emulated RAM.\n\nImproves performance but breaks features that rely on CPU reads of the EFB (post-processing, reflections, heat haze, some UI).\n\niOS note: the skipped copy/readback is CPU-side, so this can recover real time on the bottlenecked interpreter — at the cost of broken effects in affected games.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextSkipXfbToRam() -> String {
    L("Skips copying the XFB (external framebuffer) to RAM.\n\nCan increase performance but breaks software XFB paths; may cause missing frames, flicker, or broken FMVs.\n\niOS note: CPU-side saving that can help the bottleneck, but the breakage is common — keep off unless a specific title benefits.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextImmediateXfb() -> String {
    L("Renders directly from the EFB without an emulated XFB buffer.\n\nReduces latency and may raise FPS, but can cause flicker, bad deinterlacing, or timing issues.\n\niOS note: trims some CPU/sync work but is risky on VI-sensitive games. Leave off unless you specifically want lower latency.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextCopyEfbScaled() -> String {
    L("Scales EFB copies to the current internal resolution.\n\nSharpens post-processing at higher resolutions, but some games assume 1x EFB and show overblown bloom/halos or broken depth effects.\n\niOS note: GPU-side quality choice; little framerate effect on the CPU-bound path. Disable only to fix such glitches.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextEarlyXfbOutput() -> String {
    L("Outputs the XFB earlier in the pipeline.\n\nReduces display latency, but may cause jitter or timing issues in VI-sensitive titles.\n\niOS note: latency/pacing tweak; negligible framerate effect. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextSkipDuplicateXFBs() -> String {
    L("Skips presenting duplicate XFB fields/frames.\n\nSaves work and bandwidth when games output identical fields; rarely affects pacing or A/V sync.\n\niOS note: small saving on both CPU and GPU; safe. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextEmulateEfbFormatChanges() -> String {
    L("Accurately emulates EFB format/precision changes.\n\nFixes color and post-process issues in many games. Disabling can help speed but may cause wrong colors or missing effects.\n\niOS note: accuracy vs a modest CPU/GPU saving; the breakage usually isn't worth it. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextVertexRounding() -> String {
    L("Rounds vertex positions to reduce subpixel jitter.\n\nStabilizes 2D elements and reduces shimmering; can slightly distort 3D geometry.\n\niOS note: minor cost; quality choice rather than a performance one.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextForceProgressive() -> String {
    L("Forces progressive scan instead of interlaced fields.\n\nReduces flicker and may cut latency, but some games expect interlacing.\n\niOS note: presentation choice; no meaningful framerate impact.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextDeferEfbCopies() -> String {
    L("Queues and defers EFB copies to reduce pipeline stalls.\n\nCan increase performance but reorders copies and may break effects that need immediate results (heat haze, mirrors).\n\niOS note: can reduce CPU-thread stalls on the bottleneck — a real potential win — but verify visuals per game.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextViSkipMode() -> String {
    L("Skips VI (Video Interface) updates to raise FPS.\n\nOn: always skip (highest FPS, visible artifacts/flicker). Auto: skip when likely safe. Off: most accurate.\n\niOS note: this directly cuts per-frame CPU work, so it can help on the bottlenecked interpreter — at the cost of temporal artifacts. Try Auto if you need frames.\n\nIf unsure, select Auto or Off.")
  }
  private func helpTextFastTextureSampling() -> String {
    L("Uses a faster, less accurate texture-sampling path.\n\nCan help on some GPUs but may cause banding, seams, or vertical lines in FMVs.\n\niOS note: GPU-side; rarely changes the CPU-bound framerate. Disable if you see texture artifacts. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextFastMath() -> String {
    L("Enables fast-math optimizations in iCube's Metal shaders.\n\nRelaxes IEEE precision for speed; can cause subtle lighting differences or rare shader bugs.\n\niOS note: GPU-side optimization; helps only when GPU-bound and won't move the CPU bottleneck. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextUseComputeEfbXfb() -> String {
    L("Native-Metal compute acceleration for EFB/XFB.\n\nRoutes EFB color/depth resolve, RGBA8 blit/scale/gamma, and mipmap generation through Metal compute kernels instead of the stock raster path. This is an experimental GPU performance knob and is OFF by default.\n\nFalls back to the stock path automatically for any case it doesn't handle, so it is safe to leave on, but on untested hardware it can produce visual glitches (shimmer, wrong depth) — benchmark and visually verify GPU-bound titles before relying on it.\n\nApplies on next launch.")
  }
  private func helpTextNoMipmapping() -> String {
    L("Disables texture mipmapping.\n\nA workaround for rare driver bugs; normally increases shimmering/aliasing and can hurt performance via texture-cache inefficiency.\n\niOS note: GPU-side; leave OFF — it usually makes things both uglier and slightly slower.\n\nIf unsure, leave this unchecked.")
  }
}

private struct TextureCacheAccuracyPicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SelectRow(label: L("Safe"), checked: selected == 512) {
        selected = 512
        DOLConfigBridge.setGfxSafeTextureCacheColorSamples(512)
      }
      SelectRow(label: L("Default"), checked: selected == 128) {
        selected = 128
        DOLConfigBridge.setGfxSafeTextureCacheColorSamples(128)
      }
      SelectRow(label: L("Fast"), checked: selected == 0) {
        selected = 0
        DOLConfigBridge.setGfxSafeTextureCacheColorSamples(0)
      }
    }
    .navigationTitle(L("Texture Cache Accuracy"))
  }
}

private struct ViSkipModePicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SelectRow(label: L("Off"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGfxHackViSkipMode(0) }
      SelectRow(label: L("On"), checked: selected == 1) { selected = 1; DOLConfigBridge.setGfxHackViSkipMode(1) }
      SelectRow(label: L("Auto"), checked: selected == 2) { selected = 2; DOLConfigBridge.setGfxHackViSkipMode(2) }
    }
    .navigationTitle(L("VI Skip Mode"))
  }
}

private struct BBoxSyncModePicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SelectRow(label: L("Latched"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGfxBboxSyncMode(0) }
      SelectRow(label: L("Force Sync"), checked: selected == 1) { selected = 1; DOLConfigBridge.setGfxBboxSyncMode(1) }
    }
    .navigationTitle(L("Bounding Box Sync"))
  }
}

/// Reusable Off/On/Auto picker for Metal TriState knobs (present-drawable, manual-upload).
struct MetalTriStatePicker: View {
  @Binding var selected: Int
  let title: String
  let setter: (Int) -> Void
  var body: some View {
    List {
      SelectRow(label: L("Off"), checked: selected == 0) { selected = 0; setter(0) }
      SelectRow(label: L("On"), checked: selected == 1) { selected = 1; setter(1) }
      SelectRow(label: L("Auto"), checked: selected == 2) { selected = 2; setter(2) }
    }
    .navigationTitle(title)
  }
}
/// Graphics > Advanced placeholder
