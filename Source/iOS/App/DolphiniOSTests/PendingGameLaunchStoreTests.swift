// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class PendingGameLaunchStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "icube.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testSetThenConsumeRoundTripsAndClears() {
    PendingGameLaunchStore.set(gameID: "GALE01", in: defaults)
    XCTAssertEqual(PendingGameLaunchStore.consume(from: defaults), "GALE01")
    XCTAssertNil(PendingGameLaunchStore.consume(from: defaults), "second consume finds nothing left")
  }

  func testEmptyGameIDIsIgnored() {
    PendingGameLaunchStore.set(gameID: "", in: defaults)
    XCTAssertNil(PendingGameLaunchStore.consume(from: defaults))
  }

  func testConsumeWithNothingPendingReturnsNil() {
    XCTAssertNil(PendingGameLaunchStore.consume(from: defaults))
  }
}
