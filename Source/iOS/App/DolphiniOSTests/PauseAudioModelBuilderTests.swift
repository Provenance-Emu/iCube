// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// The pause menu's Audio pane: Volume and Mute as the prominent row, then Output, Effects and the full settings.
final class PauseAudioModelBuilderTests: XCTestCase {
  private final class Box { var value: AnyHashable; init(_ v: AnyHashable) { value = v } }
  private var opened: [AudioEffectPage] = []
  private var pages: [String] = []

  private func bindings(volume: Box = Box(100), muted: Box = Box(false), backend: Box = Box(""), surround: Box = Box(false),
                        effects: Box = Box([String: Bool]()), soundMode: Box = Box(1), speaker: Box = Box(4)) -> PauseAudioBindings {
    PauseAudioBindings(
      volume: Binding(get: { volume.value }, set: { volume.value = $0 }),
      mute: Binding(get: { muted.value as? Bool ?? false }, set: { muted.value = $0 }),
      backend: Binding(get: { backend.value }, set: { backend.value = $0 }),
      surround: Binding(get: { surround.value as? Bool ?? false }, set: { surround.value = $0 }),
      effectEnabled: { page in
        Binding(get: { (effects.value as? [String: Bool])?[page.rawValue] ?? false },
                set: { var d = effects.value as? [String: Bool] ?? [:]; d[page.rawValue] = $0; effects.value = d })
      },
      wiiSoundMode: Binding(get: { soundMode.value }, set: { soundMode.value = $0 }),
      wiiSpeakerVolume: Binding(get: { speaker.value }, set: { speaker.value = $0 }))
  }

  private func actions() -> PauseAudioActions {
    PauseAudioActions(openEffect: { self.opened.append($0) }, openAudioSettings: { self.pages.append("audio") },
                      openWiiSettings: { self.pages.append("wii") })
  }

  private func state(isWii: Bool = false, volume: Int = 100, muted: Bool = false) -> PauseAudioState {
    PauseAudioState(isWii: isWii, volume: volume, isMuted: muted, backend: "CoreAudio",
                    backendOptions: [("CoreAudio", "CoreAudio"), ("AVAudioEngine", "AVAudioEngine")])
  }

