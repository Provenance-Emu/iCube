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

// MARK: - Config Advanced (hardware overrides)

struct ConfigAdvancedView: View {
  @State private var memOverride: Bool = false
  @State private var mem1MB: Int = 24
  @State private var mem2MB: Int = 64
  @State private var rtcEnabled: Bool = false
  @State private var rtcDate: Date = Date(timeIntervalSince1970: 946684800) // 2000-01-01 UTC

  var body: some View {
    List {
      Section(
        header: Text(L("Memory Override")),
        footer: Text(L("For CPU and interpreter performance options, see Performance Tuning in Settings or Config."))
      ) {
        settingsCaption(
          Toggle(L("Enable Emulated Memory Size Override"), isOn: $memOverride.onSet { DOLConfigBridge.setMainRamOverrideEnable($0) }),
          L("Changes the emulated console's RAM. MEM1 is main memory (24–64 MB); MEM2 is Wii extended memory (64–128 MB). ⚠️ Enabling this breaks many games and invalidates save states made at a different size."))
        HStack {
          Text("MEM1")
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $mem1MB.onSet { DOLConfigBridge.setMainMem1SizeMB($0) }, range: 24 ... 64, step: 1)
#else
          Slider(value: $mem1MB.onSet { DOLConfigBridge.setMainMem1SizeMB($0) }.asDouble, in: 24 ... 64)
            .frame(width: 260)
#endif
        }
        .disabled(!memOverride)
        HStack {
          Text("MEM2")
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $mem2MB.onSet { DOLConfigBridge.setMainMem2SizeMB($0) }, range: 64 ... 128, step: 1)
#else
          Slider(value: $mem2MB.onSet { DOLConfigBridge.setMainMem2SizeMB($0) }.asDouble, in: 64 ... 128)
            .frame(width: 260)
#endif
        }
        .disabled(!memOverride)
      }

      Section(header: Text(L("Custom RTC Options"))) {
        settingsCaption(
          Toggle(L("Enable Custom RTC"), isOn: $rtcEnabled.onSet { DOLConfigBridge.setMainCustomRtcEnable($0) }),
          L("Sets a custom real-time clock for the emulated console, separate from your device clock. Useful for time-based game events. If unsure, leave off."))
#if !os(tvOS)
        DatePicker("", selection: $rtcDate.onSet { DOLConfigBridge.setMainCustomRtcValue(Int($0.timeIntervalSince1970)) }, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .disabled(!rtcEnabled)
#endif
      }
    }
    .navigationTitle(L("Advanced"))
    .configSynced { syncAdvancedHardware() }
  }

  private func syncAdvancedHardware() {
    memOverride = DOLConfigBridge.mainRamOverrideEnable()
    mem1MB = DOLConfigBridge.mainMem1SizeMB()
    mem2MB = DOLConfigBridge.mainMem2SizeMB()
    rtcEnabled = DOLConfigBridge.mainCustomRtcEnable()
    rtcDate = Date(timeIntervalSince1970: TimeInterval(DOLConfigBridge.mainCustomRtcValue()))
  }
}

/// Small green "Recommended" pill shown next to the proven default-on optimizations
/// so their on/off state is obvious at a glance.
