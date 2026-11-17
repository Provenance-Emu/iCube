// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class OpenedFileRouterTests: XCTestCase {
  private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/opened-file-router/\(name)") }

  func testGameImagesAndArchivesAreImported() {
    let urls = [file("Game.iso"), file("Game.rvz"), file("Game.wbfs"), file("Pack.zip")]
    XCTAssertEqual(OpenedFileRouter.importableFiles(in: urls), urls)
  }

  func testLinksAreLeftForTheURLRouter() throws {
    let links = [try XCTUnwrap(URL(string: "dolphinios://play?id=GALE01")),
                 try XCTUnwrap(URL(string: "https://icube-emu.com/play?id=GALE01")),
                 // A web address that merely ends in a game extension is still a link.
                 try XCTUnwrap(URL(string: "https://example.com/Game.iso"))]
    XCTAssertEqual(OpenedFileRouter.importableFiles(in: links), [])
  }

  func testUnknownFilesAreLeftAlone() {
    XCTAssertEqual(OpenedFileRouter.importableFiles(in: [file("notes.txt"), file("photo.png")]), [])
  }

  func testOrderIsKeptWhenFilesAndLinksAreMixed() throws {
    let link = try XCTUnwrap(URL(string: "dolphinios://play?id=GALE01"))
    let mixed = [file("B.iso"), link, file("readme.txt"), file("A.gcm")]
    XCTAssertEqual(OpenedFileRouter.importableFiles(in: mixed), [file("B.iso"), file("A.gcm")])
  }
}
