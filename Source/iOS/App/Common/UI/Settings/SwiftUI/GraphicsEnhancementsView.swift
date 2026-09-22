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

// MARK: - Graphics placeholders

/// Graphics > General placeholder (replaced above)
/// Graphics > Enhancements placeholder
struct GraphicsEnhancementsView: View {
  @State private var anisotropy: Int = 1
  @State private var msaa: Int = 1 // sample count: 1/2/4/8
  @State private var ssaa: Bool = false
  @State private var outputResampling: Int = 0 // OutputResamplingMode: 0=Default..6=AreaSampling
  @State private var trueColor: Bool = true
  @State private var disableCopyFilter: Bool = true
  @State private var efbScale: Int = 1
  @State private var efbMaxScale: Int = 6
  // Resolver step #3 "Auto" badge: true when Auto-IR / thermal is overriding GFX_EFB_SCALE on the
  // CurrentRun layer. While true the manual picker is disabled and the value shown is effective.
  @State private var efbAutoOverridden: Bool = false
  @State private var widescreenHack: Bool = false
  @State private var disableFog: Bool = false
  @State private var arbitraryMipmapDetection: Bool = false
  @State private var arbitraryMipmapThreshold: Double = 0.5
  @State private var hdrOutput: Bool = false
  @State private var gpuTextureDecoding: Bool = false
  @State private var helpMessage: String = ""
  @State private var showHelp: Bool = false
  var body: some View {
    List {
      Section(content: {
        settingsNavCaption(
          destination: EfbScalePicker(selected: $efbScale, maxScale: efbMaxScale),
          L("Renders the game above native resolution for a sharper image. Higher costs more GPU; on the CPU-bound path 1x–2x is usually plenty.")
        ) {
          HStack {
            Text("\(L("Internal Resolution")): \(efbScale == 0 ? L("Auto (fit window)") : "\(efbScale)x")")
            // Resolver step #3: "Auto" badge when Auto-IR / thermal is overriding GFX_EFB_SCALE.
            if efbAutoOverridden {
              Text(L("Auto"))
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())
            }
          }
        }
        // While an auto controller drives this key (CurrentRun), disable the manual picker so the
        // displayed effective value can't be silently shadowed by a stale Base value authored here.
        .disabled(efbAutoOverridden)
        .onChange(of: efbScale) { newScale in
          DOLConfigBridge.setGfxEfbScale(newScale)
          // Picking an explicit (non-fit-window) scale means the user wants that exact IR. The Auto-IR
          // controller also drives GFX_EFB_SCALE, so leave it on and the two fight. Turn Auto-IR off so
          // the manual choice sticks. (The Auto-IR toggle lives on the Graphics > General screen and
          // re-reads its state from the bridge when it next appears.)
          if newScale != 0 {
            DOLConfigBridge.setGfxAutoIREnable(false)
          }
        }
      }, header: { Text(L("Internal Resolution")) })
      Section(content: {
        settingsNavCaption(
          destination: AnisotropyPicker(selected: $anisotropy),
          L("Sharpens textures viewed at steep angles (floors, walls). Cheap on modern GPUs; 4x–16x is a safe quality win.")
        ) {
          Text("\(L("Anisotropic Filtering")): \(anisotropy)x")
        }
        .onChange(of: anisotropy) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
        settingsNavCaption(
          destination: MSAAPicker(selected: $msaa),
          L("Multisample anti-aliasing smooths jagged polygon edges. Higher costs more GPU. The Metal backend clamps unsupported sample counts automatically.")
        ) {
          Text("\(L("Anti-Aliasing (MSAA)")): \(msaa == 1 ? L("None") : "\(msaa)x")")
        }
        .onChange(of: msaa) { newMsaa in
          DOLConfigBridge.setGfxMsaa(newMsaa)
          // Desktop parity: SSAA only applies when MSAA > 1. Clear it if MSAA drops to None.
          if newMsaa <= 1 && ssaa {
            ssaa = false
            DOLConfigBridge.setGfxSsaa(false)
          }
        }
        settingsCaption(
          Toggle(L("Supersampling (SSAA)"), isOn: $ssaa)
            .disabled(msaa <= 1)
            .onChange(of: ssaa) { DOLConfigBridge.setGfxSsaa($0) },
          msaa > 1
            ? L("Supersampling renders MSAA samples at full shading for the sharpest result, at a heavy GPU cost. Requires MSAA above None.")
            : L("Enable MSAA (above None) first to use supersampling."))
        settingsNavCaption(
          destination: OutputResamplingPicker(selected: $outputResampling),
          L("How the final image is resampled to the screen. Default matches the backend; Sharp Bilinear and Area Sampling can look cleaner when up/down-scaling.")
        ) {
          Text("\(L("Output Resampling")): \(outputResamplingLabel(outputResampling))")
        }
        .onChange(of: outputResampling) { DOLConfigBridge.setGfxEnhanceOutputResampling($0) }
      }, header: { Text(L("Texture Filtering")) })
      Section(content: {
        settingsCaption(
          Toggle(L("Force 24-bit Color"), isOn: $trueColor)
            .onChange(of: trueColor) { DOLConfigBridge.setGfxEnhanceForceTrueColor($0) },
          L("Forces full 24-bit color instead of the GameCube/Wii's banded 16/18-bit output. Reduces gradient banding at negligible cost. Recommended ON."))
        settingsCaption(
          Toggle(L("Disable Copy Filter"), isOn: $disableCopyFilter)
            .onChange(of: disableCopyFilter) { DOLConfigBridge.setGfxEnhanceDisableCopyFilter($0) },
          L("Disables the deflicker/blur the console applied to copies. Gives a sharper image; may slightly change how a few games look."))
        settingsCaption(
          Toggle(L("Widescreen Hack"), isOn: $widescreenHack)
            .onChange(of: widescreenHack) { DOLConfigBridge.setGfxWidescreenHack($0) },
          L("Forces 16:9 in games that only render 4:3. Can stretch HUDs or break some games; leave off for natively-widescreen titles."))
        settingsCaption(
          Toggle(L("HDR Output"), isOn: $hdrOutput)
            .onChange(of: hdrOutput) { DOLConfigBridge.setGfxEnhanceHDROutput($0) },
          L("Outputs in HDR on capable displays. Most games are SDR, so the effect is subtle; harmless to leave off."))
        settingsCaption(
          Toggle(L("GPU Texture Decoding"), isOn: $gpuTextureDecoding)
            .onChange(of: gpuTextureDecoding) { DOLConfigBridge.setGfxEnableGPUTextureDecoding($0) },
          L("Decodes textures on the GPU instead of the CPU. Moves work off the bottleneck thread, so it can help CPU-bound titles that stream many textures. iCube already ships a NEON CPU decoder (Config ▸ Advanced) as the default fast path."))
      }, header: { Text(L("Enhancements")) })
      Section(content: {
        settingsCaption(
          Toggle(L("Disable Fog"), isOn: $disableFog)
            .onChange(of: disableFog) { DOLConfigBridge.setGfxDisableFog($0) },
          L("Removes distance fog. Can improve visibility but breaks the intended look and a few effects. Leave off normally."))
        settingsCaption(
          Toggle(L("Arbitrary Mipmap Detection"), isOn: $arbitraryMipmapDetection)
            .onChange(of: arbitraryMipmapDetection) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetection($0) },
          L("Detects games that abuse mipmaps for special effects and renders them correctly. Leave on unless a game looks wrong."))
        if arbitraryMipmapDetection {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(L("Mipmap Detection Threshold"))
              Spacer()
              Text(String(format: "%.2f", arbitraryMipmapThreshold))
            }
            // Threshold is the average per-pixel/per-channel percent diff between an expected
            // blurred mipmap and the received one (default 14.0; ~4.5 is just below clearly-arbitrary).
            // Old 0...1 range couldn't represent the 14 default at all. Span the meaningful 0...30 scale.
#if os(tvOS)
            TVIntStepper(
              value: Binding(
                get: { Int(arbitraryMipmapThreshold * 10) },
                set: { arbitraryMipmapThreshold = Double($0) / 10.0 }
              ),
              range: 0...300,
              step: 1
            )
            .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#else
            Slider(value: $arbitraryMipmapThreshold, in: 0.0...30.0, step: 0.1)
              .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#endif
            Text(L("Sensitivity of arbitrary-mipmap detection. Leave at the default unless a game's textures look wrong."))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      }, header: { Text(L("Compatibility")) })
    }
    .navigationTitle(L("Enhancements"))
    .configSynced { sync() }
    .sheet(isPresented: $showHelp) {
      NavigationView {
        ScrollView { Text(helpMessage).padding() }
          .navigationTitle(L("Help"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showHelp = false } } }
      }
    }
  }
  private func sync() {
    efbMaxScale = max(1, DOLConfigBridge.gfxEfbMaxScale())
    efbScale = DOLConfigBridge.gfxEfbScale()
    efbAutoOverridden = DOLConfigBridge.isEfbScaleAutoOverridden()
    anisotropy = DOLConfigBridge.gfxEnhanceAnisotropySamples()
    msaa = normalizedMsaa(DOLConfigBridge.gfxMsaa())
    ssaa = DOLConfigBridge.gfxSsaa()
    outputResampling = DOLConfigBridge.gfxEnhanceOutputResampling()
    trueColor = DOLConfigBridge.gfxEnhanceForceTrueColor()
    disableCopyFilter = DOLConfigBridge.gfxEnhanceDisableCopyFilter()
    widescreenHack = DOLConfigBridge.gfxWidescreenHack()
    disableFog = DOLConfigBridge.gfxDisableFog()
    gpuTextureDecoding = DOLConfigBridge.gfxEnableGPUTextureDecoding()
    arbitraryMipmapDetection = DOLConfigBridge.gfxEnhanceArbitraryMipmapDetection()
    arbitraryMipmapThreshold = Double(DOLConfigBridge.gfxEnhanceArbitraryMipmapDetectionThreshold())
    hdrOutput = DOLConfigBridge.gfxEnhanceHDROutput()
  }
  private func labelWithInfo(_ title: String, action: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button(action: action) { Image(systemName: "info.circle") }
        .buttonStyle(.plain)
    }
  }

  /// Snap an arbitrary stored MSAA sample count to the fixed UI ladder (1/2/4/8).
  private func normalizedMsaa(_ samples: Int) -> Int {
    switch samples {
    case ..<2: return 1
    case 2...3: return 2
    case 4...7: return 4
    default: return 8
    }
  }
  private func outputResamplingLabel(_ v: Int) -> String {
    switch v {
    case 1: return L("Bilinear")
    case 2: return L("B-Spline")
    case 3: return L("Mitchell-Netravali")
    case 4: return L("Catmull-Rom")
    case 5: return L("Sharp Bilinear")
    case 6: return L("Area Sampling")
    default: return L("Default")
    }
  }

  // MARK: - Help Text (UIKit parity)
  private func helpTextInternalResolution() -> String {
    L("Controls the rendering resolution.\n\nA high resolution greatly improves visual quality, but also greatly increases GPU load and can cause issues in certain games. Generally speaking, the lower the internal resolution, the better performance will be.\n\niOS note: this is a GPU cost. iCube is usually CPU-bound (the jitless interpreter), so raising resolution often costs little until the GPU becomes the limit; lower it first if a GPU-heavy scene drops frames.\n\nIf unsure, select Native (1x).")
  }
  private func helpTextAnisotropy() -> String {
    L("Adjusts texture filtering. Anisotropic filtering sharpens textures viewed at oblique angles.\n\nAny option above 1x slightly increases GPU load and can alter the look of textures in a few games.\n\niOS note: GPU-side cost only; rarely matters on the CPU-bound interpreter. Safe to raise unless a specific GPU-heavy scene struggles.\n\nIf unsure, select 1x.")
  }
  private func helpTextDisableFog() -> String {
    L("Removes distance fog, making far objects more visible.\n\nDisabling fog breaks games that rely on proper fog emulation (pop-in, wrong visibility).\n\niOS note: tiny GPU saving; almost never helps on iCube because the CPU interpreter is the limit, and it can cause visual glitches. Leave OFF unless you are clearly GPU-bound.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextDisableCopyFilter() -> String {
    L("Disables the blending of adjacent rows when copying the EFB (some games call this \"deflickering\" or \"smoothing\").\n\nResults in a sharper image with no performance cost; causes few issues.\n\niOS note: image-quality choice only; no effect on the CPU-bound framerate.\n\nIf unsure, leave this checked.")
  }
  private func helpTextWidescreenHack() -> String {
    L("Forces 4:3 games to render at a wider aspect ratio. Use with Aspect Ratio set to 16:9.\n\nOften partially breaks graphics and UIs, and is unnecessary (and harmful) if you use an AR/Gecko widescreen patch instead.\n\niOS note: display/aspect choice only; no framerate impact.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextForceTrueColor() -> String {
    L("Renders color in 24-bit to reduce banding.\n\nNo performance impact and few graphical issues.\n\niOS note: pure quality win; safe to leave on regardless of the CPU bottleneck.\n\nIf unsure, leave this checked.")
  }
  private func helpTextArbitraryMipmap() -> String {
    L("Detects arbitrary mipmaps that some games use for distance-based effects.\n\nCan cause blurry textures from false positives, and is incompatible with GPU Texture Decoding. Disabling can reduce stutter in games that stream many textures.\n\niOS note: mostly an accuracy/quality tradeoff; little framerate effect on the CPU-bound path.\n\nIf unsure, leave this checked.")
  }
  private func helpTextHDROutput() -> String {
    L("Enables HDR output on supported displays for wider dynamic range and color.\n\niOS note: display feature; negligible performance cost. Only useful on HDR-capable screens.")
  }
}

private struct AnisotropyPicker: View {
  @Binding var selected: Int
  private var options: [Int] { [1, 2, 4, 8, 16] }
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        SelectRow(label: "\(v)x", checked: v == selected) { selected = v; DOLConfigBridge.setGfxEnhanceAnisotropySamples(v) }
      }
    }
    .navigationTitle(L("Anisotropic Filtering"))
  }
}

