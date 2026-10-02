// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class QuickScreenshotTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  /// 2026-10-01 12:30:45 UTC.
  private let date = Date(timeIntervalSince1970: 1_790_857_845)

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickScreenshotTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testFileNameMatchesTheCoresOwnScreenshotNaming() {
    XCTAssertEqual(QuickScreenshot.fileName(gameID: "GMSE01", date: date, timeZone: utc), "GMSE01_2026-10-01_12-30-45.png")
  }

  func testFileNameFollowsTheGivenTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    XCTAssertEqual(QuickScreenshot.fileName(gameID: "GMSE01", date: date, timeZone: tokyo), "GMSE01_2026-10-01_21-30-45.png")
  }

  func testDestinationLivesInThePerGameScreenShotsFolderAndCreatesIt() throws {
    let user = try makeTempDirectory()
    let url = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "RSBE01")
    XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, QuickScreenshot.folderName)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testDestinationFailsWhenTheFolderCannotBeCreated() throws {
    let user = try makeTempDirectory()
    let blocker = user.appendingPathComponent(QuickScreenshot.folderName)
    try Data().write(to: blocker)
    XCTAssertNil(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
  }
}
