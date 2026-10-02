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
    XCTAssertEqual(QuickScreenshot.fileName(gameID: "GMSE01", date: date, timeZone: utc), "GMSE01_2026-10-01_12-30-45-000.png")
  }

  func testFileNameFollowsTheGivenTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    XCTAssertEqual(QuickScreenshot.fileName(gameID: "GMSE01", date: date, timeZone: tokyo), "GMSE01_2026-10-01_21-30-45-000.png")
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

  func testFileNameCarriesMilliseconds() {
    let later = date.addingTimeInterval(0.25)
    XCTAssertEqual(QuickScreenshot.fileName(gameID: "GMSE01", date: later, timeZone: utc), "GMSE01_2026-10-01_12-30-45-250.png")
  }

  func testTwoShotsInTheSameSecondGetDifferentFiles() throws {
    let user = try makeTempDirectory()
    let first = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
    let second = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date.addingTimeInterval(0.4), userDirectory: user))
    XCTAssertNotEqual(first, second)
  }

  func testATakenNameGetsACounterInsteadOfReusingTheFile() throws {
    let user = try makeTempDirectory()
    let first = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
    try Data([1]).write(to: first)
    let second = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.png"), second.lastPathComponent)
    try Data([1]).write(to: second)
    let third = try XCTUnwrap(QuickScreenshot.destination(gameID: "RSBE01", date: date, userDirectory: user))
    XCTAssertTrue(third.lastPathComponent.hasSuffix("-3.png"), third.lastPathComponent)
  }
}
