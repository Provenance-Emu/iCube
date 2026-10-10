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

  private let tail = ["volume", "stretch", "stretch-latency", "mute-on-no-speed-limit", "obey-mute-switch"]

  func test_rowOrder_defaultDevice_hasNoEffectsRows() {
    XCTAssertEqual(model().allItems.map(\.id), ["backend"] + tail)
    XCTAssertEqual(model().sections.map(\.id), ["backend", "volume", "stretching", "misc"])
    XCTAssertEqual(model().sections.map(\.header), [nil, nil, "Audio Stretching Settings", "Misc. Controls"])
  }

  func test_rowOrder_coreAudio_andAVAudioEngine() {
    #if os(iOS)
    let core = model(state { $0.backend = "CoreAudio" })
    XCTAssertEqual(core.allItems.map(\.id), ["backend", "coreaudio-effects"] + tail)
    XCTAssertEqual(core.section(containing: "coreaudio-effects")?.header, "CoreAudio Effects")
    XCTAssertEqual(core.section(containing: "coreaudio-effects")?.footer, "Built‑in echo, EQ, and bitcrush. Does not support AUv3 plugins.")
    let av = model(state { $0.backend = "AVAudioEngine" })
    XCTAssertEqual(av.allItems.map(\.id), ["backend", "effects-chain"] + tail)
    XCTAssertEqual(av.section(containing: "effects-chain")?.header, "Master Effects Chain")
    XCTAssertEqual(av.section(containing: "effects-chain")?.footer, "Effects apply post‑environment. Requires AVAudioEngine backend.")
    #else
    for backend in ["CoreAudio", "AVAudioEngine"] {
      XCTAssertEqual(model(state { $0.backend = backend }).allItems.map(\.id), ["backend"] + tail, backend)
    }
    #endif
  }

  func test_effectsRows_areCustomRows() {
    #if os(iOS)
    for (backend, id) in [("AVAudioEngine", "effects-chain"), ("CoreAudio", "coreaudio-effects")] {
      guard case .custom? = model(state { $0.backend = backend }).item(id: id)?.role else { XCTFail(id); continue }
    }
    #endif
  }

  func test_everyRow_hasADescription() {
    for backend in ["", "CoreAudio", "AVAudioEngine"] {
      for item in model(state { $0.backend = backend }).allItems { XCTAssertFalse((item.description ?? "").isEmpty, "\(backend) \(item.id)") }
    }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigAudioChange)] = [
      ("stretch", { .stretch($0) }), ("mute-on-no-speed-limit", { .muteOnNoSpeedLimit($0) }), ("obey-mute-switch", { .obeyMuteSwitch($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_toggleRows_reflectTheState() {
    let on = state { $0.stretch = true; $0.muteOnNoSpeedLimit = true; $0.obeyMuteSwitch = false }
    let expected: [(String, Bool)] = [("stretch", true), ("mute-on-no-speed-limit", true), ("obey-mute-switch", false)]
    for (id, value) in expected {
      guard case .toggle(let binding)? = model(on).item(id: id)?.role else { XCTFail(id); continue }
      XCTAssertEqual(binding.wrappedValue, value, id)
    }
  }

  func test_steppers_haveTheirRanges_andEmitTheirOwnChange() {
    let expected: [(String, ClosedRange<Double>, Double, ConfigAudioChange)] = [
      ("volume", 0 ... 100, 40, .volume(40)),
      ("stretch-latency", 5 ... 200, 120, .stretchLatencyMs(120)),
    ]
    let m = model(state { $0.stretch = true })
    for (id, range, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      XCTAssertEqual(stepper.step, 1, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_steppers_formatTheirValue() {
    let m = model(state { $0.volume = 85; $0.stretchLatencyMs = 30 })
    XCTAssertEqual(m.item(id: "volume")?.currentValueTitle, "85%")
    XCTAssertEqual(m.item(id: "stretch-latency")?.currentValueTitle, "30 ms")
  }

  func test_stretchLatency_isDisabledUntilStretchIsOn() {
    XCTAssertEqual(model().item(id: "stretch-latency")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.stretch = true }).item(id: "stretch-latency")?.isEnabled, true)
    XCTAssertEqual(model().item(id: "stretch")?.isEnabled, true)
  }

  func test_backendRow_isADirectPicker_notACycle() {
    guard case .picker? = model().item(id: "backend")?.role else { return XCTFail("not a picker") }
  }

  func test_backendPicker_emitsTheRawName() {
    let m = model(state { $0.backends = ["AVAudioEngine", "CoreAudio"] })
    guard case .picker(let options, let selection)? = m.item(id: "backend")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map(\.0), ["Default Device", "AVAudioEngine", "CoreAudio (Speakers/HDMI)"])
    XCTAssertEqual(options.map { $0.1.base as? String }, ["", "AVAudioEngine", "CoreAudio"])
    changes = []
    selection.wrappedValue = AnyHashable("CoreAudio")
    XCTAssertEqual(changes, [.backend("CoreAudio")])
  }

  func test_backendRow_showsTheStoredBackendsLabel() {
    let cases: [(String, String)] = [("", "Default Device"), ("AVAudioEngine", "AVAudioEngine"), ("CoreAudio", "CoreAudio (Speakers/HDMI)"), ("Other", "Other")]
    for (raw, title) in cases {
      let s = state { $0.backends = ["AVAudioEngine", "CoreAudio"]; $0.backend = raw }
      XCTAssertEqual(model(s).item(id: "backend")?.currentValueTitle, title, raw)
    }
  }

  func test_labelForBackend_table() {
    let cases: [(String, String)] = [
      ("", "Default Device"), ("AVAudioEngine", "AVAudioEngine"), ("CoreAudio", "CoreAudio (Speakers/HDMI)"), ("Cubeb", "Cubeb"),
    ]
    for (raw, label) in cases { XCTAssertEqual(ConfigAudioState.label(forBackend: raw), label, raw) }
  }

  func test_backendOptions_insertAnUnlistedCurrentBackendFirst() {
    let unlisted = state { $0.backends = ["CoreAudio"]; $0.backend = "" }.backendOptions
    XCTAssertEqual(unlisted.map(\.0), ["Default Device", "CoreAudio (Speakers/HDMI)"])
    XCTAssertEqual(unlisted.map(\.1), ["", "CoreAudio"])
    let listed = state { $0.backends = ["", "CoreAudio"]; $0.backend = "CoreAudio" }.backendOptions
    XCTAssertEqual(listed.map(\.1), ["", "CoreAudio"])
    XCTAssertEqual(ConfigAudioState().backendOptions.map(\.1), [""])
  }

  func test_needsConfirmation_isTrueOnlyForAVAudioEngine() {
    XCTAssertTrue(ConfigAudioState.needsConfirmation(choosing: "AVAudioEngine"))
    for raw in ["", "CoreAudio", "Cubeb"] { XCTAssertFalse(ConfigAudioState.needsConfirmation(choosing: raw), raw) }
  }

  func test_choice_table() {
    let cases: [(String, String, ConfigAudioState.BackendChoice)] = [
      ("", "CoreAudio", .commit), ("CoreAudio", "", .commit), ("", "AVAudioEngine", .confirm),
      ("CoreAudio", "AVAudioEngine", .confirm), ("AVAudioEngine", "AVAudioEngine", .ignore),
      ("CoreAudio", "CoreAudio", .ignore), ("AVAudioEngine", "CoreAudio", .commit),
    ]
    for (current, raw, expected) in cases {
      XCTAssertEqual(state { $0.backend = current }.choice(for: raw), expected, "\(current) -> \(raw)")
    }
  }

  func test_effectsVisibility_followsTheBackend() {
    let cases: [(String, Bool, Bool)] = [("", false, false), ("CoreAudio", false, true), ("AVAudioEngine", true, false)]
    for (backend, av, core) in cases {
      let s = state { $0.backend = backend }
      XCTAssertEqual(s.showsAVAudioEngineEffects, av, backend)
      XCTAssertEqual(s.showsCoreAudioEffects, core, backend)
    }
  }

  func test_defaults_matchTheOldViewsState() {
    let s = ConfigAudioState()
    XCTAssertEqual(s.backend, "")
    XCTAssertEqual(s.volume, 100)
    XCTAssertFalse(s.stretch)
    XCTAssertEqual(s.stretchLatencyMs, 30)
    XCTAssertFalse(s.muteOnNoSpeedLimit)
    XCTAssertTrue(s.obeyMuteSwitch)
  }
}