private struct MSAAPicker: View {
  @Binding var selected: Int
  // Fixed sample ladder. NOT gated on per-device AAModes — the Metal backend clamps
  // unsupported counts at runtime, so an unsupported pick degrades, it doesn't crash.
  private var options: [Int] { [1, 2, 4, 8] }
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        SelectRow(label: v == 1 ? L("None") : "\(v)x", checked: v == selected) {
          selected = v
          DOLConfigBridge.setGfxMsaa(v)
        }
      }
    }
    .navigationTitle(L("Anti-Aliasing (MSAA)"))
  }
}

private struct OutputResamplingPicker: View {
  @Binding var selected: Int
  // (label, OutputResamplingMode raw value 0..6)
  private var options: [(String, Int)] {
    [(L("Default"), 0), (L("Bilinear"), 1), (L("B-Spline"), 2),
     (L("Mitchell-Netravali"), 3), (L("Catmull-Rom"), 4),
     (L("Sharp Bilinear"), 5), (L("Area Sampling"), 6)]
  }
  var body: some View {
    List {
      ForEach(options, id: \.1) { opt in
        SelectRow(label: opt.0, checked: opt.1 == selected) {
          selected = opt.1
          DOLConfigBridge.setGfxEnhanceOutputResampling(opt.1)
        }
      }
    }
    .navigationTitle(L("Output Resampling"))
  }
}

private struct EfbScalePicker: View {
  @Binding var selected: Int
  let maxScale: Int
  private var options: [Int] { [0] + Array(1...max(1, maxScale)) }
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        if v == 0 {
          SelectRow(label: L("Auto"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGfxEfbScale(0) }
        } else if v == 1 {
          SelectRow(label: "1x (\(L("Native")))", checked: selected == 1) { selected = 1; DOLConfigBridge.setGfxEfbScale(1) }
        } else {
          SelectRow(label: "\(v)x", checked: selected == v) { selected = v; DOLConfigBridge.setGfxEfbScale(v) }
        }
      }
    }
    .navigationTitle(L("Internal Resolution"))
  }
}

/// Graphics > Hacks placeholder
