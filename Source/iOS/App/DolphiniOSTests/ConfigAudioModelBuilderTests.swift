// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigAudioModelBuilderTests: XCTestCase {
  private var changes: [ConfigAudioChange] = []
  private func model(_ state: ConfigAudioState = ConfigAudioState()) -> MenuModel {
    ConfigAudioModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout ConfigAudioState) -> Void) -> ConfigAudioState {
    var s = ConfigAudioState()
    edit(&s)
    return s
  }

  private let surroundRows = ["surround", "surround-quality", "spatial", "head-tracking", "output-caption"]
  private let effectRows = ["echo", "echo-time", "echo-feedback", "eq", "eq-low", "eq-mid", "eq-high", "bitcrusher", "crush-bits", "crush-downsample"]
  private let timingRows = ["buffer", "fill-gaps", "preserve-pitch"]
  private var miscRows: [String] {
    #if os(iOS)
    return ["mute-on-no-speed-limit", "obey-mute-switch"]
    #else
    return ["mute-on-no-speed-limit"]
    #endif
  }

  func test_rowOrder_coreAudio() {
    let m = model(state { $0.backend = "CoreAudio" })
    XCTAssertEqual(m.allItems.map(\.id), ["backend", "volume"] + surroundRows + effectRows + timingRows + miscRows + ["microphone-unsupported"])
    XCTAssertEqual(m.sections.map(\.id), ["output", "surround", "effects", "timing", "misc", "microphone"])
    XCTAssertEqual(m.sections.map(\.header), ["Output", "Surround & Spatial", "Effects", "Timing", "Misc. Controls", "Microphone"])
  }

  func test_pluginChain_onlyOnAVAudioEngine_andOnlyOniOS() {
    let av = model(state { $0.backend = "AVAudioEngine" })
    #if os(iOS)
    XCTAssertEqual(av.sections.map(\.id), ["output", "surround", "effects", "plugins", "timing", "misc", "microphone"])
    XCTAssertEqual(av.section(containing: "plugin-chain")?.footer, ConfigAudioModelBuilder.pluginFooter)
    guard case .custom? = av.item(id: "plugin-chain")?.role else { return XCTFail("plugin-chain is not a custom row") }
    #else
    XCTAssertEqual(av.sections.map(\.id), ["output", "surround", "effects", "timing", "misc", "microphone"])
    #endif
    XCTAssertNil(model(state { $0.backend = "CoreAudio" }).item(id: "plugin-chain"))
  }

  func test_effectsModel_isJustTheEffectSections() {
    let m = ConfigAudioModelBuilder.effectsModel(state: state { $0.backend = "CoreAudio" }) { self.changes.append($0) }
    XCTAssertEqual(m.sections.map(\.id), ["effects"])
    XCTAssertEqual(m.allItems.map(\.id), effectRows)
  }

  func test_everyRow_hasADescription() {
    for backend in ["", "CoreAudio", "AVAudioEngine"] {
      for item in model(state { $0.backend = backend }).allItems { XCTAssertFalse((item.description ?? "").isEmpty, "\(backend) \(item.id)") }
    }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    var expected: [(String, (Bool) -> ConfigAudioChange)] = [
      ("surround", { .surround($0) }), ("spatial", { .spatial($0) }), ("head-tracking", { .headTracking($0) }),
      ("fill-gaps", { .fillGaps($0) }), ("preserve-pitch", { .preservePitch($0) }),
      ("mute-on-no-speed-limit", { .muteOnNoSpeedLimit($0) }),
      ("echo", { .effect(.echoEnabled($0)) }), ("eq", { .effect(.eqEnabled($0)) }), ("bitcrusher", { .effect(.crushEnabled($0)) }),
    ]
    #if os(iOS)
    expected.append(("obey-mute-switch", { .obeyMuteSwitch($0) }))
    #endif
    let m = model(state { $0.backend = "AVAudioEngine"; $0.surround = true })
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_steppers_haveTheirRanges_andEmitTheirOwnChange() {
    let expected: [(String, ClosedRange<Double>, Double, Double, ConfigAudioChange)] = [
      ("volume", 0 ... 100, 1, 40, .volume(40)),
      ("buffer", 16 ... 200, 1, 120, .bufferMs(120)),
      ("echo-time", 10 ... 2000, 10, 500, .effect(.echoMs(500))),
      ("echo-feedback", 0 ... 0.95, 0.05, 0.5, .effect(.echoFeedback(0.5))),
      ("eq-low", -24 ... 24, 1, 6, .effect(.eqLowDb(6))),
      ("eq-mid", -24 ... 24, 1, -3, .effect(.eqMidDb(-3))),
      ("eq-high", -24 ... 24, 1, 2, .effect(.eqHighDb(2))),
      ("crush-bits", 4 ... 16, 1, 8, .effect(.crushBits(8))),
      ("crush-downsample", 1 ... 16, 1, 4, .effect(.crushDownsample(4))),
    ]
    let m = model(state { $0.effects.echoEnabled = true; $0.effects.eqEnabled = true; $0.effects.crushEnabled = true })
    for (id, range, step, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      XCTAssertEqual(stepper.step, step, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_steppers_formatTheirValue() {
    let m = model(state { $0.volume = 85; $0.bufferMs = 80; $0.effects.echoMs = 250; $0.effects.echoFeedback = 0.35; $0.effects.eqLowDb = 6; $0.effects.crushBits = 12; $0.effects.crushDownsample = 3 })
    XCTAssertEqual(m.item(id: "volume")?.currentValueTitle, "85%")
    XCTAssertEqual(m.item(id: "buffer")?.currentValueTitle, "80 ms")
    XCTAssertEqual(m.item(id: "echo-time")?.currentValueTitle, "250 ms")
    XCTAssertEqual(m.item(id: "echo-feedback")?.currentValueTitle, "35%")
    XCTAssertEqual(m.item(id: "eq-low")?.currentValueTitle, "+6 dB")
    XCTAssertEqual(m.item(id: "crush-bits")?.currentValueTitle, "12")
    XCTAssertEqual(m.item(id: "crush-downsample")?.currentValueTitle, "3x")
  }

  func test_dependentRows_followTheirMasterToggle() {
    let off = model()
    for id in ["surround-quality", "spatial", "head-tracking", "echo-time", "echo-feedback", "eq-low", "eq-mid", "eq-high", "crush-bits", "crush-downsample"] {
      XCTAssertEqual(off.item(id: id)?.isEnabled, false, id)
    }
    let on = model(state { $0.backend = "AVAudioEngine"; $0.surround = true; $0.effects.echoEnabled = true; $0.effects.eqEnabled = true; $0.effects.crushEnabled = true })
    for id in ["surround-quality", "spatial", "head-tracking", "echo-time", "echo-feedback", "eq-low", "eq-mid", "eq-high", "crush-bits", "crush-downsample"] {
      XCTAssertEqual(on.item(id: id)?.isEnabled, true, id)
    }
  }

  func test_spatialRows_needTheAVAudioEngineBackend() {
    let core = model(state { $0.backend = "CoreAudio"; $0.surround = true })
    XCTAssertEqual(core.item(id: "surround-quality")?.isEnabled, true)
    XCTAssertEqual(core.item(id: "spatial")?.isEnabled, false)
    XCTAssertEqual(core.item(id: "head-tracking")?.isEnabled, false)
    let noTracking = model(state { $0.backend = "AVAudioEngine"; $0.surround = true; $0.spatial = false })
    XCTAssertEqual(noTracking.item(id: "spatial")?.isEnabled, true)
    XCTAssertEqual(noTracking.item(id: "head-tracking")?.isEnabled, false)
  }

  func test_backendRow_isADirectPicker_thatEmitsTheRawName() {
    let m = model(state { $0.backends = ["AVAudioEngine", "CoreAudio"] })
    guard case .picker(let options, let selection)? = m.item(id: "backend")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map(\.0), ["Automatic (CoreAudio)", "AVAudioEngine (Spatial & Plug-ins)", "CoreAudio (Low Latency)"])
    XCTAssertEqual(options.map { $0.1.base as? String }, ["", "AVAudioEngine", "CoreAudio"])
    changes = []
    selection.wrappedValue = AnyHashable("CoreAudio")
    XCTAssertEqual(changes, [.backend("CoreAudio")])
  }

  func test_surroundQuality_isAPicker_overTheFourQualities() {
    let m = model(state { $0.surround = true; $0.surroundQuality = 3 })
    guard case .picker(let options, let selection)? = m.item(id: "surround-quality")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map(\.0), ["Lowest", "Low", "High", "Highest"])
    XCTAssertEqual(selection.wrappedValue.base as? Int, 3)
    changes = []
    selection.wrappedValue = AnyHashable(1)
    XCTAssertEqual(changes, [.surroundQuality(1)])
  }

  func test_labelForBackend_table() {
    let cases: [(String, String)] = [
      ("", "Automatic (CoreAudio)"), ("AVAudioEngine", "AVAudioEngine (Spatial & Plug-ins)"), ("CoreAudio", "CoreAudio (Low Latency)"), ("Cubeb", "Cubeb"),
    ]
    for (raw, label) in cases { XCTAssertEqual(ConfigAudioState.label(forBackend: raw), label, raw) }
  }

  func test_backendOptions_insertAnUnlistedCurrentBackendFirst() {
    let unlisted = state { $0.backends = ["CoreAudio"]; $0.backend = "" }.backendOptions
    XCTAssertEqual(unlisted.map(\.1), ["", "CoreAudio"])
    let listed = state { $0.backends = ["", "CoreAudio"]; $0.backend = "CoreAudio" }.backendOptions
    XCTAssertEqual(listed.map(\.1), ["", "CoreAudio"])
  }

  func test_outputCaption_table() {
    var live = AudioLiveState()
    live.routeDescription = "HDMI:Living Room TV"
    live.routeMaxChannels = 6
    live.outputMode = "discrete"
    XCTAssertEqual(ConfigAudioState.outputCaption(live: live, surround: true), "HDMI:Living Room TV · up to 6 channels · playing discrete 5.1")
    live.routeDescription = "BluetoothA2DP:AirPods Pro"
    live.routeMaxChannels = 2
    live.outputMode = "spatial"
    XCTAssertEqual(ConfigAudioState.outputCaption(live: live, surround: true), "BluetoothA2DP:AirPods Pro · 2 channels · playing spatial audio")
    live.outputMode = "stereo"
    XCTAssertEqual(ConfigAudioState.outputCaption(live: live, surround: false), "BluetoothA2DP:AirPods Pro · 2 channels · playing stereo")
    XCTAssertEqual(ConfigAudioState.outputCaption(live: live, surround: true), "BluetoothA2DP:AirPods Pro · 2 channels · playing stereo (surround needs a 5.1 route or headphones on AVAudioEngine)")
    live.routeDescription = ""
    live.outputMode = ""
    XCTAssertEqual(ConfigAudioState.outputCaption(live: live, surround: false), "Unknown output · 2 channels · no game running")
  }

  func test_microphoneSection_followsSupportAndPermission() {
    XCTAssertEqual(ConfigAudioState.microphoneAccess(supported: false, permission: 2), .unsupported)
    XCTAssertEqual(ConfigAudioState.microphoneAccess(supported: true, permission: 0), .ask)
    XCTAssertEqual(ConfigAudioState.microphoneAccess(supported: true, permission: 1), .denied)
    XCTAssertEqual(ConfigAudioState.microphoneAccess(supported: true, permission: 2), .granted)

    let ask = model(state { $0.live.microphoneSupported = true; $0.live.microphonePermission = 0 })
    guard case .action(let run)? = ask.item(id: "microphone-request")?.role else { return XCTFail("not an action") }
    changes = []
    run()
    XCTAssertEqual(changes, [.requestMicrophoneAccess])

    let denied = model(state { $0.live.microphoneSupported = true; $0.live.microphonePermission = 1 })
    guard case .action(let open)? = denied.item(id: "microphone-settings")?.role else { return XCTFail("not an action") }
    changes = []
    open()
    XCTAssertEqual(changes, [.openSystemSettings])

    let granted = model(state { $0.live.microphoneSupported = true; $0.live.microphonePermission = 2 })
    XCTAssertEqual(granted.section(containing: "microphone-granted")?.id, "microphone")
    XCTAssertEqual(granted.item(id: "microphone-granted")?.isEnabled, false)
  }

  func test_defaults_matchTheCompiledConfig() {
    let s = ConfigAudioState()
    XCTAssertEqual(s.backend, "")
    XCTAssertEqual(s.volume, 100)
    XCTAssertFalse(s.surround)
    XCTAssertTrue(s.spatial)
    XCTAssertTrue(s.headTracking)
    XCTAssertEqual(s.bufferMs, 80)
    XCTAssertTrue(s.fillGaps)
    XCTAssertFalse(s.preservePitch)
    XCTAssertFalse(s.muteOnNoSpeedLimit)
    XCTAssertTrue(s.obeyMuteSwitch)
    XCTAssertEqual(s.effects, AudioEffectsState())
    XCTAssertEqual(s.effects.echoMs, 200)
    XCTAssertEqual(s.effects.echoFeedback, 0.35)
    XCTAssertEqual(s.effects.crushBits, 16)
    XCTAssertEqual(s.effects.crushDownsample, 1)
  }
}
