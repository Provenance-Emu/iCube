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

// MARK: - Performance A/B harness
//
// Why this exists: the adaptive clock auto-tunes the emulated CPU/VI clock to hold a fixed "speed%",
// which means it ABSORBS interpreter optimizations (a faster core just lets it raise the clock) — so
// toggling opts looked like it did nothing. To A/B honestly you must (a) turn the adaptive clock OFF and
// pin 100% clocks so speed% reflects raw interpreter throughput, then (b) flip one variable at a time and
// relaunch. This screen makes that one tap each, plus named snapshots to capture/restore whole configs.

/// One captured performance configuration. Stored as JSON in UserDefaults.
struct PerfSnapshot: Codable, Identifiable {
  var id = UUID()
  var name: String
  var bools: [String: Bool]
  var cpuEngine: Int
  var overclockEnable: Bool
  var overclockPercent: Int
  var viOverclockEnable: Bool
  var viOverclockPercent: Int
  var adaptiveClock: Bool
}

enum PerfAB {
  // The optimization flags captured by a snapshot. Each entry knows how to read/write its bridge value,
  // so capture/apply iterate one table instead of repeating 25 getters/setters.
  struct Flag { let key: String; let get: () -> Bool; let set: (Bool) -> Void }
  static let flags: [Flag] = [
    Flag(key: "blockLinking", get: { DOLConfigBridge.cirBlockLinking() }, set: { DOLConfigBridge.setCirBlockLinking($0) }),
    Flag(key: "dynLinking", get: { DOLConfigBridge.cirDynLinking() }, set: { DOLConfigBridge.setCirDynLinking($0) }),
    Flag(key: "picLoadStore", get: { DOLConfigBridge.cirPicLoadStore() }, set: { DOLConfigBridge.setCirPicLoadStore($0) }),
    Flag(key: "specializedOps", get: { DOLConfigBridge.cirSpecializedOps() }, set: { DOLConfigBridge.setCirSpecializedOps($0) }),
    Flag(key: "specializedFpLs", get: { DOLConfigBridge.cirSpecializedFpLs() }, set: { DOLConfigBridge.setCirSpecializedFpLs($0) }),
    Flag(key: "specializedPsq", get: { DOLConfigBridge.cirSpecializedPsq() }, set: { DOLConfigBridge.setCirSpecializedPsq($0) }),
    Flag(key: "specializedFpArith", get: { DOLConfigBridge.cirSpecializedFpArith() }, set: { DOLConfigBridge.setCirSpecializedFpArith($0) }),
    Flag(key: "microOpFusion", get: { DOLConfigBridge.cirMicroOpFusion() }, set: { DOLConfigBridge.setCirMicroOpFusion($0) }),
    Flag(key: "deadFlagElim", get: { DOLConfigBridge.cirDeadFlagElim() }, set: { DOLConfigBridge.setCirDeadFlagElim($0) }),
    Flag(key: "deadFprfElim", get: { DOLConfigBridge.cirDeadFprfElim() }, set: { DOLConfigBridge.setCirDeadFprfElim($0) }),
    Flag(key: "psqFastPath", get: { DOLConfigBridge.cirPsqFastPath() }, set: { DOLConfigBridge.setCirPsqFastPath($0) }),
    Flag(key: "storeLoopFF", get: { DOLConfigBridge.cirStoreLoopFF() }, set: { DOLConfigBridge.setCirStoreLoopFF($0) }),
    Flag(key: "cacheLoopFF", get: { DOLConfigBridge.cirCacheLoopFF() }, set: { DOLConfigBridge.setCirCacheLoopFF($0) }),
    Flag(key: "psNeon", get: { DOLConfigBridge.cirPsNeon() }, set: { DOLConfigBridge.setCirPsNeon($0) }),
    Flag(key: "irConstFusion", get: { DOLConfigBridge.cirIrConstFusion() }, set: { DOLConfigBridge.setCirIrConstFusion($0) }),
    Flag(key: "irMicroOpFusion", get: { DOLConfigBridge.cirIrMicroOpFusion() }, set: { DOLConfigBridge.setCirIrMicroOpFusion($0) }),
    Flag(key: "irDeadFlagElim", get: { DOLConfigBridge.cirIrDeadFlagElim() }, set: { DOLConfigBridge.setCirIrDeadFlagElim($0) }),
    // Validators (captured so a snapshot restores them too; normally all off).
    Flag(key: "specializedOpsValidate", get: { DOLConfigBridge.cirSpecializedOpsValidate() }, set: { DOLConfigBridge.setCirSpecializedOpsValidate($0) }),
    Flag(key: "microOpFusionValidate", get: { DOLConfigBridge.cirMicroOpFusionValidate() }, set: { DOLConfigBridge.setCirMicroOpFusionValidate($0) }),
    Flag(key: "deadFlagElimValidate", get: { DOLConfigBridge.cirDeadFlagElimValidate() }, set: { DOLConfigBridge.setCirDeadFlagElimValidate($0) }),
    Flag(key: "deadFprfElimValidate", get: { DOLConfigBridge.cirDeadFprfElimValidate() }, set: { DOLConfigBridge.setCirDeadFprfElimValidate($0) }),
    Flag(key: "psqFastPathValidate", get: { DOLConfigBridge.cirPsqFastPathValidate() }, set: { DOLConfigBridge.setCirPsqFastPathValidate($0) }),
    Flag(key: "storeLoopFFValidate", get: { DOLConfigBridge.cirStoreLoopFFValidate() }, set: { DOLConfigBridge.setCirStoreLoopFFValidate($0) }),
    Flag(key: "cacheLoopFFValidate", get: { DOLConfigBridge.cirCacheLoopFFValidate() }, set: { DOLConfigBridge.setCirCacheLoopFFValidate($0) }),
    Flag(key: "irConstFusionValidate", get: { DOLConfigBridge.cirIrConstFusionValidate() }, set: { DOLConfigBridge.setCirIrConstFusionValidate($0) }),
    Flag(key: "psNeonValidate", get: { DOLConfigBridge.cirPsNeonValidate() }, set: { DOLConfigBridge.setCirPsNeonValidate($0) }),
    Flag(key: "irMicroOpFusionValidate", get: { DOLConfigBridge.cirIrMicroOpFusionValidate() }, set: { DOLConfigBridge.setCirIrMicroOpFusionValidate($0) }),
    Flag(key: "irDeadFlagElimValidate", get: { DOLConfigBridge.cirIrDeadFlagElimValidate() }, set: { DOLConfigBridge.setCirIrDeadFlagElimValidate($0) }),
    Flag(key: "irPicLoadStoreValidate", get: { DOLConfigBridge.cirIrPicLoadStoreValidate() }, set: { DOLConfigBridge.setCirIrPicLoadStoreValidate($0) }),
    Flag(key: "irSpecializedOpsValidate", get: { DOLConfigBridge.cirIrSpecializedOpsValidate() }, set: { DOLConfigBridge.setCirIrSpecializedOpsValidate($0) }),
    Flag(key: "blockLinkingValidate", get: { DOLConfigBridge.cirBlockLinkingValidate() }, set: { DOLConfigBridge.setCirBlockLinkingValidate($0) }),
  ]
  // The four proven default-on wins; everything else is experimental.
  static let recommendedOn: Set<String> = ["blockLinking", "picLoadStore", "specializedOps", "microOpFusion"]

