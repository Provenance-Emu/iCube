// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class BenchAwaitTests: XCTestCase {
  func testReturnsCallbackValueBeforeDeadline() async {
    let v = await BenchAwait.withTimeout(seconds: 5) { finish in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { finish(true) }
    }
    XCTAssertEqual(v, true)
  }

  func testReturnsNilWhenDeadlinePasses() async {
    let started = Date()
    let v: Bool? = await BenchAwait.withTimeout(seconds: 0.2) { _ in /* never finishes */ }
    XCTAssertNil(v)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.19)
  }

  func testLateCallbackAfterTimeoutIsIgnored() async {
    let late = expectation(description: "late callback delivered")
    let v: Int? = await BenchAwait.withTimeout(seconds: 0.1) { finish in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
        finish(7) // must not double-resume
        late.fulfill()
      }
    }
    XCTAssertNil(v)
    await fulfillment(of: [late], timeout: 2)
  }

  func testImmediateCompletionWins() async {
    let v = await BenchAwait.withTimeout(seconds: 1) { finish in finish(false) }
    XCTAssertEqual(v, false)
  }
}
