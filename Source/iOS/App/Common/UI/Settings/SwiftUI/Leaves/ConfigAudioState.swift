// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ConfigAudioLimits {
  static let volume: ClosedRange<Double> = 0 ... 100
  static let stretchLatencyMs: ClosedRange<Double> = 5 ... 200
}

/// Snapshot of Config for the Audio screen. Defaults match the old view's `@State` defaults.
struct ConfigAudioState: Equatable {
  /// Raw Config value; "" is the default device.
  var backend = ""
  /// Raw names from `DOLConfigBridge.audioBackends()`. The host reads them, the builder never does.
  var backends: [String] = []
  var volume = 100
  var stretch = false
  var stretchLatencyMs = 30
  var muteOnNoSpeedLimit = false
  var obeyMuteSwitch = true

  static let avAudioEngine = "AVAudioEngine"
  static let coreAudio = "CoreAudio"

  /// What the backend row shows for a raw backend name.
  static func label(forBackend raw: String) -> String {
    switch raw {
    case "": return L("Default Device")
    case coreAudio: return L("CoreAudio (Speakers/HDMI)")
    default: return raw
    }
  }

  /// (label, raw) for every listed backend; a current backend the list does not carry is inserted first.
  var backendOptions: [(String, String)] {
    var raws = backends
    if !raws.contains(backend) { raws.insert(backend, at: 0) }
    return raws.map { (Self.label(forBackend: $0), $0) }
  }

  /// AVAudioEngine is in development: choosing it asks first.
  static func needsConfirmation(choosing raw: String) -> Bool { raw == avAudioEngine }

  var showsAVAudioEngineEffects: Bool { backend.contains(Self.avAudioEngine) }
  var showsCoreAudioEffects: Bool { !showsAVAudioEngineEffects && backend.contains(Self.coreAudio) }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigAudioChange: Equatable {
  case backend(String)
  case volume(Int)
  case stretch(Bool)
  case stretchLatencyMs(Int)
  case muteOnNoSpeedLimit(Bool)
  case obeyMuteSwitch(Bool)
}
