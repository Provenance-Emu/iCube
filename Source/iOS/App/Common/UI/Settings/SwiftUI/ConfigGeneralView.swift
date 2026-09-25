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

// MARK: - Config General (wired)

struct ConfigGeneralView: View {
  @State private var dualCore: Bool = false
  @State private var cheats: Bool = false
  @State private var mismatchedRegion: Bool = false
  @State private var autoDiscChange: Bool = false
  @State private var fastDiscSpeed: Bool = false
  @State private var dspThread: Bool = false
  @State private var speedLimitPercent: Int = 0
  @State private var fastForwardSpeedPercent: Int = 300
  @State private var fallbackRegion: Region = .ntscU
  // Resume where I left off — frontend-only NSUserDefault (see SaveStateService).
  @AppStorage("resume_where_left_off") private var resumeWhereLeftOff: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("Basic Settings"))) {
        settingsCaption(
          Toggle(L("Enable Dual Core (speedup)"), isOn: $dualCore)
            .onChange(of: dualCore) { DOLConfigBridge.setMainCpuThread($0) },
          L("Runs the emulated GPU on a separate thread from the emulated CPU (can deadlock some games on this interpreter)."))
        settingsCaption(
          Toggle(L("DSP Thread (speedup)"), isOn: $dspThread)
            .onChange(of: dspThread) { DOLConfigBridge.setMainDSPThread($0) },
          L("Runs audio emulation on its own thread. Small speedup; safe to leave ON."))
        settingsCaption(
          Toggle(L("Enable Cheats"), isOn: $cheats)
            .onChange(of: cheats) { DOLConfigBridge.setMainEnableCheats($0) },
          L("Activates AR/Gecko cheat codes for the running game."))
        settingsCaption(
          Toggle(L("Override Region Mismatch"), isOn: $mismatchedRegion)
            .onChange(of: mismatchedRegion) { DOLConfigBridge.setMainOverrideRegionSettings($0) },
          L("Lets a game boot under a different region's settings. Can cause issues; leave OFF unless a game needs it."))
        settingsCaption(
          Toggle(L("Auto Disc Change"), isOn: $autoDiscChange)
            .onChange(of: autoDiscChange) { DOLConfigBridge.setMainAutoDiscChange($0) },
          L("Automatically swaps to the next disc for multi-disc games."))
        settingsCaption(
          Toggle(L("Fast Disc Speed (speedup)"), isOn: $fastDiscSpeed)
            .onChange(of: fastDiscSpeed) { DOLConfigBridge.setMainFastDiscSpeed($0) },
          L("Removes emulated disc-read delays. Speeds up loading in most games but breaks a few that depend on real timing."))
        settingsCaption(
          Toggle(L("Resume Where I Left Off"), isOn: $resumeWhereLeftOff),
          L("When you quit a game, your spot is auto-saved to a dedicated slot and reloaded the next time you launch that game. Never touches your numbered save slots."))
      }

      Section(header: Text(L("Speed"))) {
        settingsNavCaption(
          destination: SpeedLimitPicker(selectedPercent: $speedLimitPercent),
          L("Caps emulation speed as a percentage of real hardware. 100% is full speed; Unlimited runs as fast as the device allows. Lower it only to slow a game down deliberately.")
        ) {
          HStack {
            Label(L("Speed Limit"), systemImage: "speedometer")
            Spacer()
            Text(speedLimitLabel(percent: speedLimitPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: speedLimitPercent) { DOLConfigBridge.setMainEmulationSpeedPercent($0) }

        settingsNavCaption(
          destination: FastForwardSpeedPicker(selectedPercent: $fastForwardSpeedPercent),
          L("Speed used while the fast-forward button is held. Unlimited runs as fast as possible; the CPU-bound interpreter may not reach high multiples.")
        ) {
          HStack {
            Label(L("Fast Forward Speed"), systemImage: "forward.fill")
            Spacer()
            Text(fastForwardSpeedLabel(percent: fastForwardSpeedPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: fastForwardSpeedPercent) { UserDefaults.standard.set($0, forKey: "fast_forward_speed_percent") }
      }

      Section(header: Text(L("Fallback Region"))) {
        settingsNavCaption(
          destination: FallbackRegionPicker(selected: $fallbackRegion),
          L("Region used for titles whose region can't be detected automatically.")
        ) {
          Text("\(L("Fallback Region")): \(fallbackRegion.label)")
        }
        .onChange(of: fallbackRegion) { DOLConfigBridge.setMainFallbackRegion($0.rawValue) }
      }
    }
    .navigationTitle(L("General"))
    .configSynced { syncFromConfig() }
  }

  private func syncFromConfig() {
    dualCore = DOLConfigBridge.mainCpuThread()
    cheats = DOLConfigBridge.mainEnableCheats()
    mismatchedRegion = DOLConfigBridge.mainOverrideRegionSettings()
    autoDiscChange = DOLConfigBridge.mainAutoDiscChange()
    fastDiscSpeed = DOLConfigBridge.mainFastDiscSpeed()
    dspThread = DOLConfigBridge.mainDSPThread()
    speedLimitPercent = DOLConfigBridge.mainEmulationSpeedPercent()
    // `integer(forKey:)` returns 0 both when the key is unset and when the user has
    // explicitly chosen "Unlimited" (which is stored as 0) — collapsing those cases
    // mislabels a persisted Unlimited selection as "300%" on the next sync. Use
    // `object(forKey:)` so only a truly unset key falls back to the 3x default.
    fastForwardSpeedPercent = (UserDefaults.standard.object(forKey: "fast_forward_speed_percent") as? Int) ?? 300
    let regionRaw = DOLConfigBridge.mainFallbackRegion()
    let regionVal = Region.from(raw: regionRaw)
    if regionVal == .unknown {
      fallbackRegion = .ntscU
      DOLConfigBridge.setMainFallbackRegion(Region.ntscU.rawValue)
    } else {
      fallbackRegion = regionVal
    }
  }

  private func speedLimitLabel(percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if percent == 100 { return String(format: "%d%% (%@)", percent, L("Normal Speed")) }
    return "\(percent)%"
  }

  private func fastForwardSpeedLabel(percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if percent == 100 { return String(format: "%d%% (%@)", percent, L("Normal Speed")) }
    return "\(percent)%"
  }
}

private enum Region: Int, CaseIterable { case ntscJ = 0, ntscU = 1, pal = 2, unknown = 3, ntscK = 4
  var label: String { switch self { case .ntscJ: return "NTSC-J"; case .ntscU: return "NTSC-U"; case .pal: return "PAL"; case .ntscK: return "NTSC-K"; case .unknown: return "Error" } }
  static func from(raw: Int) -> Region { Region(rawValue: raw) ?? .unknown }
}

private struct SpeedLimitPicker: View {
  @Binding var selectedPercent: Int
  @State private var showHelp = false
  var body: some View {
    List {
      SettingsSelectRow(label: L("Unlimited"), checked: selectedPercent == 0) { selectedPercent = 0 }
      ForEach(1..<21) { idx in
        let value = idx * 10
        let text = value == 100 ? String(format: "%d%% (%@)", value, L("Normal Speed")) : "\(value)%"
        SettingsSelectRow(label: text, checked: selectedPercent == value) { selectedPercent = value }
      }
    }
    .navigationTitle(L("Speed Limit"))
    .toolbar { HelpButton(helpKey:
                            "Controls how fast emulation runs relative to the original hardware.<br><br>Values higher than 100% will emulate faster than the original hardware can run, if your hardware is able to keep up. Values lower than 100% will slow emulation instead. Unlimited will emulate as fast as your hardware is able to.<br><br><dolphin_emphasis>If unsure, select 100%.</dolphin_emphasis>") }
  }
}

private struct FastForwardSpeedPicker: View {
  @Binding var selectedPercent: Int
  @State private var showHelp = false
  var body: some View {
    List {
      SettingsSelectRow(label: L("Unlimited"), checked: selectedPercent == 0) { selectedPercent = 0 }
      ForEach([200, 300, 400, 500, 600, 800, 1000], id: \.self) { value in
        let text = "\(value)% (\(value/100)x)"
        SettingsSelectRow(label: text, checked: selectedPercent == value) { selectedPercent = value }
      }
    }
    .navigationTitle(L("Fast Forward Speed"))
    .toolbar { HelpButton(helpKey:
                            "Controls the speed multiplier when fast forward is enabled.<br><br>Higher values will run the game faster, but may impact performance. 300% (3x speed) is recommended for most games.<br><br><dolphin_emphasis>If unsure, select 300% (3x).</dolphin_emphasis>") }
  }
}

private struct FallbackRegionPicker: View {
  @Binding var selected: Region
  var body: some View {
    List {
      ForEach(Region.allCases, id: \.rawValue) { r in
        SettingsSelectRow(label: r.label, checked: r == selected) { selected = r }
      }
    }
    .navigationTitle(L("Fallback Region"))
    .toolbar { HelpButton(helpKey:
                            "Sets the region used for titles whose region cannot be determined automatically.<br><br>This setting cannot be changed while emulation is active.") }
  }
}
