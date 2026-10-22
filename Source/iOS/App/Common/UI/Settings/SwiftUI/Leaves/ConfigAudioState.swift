// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ConfigAudioLimits {
  static let volume: ClosedRange<Double> = 0 ... 100
  /// MAIN_AUDIO_BUFFER_SIZE; Dolphin's own slider range.
  static let bufferMs: ClosedRange<Double> = 16 ... 200
  static let echoMs: ClosedRange<Double> = 10 ... 2000
  static let echoFeedback: ClosedRange<Double> = 0 ... 0.95
  static let crushBits: ClosedRange<Double> = 4 ... 16
  static let crushDownsample: ClosedRange<Double> = 1 ... 16
  static let eqDb: ClosedRange<Double> = -24 ... 24
}

/// The shared filter chain both backends run (MAIN_AUDIO_FX_*). Defaults match the compiled Config defaults.
struct AudioEffectsState: Equatable {
  var echoEnabled = false
  var echoMs = 200
  var echoFeedback = 0.35
  var eqEnabled = false
  var eqLowDb = 0.0
  var eqMidDb = 0.0
  var eqHighDb = 0.0
  var crushEnabled = false
  var crushBits = 16
  var crushDownsample = 1
}

/// One built-in effect's parameter page (the pause menu's Audio pane opens one per effect), or every effect.
enum AudioEffectPage: String, CaseIterable, Equatable {
  case echo
  case equalizer
  case bitcrusher
  case all

  var title: String {
    switch self {
    case .echo: return L("Echo")
    case .equalizer: return L("Equalizer")
    case .bitcrusher: return L("Bitcrusher")
    case .all: return L("Effects")
    }
  }

  /// The id of the effect's on/off row in `ConfigAudioModelBuilder.effectsSections`; nil for `all`.
  var toggleRowID: String? {
    switch self {
    case .echo: return "echo"
    case .equalizer: return "eq"
    case .bitcrusher: return "bitcrusher"
    case .all: return nil
    }
  }

  /// The ids of the effect's rows in `ConfigAudioModelBuilder.effectsSections`, toggle first; empty for `all`
  /// (which keeps every row).
  var rowIDs: [String] {
    switch self {
    case .echo: return ["echo", "echo-time", "echo-feedback"]
    case .equalizer: return ["eq", "eq-low", "eq-mid", "eq-high"]
    case .bitcrusher: return ["bitcrusher", "crush-bits", "crush-downsample"]
    case .all: return []
    }
  }

  var icon: String {
    switch self {
    case .echo: return "wave.3.right"
    case .equalizer: return "slider.vertical.3"
    case .bitcrusher: return "waveform.path"
    case .all: return "waveform"
    }
  }

  func isEnabled(in fx: AudioEffectsState) -> Bool {
    switch self {
    case .echo: return fx.echoEnabled
    case .equalizer: return fx.eqEnabled
    case .bitcrusher: return fx.crushEnabled
    case .all: return fx.echoEnabled || fx.eqEnabled || fx.crushEnabled
    }
  }

  /// The change that turns this effect on or off; nil for `all`.
  func enabledChange(_ on: Bool) -> AudioEffectsChange? {
    switch self {
    case .echo: return .echoEnabled(on)
    case .equalizer: return .eqEnabled(on)
    case .bitcrusher: return .crushEnabled(on)
    case .all: return nil
    }
  }
}

enum AudioEffectsChange: Equatable {
  case echoEnabled(Bool)
  case echoMs(Int)
  case echoFeedback(Double)
  case eqEnabled(Bool)
  case eqLowDb(Double)
  case eqMidDb(Double)
  case eqHighDb(Double)
  case crushEnabled(Bool)
  case crushBits(Int)
  case crushDownsample(Int)
}

/// What the running stream reports; read-only on the screen.
struct AudioLiveState: Equatable {
  /// "HDMI:Living Room TV", or "" when unknown.
  var routeDescription = ""
  var routeMaxChannels = 2
  var routeIsHeadphones = false
  /// "stereo", "spatial", "discrete" or "" when no stream is running.
  var outputMode = ""
  var microphoneSupported = false
  /// 0 undetermined, 1 denied, 2 granted (AudioFXBridge.microphonePermission).
  var microphonePermission = 0
}