  func test_layout_gameCube_prominentRowIsVolumeAndMute_thenOutputEffectsMore() {
    let model = PauseAudioModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.sections.map(\.id), ["level", "output", "effects", "more"])
    XCTAssertNil(model.sections[0].header, "a headerless section is the prominent row")
    XCTAssertEqual(model.sections[0].items.map(\.id), [PauseAudioModelBuilder.volumeID, "mute"])
    XCTAssertEqual(model.sections[1].items.map(\.id), [PauseAudioModelBuilder.backendID, PauseAudioModelBuilder.surroundID])
    XCTAssertEqual(model.sections[2].items.map(\.id),
                   ["audio-fx-echo", "audio-fx-equalizer", "audio-fx-bitcrusher", PauseAudioModelBuilder.effectSettingsID])
    XCTAssertEqual(model.sections[3].items.map(\.id), [PauseAudioModelBuilder.settingsID])
    for item in model.allItems { XCTAssertFalse((item.description ?? "").isEmpty, "\(item.id) has no description") }
  }

  func test_wiiTitle_addsTheConsolesSoundRows_withLongPressToTheWiiLeaf() {
    let model = PauseAudioModelBuilder.make(state: state(isWii: true), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.sections[1].items.map(\.id),
                   [PauseAudioModelBuilder.backendID, PauseAudioModelBuilder.surroundID, PauseAudioModelBuilder.soundModeID, PauseAudioModelBuilder.speakerVolumeID])
    guard case .cycle(let modes, let selection) = model.item(id: PauseAudioModelBuilder.soundModeID)!.role else { return XCTFail("cycle") }
    XCTAssertEqual(modes.map(\.0), ["Mono", "Stereo", "Surround"])
    XCTAssertEqual(selection.wrappedValue, AnyHashable(1))
    guard case .cycle(let speaker, _) = model.item(id: PauseAudioModelBuilder.speakerVolumeID)!.role else { return XCTFail("cycle") }
    XCTAssertEqual(speaker.map(\.0), ["Off", "1", "2", "3", "4", "5", "6", "7"])
    guard case .action(let run)? = model.item(id: PauseAudioModelBuilder.soundModeID)?.effectiveLongPress else { return XCTFail("long press") }
    run()
    XCTAssertEqual(pages, ["wii"])
  }

  func test_volume_isTheOldLadder_withOffLadderValuesInPlace_andMuteIsTheSharedToggle() {
    let volume = Box(80), muted = Box(false)
    let model = PauseAudioModelBuilder.make(state: state(volume: 80), bindings: bindings(volume: volume, muted: muted), actions: actions())
    guard case .cycle(let volumes, let selection) = model.item(id: PauseAudioModelBuilder.volumeID)!.role else { return XCTFail("cycle") }
    XCTAssertEqual(volumes.map(\.1), [0, 25, 50, 75, 80, 100].map { AnyHashable($0) })
    XCTAssertEqual(MenuItemRole.cycled(options: volumes, current: AnyHashable(80), step: 1), AnyHashable(100))
    selection.wrappedValue = AnyHashable(25)
    XCTAssertEqual(volume.value, AnyHashable(25))
    guard case .options? = model.item(id: PauseAudioModelBuilder.volumeID)?.effectiveLongPress else { return XCTFail("implied picker") }

    let mute = model.item(id: "mute")!
    XCTAssertEqual(mute.icon, "speaker.wave.2.fill")
    XCTAssertTrue(mute.activateInPlace())
    XCTAssertEqual(muted.value, AnyHashable(true))
    XCTAssertEqual(PauseAudioModelBuilder.make(state: state(muted: true), bindings: bindings(), actions: actions()).item(id: "mute")?.icon, "speaker.slash.fill")
  }

  func test_backendCycle_carriesTheShortLabels_andWritesTheRawName() {
    let backend = Box("CoreAudio")
    let model = PauseAudioModelBuilder.make(state: state(), bindings: bindings(backend: backend), actions: actions())
    guard case .cycle(let options, _) = model.item(id: PauseAudioModelBuilder.backendID)!.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["CoreAudio", "AVAudioEngine"])
    XCTAssertTrue(model.item(id: PauseAudioModelBuilder.backendID)!.activateInPlace())
    XCTAssertEqual(backend.value, AnyHashable("AVAudioEngine"))
  }

  func test_effectTiles_toggleTheEffect_longPressOpensItsPage_andSettingsTileOpensAll() {
    let effects = Box(["echo": true])
    var s = state()
    s.effects.echoEnabled = true
    let model = PauseAudioModelBuilder.make(state: s, bindings: bindings(effects: effects), actions: actions())
    let echo = model.item(id: PauseAudioModelBuilder.effectID(.echo))!
    guard case .toggle(let b) = echo.role else { return XCTFail("toggle") }
    XCTAssertTrue(b.wrappedValue)
    b.wrappedValue = false
    XCTAssertEqual((effects.value as? [String: Bool])?["echo"], false)
    guard case .action(let run)? = echo.effectiveLongPress else { return XCTFail("long press") }
    run()
    XCTAssertEqual(opened, [.echo])
    XCTAssertEqual(model.item(id: PauseAudioModelBuilder.effectSettingsID)?.badge, "1 on")
    XCTAssertTrue(model.item(id: PauseAudioModelBuilder.effectSettingsID)!.activateInPlace())
    XCTAssertEqual(opened, [.echo, .all])
    XCTAssertNil(PauseAudioModelBuilder.enabledEffectsBadge(AudioEffectsState()))
  }

  func test_allAudioSettings_opensTheLeaf() {
    let model = PauseAudioModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertTrue(model.item(id: PauseAudioModelBuilder.settingsID)!.activateInPlace())
    XCTAssertEqual(pages, ["audio"])
  }
}
