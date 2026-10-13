// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// L1/R1 on the tvOS library: My Library, All Games, then each platform the rail shows, wrapping.
final class TVLibraryRailDestinationTests: XCTestCase {
  private let platforms: [LibraryPlatformCategory] = [.gameCube, .wii]

  func testStepsForwardThroughTheRailOrder() {
    XCTAssertEqual(TVLibraryRailDestination.home.stepped(by: 1, platforms: platforms), .all)
    XCTAssertEqual(TVLibraryRailDestination.all.stepped(by: 1, platforms: platforms), .platform(.gameCube))
    XCTAssertEqual(TVLibraryRailDestination.platform(.gameCube).stepped(by: 1, platforms: platforms), .platform(.wii))
  }

  func testWrapsBothWays() {
    XCTAssertEqual(TVLibraryRailDestination.platform(.wii).stepped(by: 1, platforms: platforms), .home)
    XCTAssertEqual(TVLibraryRailDestination.home.stepped(by: -1, platforms: platforms), .platform(.wii))
  }

  func testAPlatformTheRailNoLongerShowsStepsFromMyLibrary() {
    XCTAssertEqual(TVLibraryRailDestination.platform(.wiiWare).stepped(by: 1, platforms: platforms), .all)
  }

  func testWithoutPlatformsItTogglesMyLibraryAndAllGames() {
    XCTAssertEqual(TVLibraryRailDestination.all.stepped(by: 1, platforms: []), .home)
  }
}
