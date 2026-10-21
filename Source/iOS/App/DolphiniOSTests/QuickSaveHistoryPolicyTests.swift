import Foundation
import XCTest
@testable import iCube

final class QuickSaveHistoryPolicyTests: XCTestCase {
  private func state(_ name: String, date: TimeInterval = 1, automatic: Bool = false,
                     quick: Bool = false, kept: Bool = false, compatible: Bool = true,
                     gameID: String = "GALE01") -> SaveStateInfo {
    SaveStateInfo(gameID: gameID, displayName: name, slot: quick || automatic ? nil : 1,
                  createdAt: nil, modifiedAt: Date(timeIntervalSince1970: date), sizeBytes: nil,
                  versionHash: nil, isCompatible: compatible,
                  path: URL(fileURLWithPath: "/states/\(name)"), thumbnailURL: nil,
                  isAuto: automatic, isQuickSave: quick, isKept: kept)
  }

  private func history(_ index: Int, kept: Bool = false) -> SaveStateInfo {
    state("GALE01.quick-00000000-0000-0000-0000-\(String(format: "%012d", index)).s01",
          date: Double(index), quick: true, kept: kept)
  }

  func test_latestManualBeatsNewerAutomaticIncludingLegacyNumberedStates() {
    let manual = state("GALE01.s01", date: 10)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [state("GALE01.auto", date: 20, automatic: true), manual], modded: false), .manual(manual.path))
  }

  func test_noSavesAndAutomaticFallback() {
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [], modded: false), .unavailable)
    let auto = state("GALE01.auto", automatic: true)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [auto], modded: false), .automatic(auto.path))
  }

  func test_incompatibleLatestManualDoesNotSilentlyLoadOlderCompatibleStateOrAuto() {
    let latest = state("GALE01.s02", date: 20, compatible: false)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [state("GALE01.s01"), latest, state("GALE01.auto", date: 30, automatic: true)], modded: false), .incompatible(latest.path))
    let auto = state("GALE01.auto", automatic: true, compatible: false)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [auto], modded: false), .incompatible(auto.path))
  }

  func test_moddedDisablesImplicitHistoryAndAutomaticFallback() {
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [history(1), state("GALE01.auto", automatic: true)], modded: true), .unavailable)
    let classic = state("GALE01.s03")
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [classic, history(20)], modded: true), .unavailable)
  }

  func test_twelveHistoryEntriesReturnOnlyTwoOldestWithNewestFirstOrder() {
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: (1...12).map { history($0) }), [history(2).path, history(1).path])
  }

  func test_retentionLimitAppliesSeparatelyToEachGame() {
    let other = state("RSBE01.quick-00000000-0000-0000-0000-000000000001.s01", quick: true, gameID: "RSBE01")
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: [history(1), history(2), other], limit: 1), [history(1).path])
  }

  func test_keptClassicAutoAndUnvalidatedForeignFilesNeverRotate() {
    let excluded = [history(1, kept: true), state("GALE01.s01"), state("GALE01.auto", automatic: true),
                    state("GALE01.quick-00000000-0000-0000-0000-000000000001.s01"),
                    state("foreign.s01", quick: true), state("GALE01.quick-not-a-uuid.s01", quick: true),
                    state("RSBE01.quick-00000000-0000-0000-0000-000000000001.s01", quick: true)]
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: excluded, limit: 0), [])
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: (1...12).map { history($0) } + excluded), [history(2).path, history(1).path])
  }

  func test_equalDatesUseAscendingPathDeterministicallyAndMissingDateUsesCreationTime() {
    let first = state("GALE01.s01")
    let second = state("GALE01.s02")
    for states in [[first, second], [second, first]] {
      XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: states, modded: false), .manual(first.path))
    }
    let created = SaveStateInfo(gameID: "GALE01", displayName: "legacy", slot: 3,
      createdAt: Date(timeIntervalSince1970: 10), modifiedAt: nil, sizeBytes: nil,
      versionHash: nil, isCompatible: true, path: URL(fileURLWithPath: "/states/GALE01.s03"), thumbnailURL: nil, isAuto: false)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: [first, created], modded: false), .manual(created.path))
    let a = state("GALE01.quick-00000000-0000-0000-0000-000000000001.s01", quick: true)
    let b = state("GALE01.quick-00000000-0000-0000-0000-000000000002.s01", quick: true)
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: [b, a], limit: 1), [b.path])
  }

  func test_oldMetadataDecodesWithoutHistoryFlagsAndRoundTripPreservesNewFlags() throws {
    let old = Data(#"{"schemaVersion":1,"title":"Legacy","gameID":"GALE01","savedAt":0,"isAuto":false}"#.utf8)
    let metadata = try JSONDecoder().decode(SaveStateMetadata.self, from: old)
    XCTAssertFalse(metadata.isQuickSave ?? false)
    XCTAssertFalse(metadata.isKept ?? false)
    let new = SaveStateMetadata(title: "Kept", gameID: "GALE01", isQuickSave: true, isKept: true)
    XCTAssertEqual(try JSONDecoder().decode(SaveStateMetadata.self, from: JSONEncoder().encode(new)), new)
  }

  func test_historyGameIDsSupportCoreHomebrewAndShortWADIdentifiers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gameIDs = ["ID-loader", "ID-Retro Launcher", "ID-demo.quick-example", "ID-新demo", "HAXX", "ID-demo.v2"]
    for gameID in gameIDs {
      let name = "\(gameID).quick-00000000-0000-0000-0000-000000000001.s01"
      let url = root.appendingPathComponent(name)
      XCTAssertEqual(QuickSaveHistoryPolicy.historyGameID(for: url), gameID)
      try Data([0]).write(to: url)
      XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Test", gameID: gameID, isQuickSave: true), forStateFile: url))
    }
    let groups = await FilesystemSaveStateProvider(root: root).statesGroupedByGame()
    for gameID in gameIDs {
      let info = try XCTUnwrap(groups[gameID]?.first)
      XCTAssertTrue(info.isQuickSave, gameID)
      XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: [info], limit: 0), [info.path])
    }
  }

  func test_validatedHomebrewHistoryDoesNotInheritSlotNumbersFromItsGameID() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for gameID in ["ID-Slot-3", "ID-StateSlot1"] {
      for index in 1...11 {
        let url = root.appendingPathComponent("\(gameID).quick-00000000-0000-0000-0000-\(String(format: "%012d", index)).s01")
        try Data([0]).write(to: url)
        XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Test", gameID: gameID,
          savedAt: Date(timeIntervalSince1970: Double(index)), isQuickSave: true), forStateFile: url))
      }
      // A legacy export without identifying history metadata keeps its old slot heuristic.
      let legacy = root.appendingPathComponent("\(gameID).sav")
      try Data([0]).write(to: legacy)
      XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Legacy", gameID: gameID), forStateFile: legacy))
    }
    let groups = await FilesystemSaveStateProvider(root: root).statesGroupedByGame()
    for (gameID, legacySlot) in [("ID-Slot-3", 3), ("ID-StateSlot1", 1)] {
      let states = try XCTUnwrap(groups[gameID])
      let history = states.filter(\.isQuickSave)
      XCTAssertEqual(history.count, 11)
      XCTAssertTrue(history.allSatisfy { $0.slot == nil }, gameID)
      let expected = root.appendingPathComponent("\(gameID).quick-00000000-0000-0000-0000-000000000001.s01")
      XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: states).map { $0.resolvingSymlinksInPath() },
                     [expected.resolvingSymlinksInPath()])
      XCTAssertEqual(try XCTUnwrap(states.first { !$0.isQuickSave }).slot, legacySlot)
    }
  }

  func test_unsafeGameIDsAndMalformedHistoryUUIDsCannotRotate() {
    for gameID in ["", ".", "..", "ID/loader", "ID\\loader", "ID\u{0}loader", "ID\nloader", "ID\u{7F}loader"] {
      let info = state("\(gameID).quick-00000000-0000-0000-0000-000000000001.s01", quick: true, gameID: gameID)
      XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: [info], limit: 0), [], gameID.debugDescription)
    }
    for suffix in ["not-a-uuid.s01", "00000000000000000000000000000001.s01",
                   "00000000-0000-0000-0000-000000000001.s01.tmp", "00000000-0000-0000-0000-000000000001.S01",
                   "00000000-0000-0000-0000-000000000001.s02"] {
      XCTAssertNil(QuickSaveHistoryPolicy.historyGameID(for: URL(fileURLWithPath: "/states/ID-loader.quick-\(suffix)")))
    }
  }

  func test_preferredAndLegacyHistoryExtensionsRequireMetadataAndExcludeSidecars() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stem = "GALE01.quick-00000000-0000-0000-0000-000000000001"
    for ext in ["s01", "sav", "s02"] {
      let url = root.appendingPathComponent("\(stem).\(ext)")
      try Data([0]).write(to: url)
      try Data([0]).write(to: url.appendingPathExtension("png"))
      XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Test", gameID: "GALE01", isQuickSave: true), forStateFile: url))
      if ext == "s02" {
        XCTAssertNil(QuickSaveHistoryPolicy.historyGameID(for: url))
      } else {
        XCTAssertEqual(QuickSaveHistoryPolicy.historyGameID(for: url), "GALE01")
      }
      XCTAssertNil(QuickSaveHistoryPolicy.historyGameID(for: url.appendingPathExtension("json")))
      XCTAssertNil(QuickSaveHistoryPolicy.historyGameID(for: url.appendingPathExtension("png")))
    }
    let states = await FilesystemSaveStateProvider(root: root).states(for: "GALE01")
    XCTAssertEqual(states.count, 3)
    let history = states.filter(\.isQuickSave)
    XCTAssertEqual(Set(history.map { $0.path.pathExtension }), Set(["s01", "sav"]))
    XCTAssertTrue(history.allSatisfy { $0.slot == nil })
    XCTAssertEqual(try XCTUnwrap(states.first { $0.path.pathExtension == "s02" }).slot, 2)
    XCTAssertEqual(Set(QuickSaveHistoryPolicy.pruningCandidates(states: states, limit: 0).map { $0.pathExtension }), Set(["s01", "sav"]))
  }

  func test_providerValidatesHistoryMetadataWithoutHidingForeignOrLegacySaves() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let valid = history(1).path.lastPathComponent
    let missing = history(2).path.lastPathComponent
    let mismatch = history(3).path.lastPathComponent
    let automatic = history(4).path.lastPathComponent
    let unmarked = history(5).path.lastPathComponent
    let malformed = "GALE01.quick-bad.s01"
    let classic = "GALE01.s99"
    for name in [valid, missing, mismatch, automatic, unmarked, malformed, classic] {
      try Data([0]).write(to: root.appendingPathComponent(name))
    }
    for (name, gameID, isAuto, quick) in [(valid, "GALE01", false, true), (mismatch, "RSBE01", false, true),
      (automatic, "GALE01", true, true), (unmarked, "GALE01", false, false),
      (malformed, "GALE01", false, true), (classic, "GALE01", false, true)] {
      XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Test", gameID: gameID,
        savedAt: Date(timeIntervalSince1970: 123), isAuto: isAuto, isQuickSave: quick, isKept: true), forStateFile: root.appendingPathComponent(name)))
    }
    let states = await FilesystemSaveStateProvider(root: root).statesGroupedByGame().values.flatMap { $0 }
    XCTAssertEqual(states.count, 7)
    XCTAssertEqual(states.filter(\.isQuickSave).map { $0.path.lastPathComponent }, [valid])
    XCTAssertTrue(try XCTUnwrap(states.first { $0.path.lastPathComponent == valid }).isKept)
    XCTAssertEqual(try XCTUnwrap(states.first { $0.path.lastPathComponent == valid }).modifiedAt, Date(timeIntervalSince1970: 123))
    XCTAssertEqual(QuickSaveHistoryPolicy.pruningCandidates(states: states, limit: 0), [])
  }
}