  static let storeKey = "icube.perfSnapshots"

  static func capture(name: String) -> PerfSnapshot {
    var bools: [String: Bool] = [:]
    for f in flags { bools[f.key] = f.get() }
    return PerfSnapshot(
      name: name, bools: bools, cpuEngine: DOLConfigBridge.mainCpuCore(),
      overclockEnable: DOLConfigBridge.mainOverclockEnable(), overclockPercent: DOLConfigBridge.mainOverclockPercent(),
      viOverclockEnable: DOLConfigBridge.mainViOverclockEnable(), viOverclockPercent: DOLConfigBridge.mainViOverclockPercent(),
      adaptiveClock: UserDefaults.standard.bool(forKey: "adaptive_clock_enable"))
  }

  static func apply(_ s: PerfSnapshot) {
    for f in flags { if let v = s.bools[f.key] { f.set(v) } }
    DOLConfigBridge.setMainCpuCore(s.cpuEngine)
    DOLConfigBridge.setMainOverclockEnable(s.overclockEnable)
    DOLConfigBridge.setMainOverclockPercent(s.overclockPercent)
    DOLConfigBridge.setMainViOverclockEnable(s.viOverclockEnable)
    DOLConfigBridge.setMainViOverclockPercent(s.viOverclockPercent)
    UserDefaults.standard.set(s.adaptiveClock, forKey: "adaptive_clock_enable")
    DOLConfigBridge.flushSettingsToDisk()
  }

