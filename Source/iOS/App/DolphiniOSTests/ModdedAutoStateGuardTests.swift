// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import UIKit
import XCTest

@testable import iCube

/// A modded boot shares its base game's ID and so its `{GameID}.auto`; none of the places that could
/// list, request or pick that vanilla state may do so for it.
@MainActor
final class ModdedAutoStateGuardTests: XCTestCase {
  // MARK: - Boot-into-state request

  func testAModdedBootDropsARequestedAutoState() {
    XCTAssertNil(SaveStateService.droppingAutoState("/states/GALE01.auto", bootIsModded: true))
    XCTAssertNil(SaveStateService.droppingAutoState("/states/GALE01.AUTO", bootIsModded: true))
  }

  func testAModdedBootKeepsARequestedManualSlot() {
    XCTAssertEqual(SaveStateService.droppingAutoState("/states/GALE01.s03", bootIsModded: true), "/states/GALE01.s03")
  }

  func testAVanillaBootKeepsARequestedAutoState() {
    XCTAssertEqual(SaveStateService.droppingAutoState("/states/GALE01.auto", bootIsModded: false), "/states/GALE01.auto")
    XCTAssertNil(SaveStateService.droppingAutoState(nil, bootIsModded: true))
  }

  // MARK: - Save-state lists

  private struct FakeProvider: SaveStateProviding {
    let all: [SaveStateInfo]

    func states(for gameID: String) async -> [SaveStateInfo] { all.filter { $0.gameID == gameID } }
    func statesGroupedByGame() async -> [String: [SaveStateInfo]] { Dictionary(grouping: all, by: \.gameID) }
    func thumbnail(for state: SaveStateInfo) async -> UIImage? { nil }
    func delete(state: SaveStateInfo) throws {}
    func rename(state: SaveStateInfo, to title: String) throws {}
  }

  private func state(slot: Int?, auto: Bool) -> SaveStateInfo {
    SaveStateInfo(gameID: "GALE01", displayName: auto ? "Continue" : "Slot \(slot ?? 0)", slot: slot, createdAt: nil, modifiedAt: nil,
                  sizeBytes: nil, versionHash: nil, isCompatible: true, path: URL(fileURLWithPath: "/states/GALE01.\(auto ? "auto" : "s01")"),
                  thumbnailURL: nil, isAuto: auto)
  }

  private func model(modded: Bool) -> SaveStatesViewModel {
    SaveStatesViewModel(provider: FakeProvider(all: [state(slot: nil, auto: true), state(slot: 1, auto: false)]),
                        isCurrentBootModded: { modded })
  }

  func testAModdedBootHidesTheContinueCard() async {
    let model = model(modded: true)
    await model.load(gameID: "GALE01")
    XCTAssertEqual(model.states.map(\.isAuto), [false])
    await model.loadAll()
    XCTAssertEqual(model.grouped.first?.states.map(\.isAuto), [false])
  }

  func testAVanillaBootListsTheContinueCard() async {
    let model = model(modded: false)
    await model.load(gameID: "GALE01")
    XCTAssertEqual(Set(model.states.map(\.isAuto)), [true, false])
  }

  // MARK: - Continuity match tie-break

  func testTheBaseGameWinsATieWithAPatchedCopy() {
    XCTAssertTrue(ICubeLibraryQuery.prefers(strength: .exactGameID, isModded: false, over: (.exactGameID, true)))
    XCTAssertFalse(ICubeLibraryQuery.prefers(strength: .exactGameID, isModded: true, over: (.exactGameID, false)))
    XCTAssertFalse(ICubeLibraryQuery.prefers(strength: .exactGameID, isModded: false, over: (.exactGameID, false)))
  }

  func testAStrongerMatchStillBeatsTheBaseGame() {
    XCTAssertTrue(ICubeLibraryQuery.prefers(strength: .contentHash, isModded: true, over: (.gameIDFamily, false)))
    XCTAssertFalse(ICubeLibraryQuery.prefers(strength: .gameIDFamily, isModded: false, over: (.exactGameID, true)))
  }
}
