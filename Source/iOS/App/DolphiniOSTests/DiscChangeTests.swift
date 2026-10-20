// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class DiscChangeTests: XCTestCase {
  func test_eligibleDiscs_matchConsoleAndExcludeNonDiscsRemoteDemoAndMissingFiles() {
    let candidates = [
      DiscChangeCandidate(title: "GC", path: "/gc.iso", platform: 0),
      DiscChangeCandidate(title: "Wii", path: "/wii.rvz", platform: 2),
      DiscChangeCandidate(title: "WAD", path: "/channel.wad", platform: 3),
      DiscChangeCandidate(title: "DOL", path: "/boot.dol", platform: 4),
      DiscChangeCandidate(title: "Remote", path: "https://example.com/game.iso", platform: 0),
      DiscChangeCandidate(title: "Demo", path: "/demo.iso", platform: 0, isDemo: true),
      DiscChangeCandidate(title: "Missing", path: "/missing.iso", platform: 0),
    ]
    XCTAssertEqual(DiscChangePolicy.eligible(candidates, isWii: false, available: { $0 != "/missing.iso" }).map(\.title), ["GC"])
    XCTAssertEqual(DiscChangePolicy.eligible(candidates, isWii: true, available: { _ in true }).map(\.title), ["Wii"])
  }

  func test_fileURLs_areDecodedAndDeduplicatedWithoutChangingSelectionIdentity() {
    let candidates = [DiscChangeCandidate(title: "Disc 2", path: "file:///tmp/Disc%202.rvz", platform: 0),
                      DiscChangeCandidate(title: "Duplicate", path: "/tmp/Disc 2.rvz", platform: 0)]
    let eligible = DiscChangePolicy.eligible(candidates, isWii: false, available: { _ in true })
    XCTAssertEqual(eligible.map(\.path), ["/tmp/Disc 2.rvz"])
    XCTAssertNil(DiscChangePolicy.localPath("file://remote-host/game.iso"))
    XCTAssertNil(DiscChangePolicy.localPath("relative.iso"))
  }

  func test_realAvailability_excludesDirectoriesAndMissingFiles() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let disc = folder.appendingPathComponent("disc.iso")
    try Data([0]).write(to: disc)
    XCTAssertTrue(DiscChangePolicy.isAvailableFile(disc.path))
    XCTAssertFalse(DiscChangePolicy.isAvailableFile(folder.path))
    XCTAssertFalse(DiscChangePolicy.isAvailableFile(folder.appendingPathComponent("missing.iso").path))
  }

  func test_cancelDoesNotSelectADisc_andSelectionUsesTheChosenPath() {
    let candidate = DiscChangeCandidate(title: "Disc 2", path: "/disc2.rvz", platform: 0, discNumber: 1)
    var selections: [String] = []
    var cancelled = 0
    let model = DiscChangeModelBuilder.make(candidates: [candidate], onSelect: { selections.append($0.path) }, onCancel: { cancelled += 1 })
    model.item(id: "disc-cancel")?.activateInPlace()
    XCTAssertEqual(cancelled, 1)
    XCTAssertEqual(selections, [])
    model.item(id: candidate.path)?.activateInPlace()
    XCTAssertEqual(selections, [candidate.path])
  }

  func test_emptyPicker_keepsCancelReachableAndExplainsNoAvailableDiscs() {
    let model = DiscChangeModelBuilder.make(candidates: [], onSelect: { _ in XCTFail("empty picker selected a disc") }, onCancel: {})
    XCTAssertTrue(model.item(id: "disc-cancel")?.isEnabled == true)
    XCTAssertFalse(model.item(id: "disc-empty")?.isEnabled ?? true)
  }

  func test_bridgeRejectsMissingFileAndDirectoryBeforeTouchingDrive() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    XCTAssertEqual(TVEmulationBridge.changeDisc(atPath: folder.appendingPathComponent("missing.iso").path), .fileUnavailable)
    XCTAssertEqual(TVEmulationBridge.changeDisc(atPath: folder.path), .fileUnavailable)
    XCTAssertEqual(TVEmulationBridge.changeDisc(atPath: "https://example.com/game.iso"), .fileUnavailable)
  }

  func test_bridgeRejectsNonDiscDataBeforeTouchingDrive() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let invalid = folder.appendingPathComponent("invalid.iso")
    try Data("This is not a disc image".utf8).write(to: invalid)
    XCTAssertEqual(TVEmulationBridge.changeDisc(atPath: invalid.path), .invalidDisc)
  }

  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}
