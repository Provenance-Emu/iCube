// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsEnhancementsModelBuilder {
  static func make(state: GraphicsEnhancementsState, apply: @escaping (GraphicsEnhancementsChange) -> Void) -> MenuModel {
    let msaaOn = state.msaa > MsaaSamples.none.rawValue

    // Resolver step #3: while an auto controller or the game drives the key, the manual choice would not apply until the override clears.
    let resolution = MenuSection(id: "internal-resolution", header: L("Internal Resolution"), items: [
      SettingsRow.cycle("efb-scale", L("Internal Resolution"), efbScaleOptions(maxScale: max(state.efbMaxScale, state.efbScale)), state.efbScale,
            L("Renders the game above native resolution for a sharper image. Higher costs more GPU; on the CPU-bound path 1x–2x is usually plenty."),
            enabled: state.efbOverride == .none, badge: ConfigOverrideBadge.title(for: state.efbOverride), set: { apply(.efbScale($0)) }),
    ])
    let filtering = MenuSection(id: "texture-filtering", header: L("Texture Filtering"), items: [
      SettingsRow.cycle("anisotropy", L("Anisotropic Filtering"), GraphicsEnhancementsState.anisotropyLadder.map { (multiplier($0), $0) }, state.anisotropy,
            L("Sharpens textures viewed at steep angles (floors, walls). Cheap on modern GPUs; 4x–16x is a safe quality win."), set: { apply(.anisotropy($0)) }),
      SettingsRow.cycle("msaa", L("Anti-Aliasing (MSAA)"), MsaaSamples.allCases.map { ($0 == .none ? L("None") : multiplier($0.rawValue), $0.rawValue) }, state.msaa,
            L("Multisample anti-aliasing smooths jagged polygon edges. Higher costs more GPU. The Metal backend clamps unsupported sample counts automatically."),
            set: { apply(.msaa($0)) }),
      SettingsRow.toggle("ssaa", L("Supersampling (SSAA)"), state.ssaa,
             msaaOn ? L("Supersampling renders MSAA samples at full shading for the sharpest result, at a heavy GPU cost. Requires MSAA above None.")
                    : L("Enable MSAA (above None) first to use supersampling."),
             enabled: msaaOn, set: { apply(.ssaa($0)) }),
      SettingsRow.cycle("output-resampling", L("Output Resampling"), OutputResamplingChoice.allCases.map { ($0.title, $0.rawValue) }, state.outputResampling,
            L("How the final image is resampled to the screen. Default matches the backend; Sharp Bilinear and Area Sampling can look cleaner when up/down-scaling."),
            set: { apply(.outputResampling($0)) }),
    ])
    let enhancements = MenuSection(id: "enhancements", header: L("Enhancements"), items: [
      SettingsRow.toggle("true-color", L("Force 24-bit Color"), state.trueColor,
             L("Forces full 24-bit color instead of the GameCube/Wii's banded 16/18-bit output. Reduces gradient banding at negligible cost. Recommended ON."),
             set: { apply(.trueColor($0)) }),
      SettingsRow.toggle("disable-copy-filter", L("Disable Copy Filter"), state.disableCopyFilter,
             L("Disables the deflicker/blur the console applied to copies. Gives a sharper image; may slightly change how a few games look."),
             set: { apply(.disableCopyFilter($0)) }),
      SettingsRow.toggle("widescreen-hack", L("Widescreen Hack"), state.widescreenHack,
             L("Forces 16:9 in games that only render 4:3. Can stretch HUDs or break some games; leave off for natively-widescreen titles."),
             set: { apply(.widescreenHack($0)) }),
      SettingsRow.toggle("hdr-output", L("HDR Output"), state.hdrOutput,
             L("Outputs in HDR on capable displays. Most games are SDR, so the effect is subtle; harmless to leave off."),
             set: { apply(.hdrOutput($0)) }),
      SettingsRow.toggle("gpu-texture-decoding", L("GPU Texture Decoding"), state.gpuTextureDecoding,
             L("Decodes textures on the GPU instead of the CPU. Moves work off the bottleneck thread, so it can help CPU-bound titles that stream many textures. iCube already ships a NEON CPU decoder (Config ▸ Advanced) as the default fast path."),
             set: { apply(.gpuTextureDecoding($0)) }),
    ])

    var compatibilityItems = [
      SettingsRow.toggle("disable-fog", L("Disable Fog"), state.disableFog,
             L("Removes distance fog. Can improve visibility but breaks the intended look and a few effects. Leave off normally."),
             set: { apply(.disableFog($0)) }),
      SettingsRow.toggle("arbitrary-mipmap", L("Arbitrary Mipmap Detection"), state.arbitraryMipmapDetection,
             L("Detects games that abuse mipmaps for special effects and renders them correctly. Leave on unless a game looks wrong."),
             set: { apply(.arbitraryMipmapDetection($0)) }),
    ]
    // Hidden, not disabled, while detection is off: the old screen only showed it then.
    if state.arbitraryMipmapDetection {
      compatibilityItems.append(
        SettingsRow.stepper("arbitrary-mipmap-threshold", L("Mipmap Detection Threshold"), state.arbitraryMipmapThreshold,
                            range: GraphicsEnhancementsState.mipmapThresholdRange, step: GraphicsEnhancementsState.mipmapThresholdStep,
                            format: { String(format: "%.2f", $0) },
                            L("Sensitivity of arbitrary-mipmap detection. Leave at the default unless a game's textures look wrong."),
                            set: { apply(.arbitraryMipmapThreshold($0)) }))
    }
    let compatibility = MenuSection(id: "compatibility", header: L("Compatibility"), items: compatibilityItems)

    return MenuModel(sections: [resolution, filtering, enhancements, compatibility])
  }

  /// "2x"; the one place a scale or sample count becomes a label.
  private static func multiplier(_ value: Int) -> String { "\(value)x" }

  /// Auto, 1x (Native), then 2x ... maxScale. Empty-safe for a maxScale below 2. The caller passes at least the stored scale, so a value above the current max keeps its real label.
  private static func efbScaleOptions(maxScale: Int) -> [(String, Int)] {
    let first = EfbScaleChoice.native.rawValue + 1
    return [(L("Auto (fit window)"), EfbScaleChoice.auto.rawValue), ("\(multiplier(EfbScaleChoice.native.rawValue)) (\(L("Native")))", EfbScaleChoice.native.rawValue)]
      + stride(from: first, through: maxScale, by: 1).map { (multiplier($0), $0) }
  }
}

private extension OutputResamplingChoice {
  var title: String {
    switch self {
    case .standard: return L("Default")
    case .bilinear: return L("Bilinear")
    case .bSpline: return L("B-Spline")
    case .mitchellNetravali: return L("Mitchell-Netravali")
    case .catmullRom: return L("Catmull-Rom")
    case .sharpBilinear: return L("Sharp Bilinear")
    case .areaSampling: return L("Area Sampling")
    }
  }
}
