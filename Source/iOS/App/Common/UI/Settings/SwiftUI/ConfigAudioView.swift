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

struct ConfigAudioView: View {
  @State private var backend: String = ""
  @State private var availableBackends: [String] = []
  @State private var volume: Int = 100
  @State private var stretch: Bool = false
  @State private var stretchLatency: Int = 30
  @State private var muteOnNoSpeedLimit: Bool = false
  @State private var obeyMuteSwitch: Bool = true

  var body: some View {
    List {
      Section(header: Text(L("Audio Backend"))) {
        NavigationLink(backend.isEmpty ? L("Default Device") : (backend == "AVAudioEngine" ? "AVAudioEngine" : (backend == "CoreAudio" ? "CoreAudio (Speakers/HDMI)" : backend)), destination: BackendPickerView(selected: $backend, options: availableBackends))
          .onChange(of: backend) { DOLConfigBridge.setAudioBackend($0) }
        Text(L("CoreAudio: Best for TV/HDMI speakers. AVAudioEngine: Enables AUv3 FXs."))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

#if os(iOS)
      if backend.contains("AVAudioEngine") {
        Section(header: Text(L("Master Effects Chain")), footer: Text(L("Effects apply post‑environment. Requires AVAudioEngine backend."))) {
          VStack { FXChainEditor() }
        }
      } else if backend.contains("CoreAudio") {
        Section(header: Text(L("CoreAudio Effects")), footer: Text(L("Built‑in echo, EQ, and bitcrush. Does not support AUv3 plugins."))) {
          CoreAudioDSPEditor(embedded: true)
        }
      }
#endif

      Section(header: Text(L("Volume"))) {
        HStack {
#if os(tvOS)
          TVIntStepper(value: $volume, range: 0...100, step: 1)
#else
          Slider(value: Binding(get: { Double(volume) }, set: { volume = Int($0) }), in: 0...100)
            .frame(width: 260)
#endif
          Spacer()
          Text("\(volume)%").foregroundStyle(.secondary)
        }
        .onChange(of: volume) { DOLConfigBridge.setAudioVolume($0) }
      }

      Section(header: Text(L("Audio Stretching Settings"))) {
        Toggle(L("Enable Audio Stretching"), isOn: $stretch)
          .onChange(of: stretch) { DOLConfigBridge.setAudioStretch($0) }
        HStack {
#if os(tvOS)
          TVIntStepper(value: $stretchLatency, range: 5...200, step: 1)
#else
          Slider(value: Binding(get: { Double(stretchLatency) }, set: { stretchLatency = Int($0) }), in: 5...200)
            .frame(width: 260)
#endif
          Spacer()
          Text(String(format: L("%1$ld ms"), stretchLatency)).foregroundStyle(.secondary)
        }
        .disabled(!stretch)
        .onChange(of: stretchLatency) { DOLConfigBridge.setAudioStretchLatencyMs($0) }
      }

      Section(header: Text(L("Misc. Controls"))) {
        Toggle(L("Mute When Disabling Speed Limit"), isOn: $muteOnNoSpeedLimit)
          .onChange(of: muteOnNoSpeedLimit) { DOLConfigBridge.setAudioMuteOnDisabledSpeedLimit($0) }
        Toggle(L("Use Mute Hardware Switch"), isOn: $obeyMuteSwitch)
          .onChange(of: obeyMuteSwitch) { DOLConfigBridge.setAudioMuteSwitchObey($0) }
      }
    }
    .navigationTitle(L("Audio"))
    .configSynced { syncAudio() }
  }

  private func syncAudio() {
    availableBackends = DOLConfigBridge.audioBackends()
    // Annotate entries to surface capabilities
    availableBackends = availableBackends.map { b in
      if b == "AVAudioEngine" { return "AVAudioEngine" }
      if b == "CoreAudio" { return "CoreAudio (Speakers/HDMI)" }
      return b
    }
    backend = DOLConfigBridge.audioBackend()
    // keep raw key for logic; present annotated in UI rows only
    volume = DOLConfigBridge.audioVolume()
    stretch = DOLConfigBridge.audioStretch()
    stretchLatency = DOLConfigBridge.audioStretchLatencyMs()
    muteOnNoSpeedLimit = DOLConfigBridge.audioMuteOnDisabledSpeedLimit()
    obeyMuteSwitch = DOLConfigBridge.audioMuteSwitchObey()
  }
}

private struct BackendPickerView: View {
  @Binding var selected: String
  let options: [String]
  @State private var pendingSelection: String? = nil
  @State private var showConfirm: Bool = false
  var body: some View {
    List {
      ForEach(options, id: \.self) { opt in
        SelectRow(label: opt, checked: opt == selected) {
          // Strip annotation before passing to bridge
          var raw = opt.replacingOccurrences(of: " (Supports Spatial Audio)", with: "")
          raw = raw.replacingOccurrences(of: " (Speakers/HDMI)", with: "")
          if raw == "AVAudioEngine" {
            pendingSelection = opt
            showConfirm = true
          } else {
            selected = opt
            DOLConfigBridge.setAudioBackend(raw)
          }
        }
      }
    }
    .navigationTitle(L("Audio Backend"))
    .alert(L("Enable AVAudioEngine?"), isPresented: $showConfirm) {
      Button(L("Enable")) {
        if let opt = pendingSelection {
          selected = opt
          var raw = opt.replacingOccurrences(of: " (Supports Spatial Audio)", with: "")
          raw = raw.replacingOccurrences(of: " (Speakers/HDMI)", with: "")
          DOLConfigBridge.setAudioBackend(raw)
        }
        pendingSelection = nil
      }
      Button(L("Cancel"), role: .cancel) { pendingSelection = nil }
    } message: {
      Text(L("AVAudioEngine is in development and not recommended for general usage yet. Are you sure?"))
    }
  }
}
/// GameCube config placeholder