  // Preset: honest benchmark base — adaptive clock OFF, 100% CPU + VI clocks, so speed% reflects raw
  // interpreter throughput instead of the adaptive controller's fixed-speed illusion.
  static func applyBenchmarkBase() {
    UserDefaults.standard.set(false, forKey: "adaptive_clock_enable")
    DOLConfigBridge.setMainOverclockEnable(false)
    DOLConfigBridge.setMainOverclockPercent(100)
    DOLConfigBridge.setMainViOverclockEnable(false)
    DOLConfigBridge.setMainViOverclockPercent(100)
    DOLConfigBridge.flushSettingsToDisk()
  }

  private static func setExperimentalAndValidatorsOff() {
    for f in flags where !recommendedOn.contains(f.key) { f.set(false) }
  }
  static func applyAllOptimizationsOn() {
    for k in recommendedOn { flags.first { $0.key == k }?.set(true) }
    setExperimentalAndValidatorsOff()
    DOLConfigBridge.flushSettingsToDisk()
  }
  static func applyAllOptimizationsOff() {
    for f in flags { f.set(false) }
    DOLConfigBridge.flushSettingsToDisk()
  }

  static func load() -> [PerfSnapshot] {
    guard let data = UserDefaults.standard.data(forKey: storeKey),
          let list = try? JSONDecoder().decode([PerfSnapshot].self, from: data) else { return [] }
    return list
  }
  static func save(_ list: [PerfSnapshot]) {
    if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: storeKey) }
  }
}

struct PerformanceABView: View {
  @State private var snapshots: [PerfSnapshot] = PerfAB.load()
  @State private var newName: String = ""
  @State private var lastAction: String = ""

  var body: some View {
    List {
      Section(header: Text(L("Honest Benchmarking")),
              footer: Text(L("The adaptive clock auto-tunes the emulated clock to hold a fixed speed%, which hides (and absorbs) CPU optimizations. Apply the benchmark base first so speed% in the perf HUD reflects raw interpreter throughput, then flip ONE optimization and relaunch the game to compare. Changes take effect on the next game launch."))) {
        Button(L("Apply Benchmark Base (adaptive OFF, 100% clocks)")) {
          PerfAB.applyBenchmarkBase(); lastAction = L("Benchmark base applied — relaunch the game.")
        }
        Button(L("All Optimizations ON (recommended)")) {
          PerfAB.applyAllOptimizationsOn(); lastAction = L("Recommended optimizations on — relaunch the game.")
        }
        Button(L("All Optimizations OFF (bare baseline)")) {
          PerfAB.applyAllOptimizationsOff(); lastAction = L("All optimizations off — relaunch the game.")
        }
        if !lastAction.isEmpty {
          Text(lastAction).font(.caption).foregroundStyle(.secondary)
        }
      }

      Section(header: Text(L("Snapshots"))) {
        HStack {
          TextField(L("Snapshot name"), text: $newName)
          Button(L("Save Current")) {
            let name = newName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            snapshots.removeAll { $0.name == name }
            snapshots.append(PerfAB.capture(name: name))
            PerfAB.save(snapshots); newName = ""; lastAction = L("Saved snapshot: ") + name
          }
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if snapshots.isEmpty {
          Text(L("No snapshots yet. Save your current settings to compare configurations quickly."))
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(snapshots) { snap in
          HStack {
            VStack(alignment: .leading) {
              Text(snap.name)
              Text(snapshotSummary(snap)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Apply")) { PerfAB.apply(snap); lastAction = L("Applied: ") + snap.name + L(" — relaunch the game.") }
              .buttonStyle(.borderless)
          }
        }
        .onDelete { idx in snapshots.remove(atOffsets: idx); PerfAB.save(snapshots) }
      }
    }
    .navigationTitle(L("Performance A/B"))
  }

  private func snapshotSummary(_ s: PerfSnapshot) -> String {
    let on = PerfAB.flags.filter { s.bools[$0.key] == true }.count
    let adaptive = s.adaptiveClock ? L("adaptive") : "\(s.overclockPercent)%cpu/\(s.viOverclockPercent)%vi"
    return "engine \(s.cpuEngine) · \(on) opts on · \(adaptive)"
  }
}