/// Snapshot of Config for the Audio screen. Defaults match the compiled Config defaults.
struct ConfigAudioState: Equatable {
  /// Raw Config value; "" means the compiled default, CoreAudio.
  var backend = ""
  /// Raw names from `DOLConfigBridge.audioBackends()`. The host reads them, the builder never does.
  var backends: [String] = []
  var volume = 100
  var surround = false
  /// AudioCommon::DPL2Quality, 0 Lowest ... 3 Highest.
  var surroundQuality = 2
  var spatial = true
  var headTracking = true
  var bufferMs = 80
  var fillGaps = true
  var preservePitch = false
  var muteOnNoSpeedLimit = false
  var obeyMuteSwitch = true
  var effects = AudioEffectsState()
  var live = AudioLiveState()

  static let avAudioEngine = "AVAudioEngine"
  static let coreAudio = "CoreAudio"
  static let surroundQualityOptions: [(String, Int)] = [(L("Lowest"), 0), (L("Low"), 1), (L("High"), 2), (L("Highest"), 3)]

  /// What the backend row shows for a raw backend name.
  static func label(forBackend raw: String) -> String {
    switch raw {
    case "": return L("Automatic (CoreAudio)")
    case coreAudio: return L("CoreAudio (Low Latency)")
    case avAudioEngine: return L("AVAudioEngine (Spatial & Plug-ins)")
    default: return raw
    }
  }

  /// The short name a tile badge shows for a raw backend name (the pause menu's Audio pane).
  static func shortLabel(forBackend raw: String) -> String {
    switch raw {
    case "": return L("Automatic")
    case coreAudio: return L("CoreAudio")
    case avAudioEngine: return L("AVAudioEngine")
    default: return raw
    }
  }

  /// (label, raw) for every listed backend; a current backend the list does not carry is inserted first.
  var backendOptions: [(String, String)] {
    backendOptions(label: Self.label(forBackend:))
  }

  /// `backendOptions` with the short tile labels.
  var shortBackendOptions: [(String, String)] { backendOptions(label: Self.shortLabel(forBackend:)) }

  private func backendOptions(label: (String) -> String) -> [(String, String)] {
    var raws = backends
    if !raws.contains(backend) { raws.insert(backend, at: 0) }
    return raws.map { (label($0), $0) }
  }

  var isAVAudioEngine: Bool { backend == Self.avAudioEngine }
  /// Spatial rendering and Audio Unit plug-ins exist on the AVAudioEngine graph only.
  var spatialRowsEnabled: Bool { surround && isAVAudioEngine }
  var headTrackingRowEnabled: Bool { spatialRowsEnabled && spatial }

  /// The caption under the surround rows: what the current route can carry and what the stream is doing with it.
  static func outputCaption(live: AudioLiveState, surround: Bool) -> String {
    let route = live.routeDescription.isEmpty ? L("Unknown output") : live.routeDescription
    let channels = live.routeMaxChannels >= 6 ? L("up to 6 channels") : L("2 channels")
    let mode: String
    switch live.outputMode {
    case "discrete": mode = L("playing discrete 5.1")
    case "spatial": mode = L("playing spatial audio")
    case "stereo": mode = surround ? L("playing stereo (surround needs a 5.1 route or headphones on AVAudioEngine)") : L("playing stereo")
    default: mode = L("no game running")
    }
    return "\(route) · \(channels) · \(mode)"
  }

  var outputCaption: String { Self.outputCaption(live: live, surround: surround) }

  /// What the microphone section says and offers for a permission state.
  enum MicrophoneAccess: Equatable {
    case unsupported
    case ask
    case denied
    case granted
  }

  static func microphoneAccess(supported: Bool, permission: Int) -> MicrophoneAccess {
    guard supported else { return .unsupported }
    switch permission {
    case 1: return .denied
    case 2: return .granted
    default: return .ask
    }
  }

  var microphoneAccess: MicrophoneAccess { Self.microphoneAccess(supported: live.microphoneSupported, permission: live.microphonePermission) }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigAudioChange: Equatable {
  case backend(String)
  case volume(Int)
  case surround(Bool)
  case surroundQuality(Int)
  case spatial(Bool)
  case headTracking(Bool)
  case bufferMs(Int)
  case fillGaps(Bool)
  case preservePitch(Bool)
  case muteOnNoSpeedLimit(Bool)
  case obeyMuteSwitch(Bool)
  case effect(AudioEffectsChange)
  case requestMicrophoneAccess
  case openSystemSettings
}
