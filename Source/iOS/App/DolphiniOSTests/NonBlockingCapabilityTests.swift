// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import iCube

/// `NFCNDEFReaderSession.readingAvailable` stalled the library grid for seconds
/// (Sentry ICUBE-K8). These pin that a reader never waits on the system check.
final class NonBlockingCapabilityTests: XCTestCase {
  func testReadersDoNotWaitForAStalledCheckAndSeeTheAnswerOnceItArrives() {
    let release = DispatchSemaphore(value: 0)
    let reads = Counter()
    let capability = NonBlockingCapability {
      reads.increment()
      release.wait()
      return true
    }

    // The check is stuck, yet every read returns at once, with false.
    XCTAssertFalse(capability.value)
    XCTAssertFalse(capability.value)

    release.signal()
    let answered = expectation(description: "the cached answer arrives")
    func poll() {
      if capability.value { answered.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) }
    }
    poll()
    wait(for: [answered], timeout: 5)
    // Only one system call, however many readers asked.
    XCTAssertEqual(reads.value, 1)
  }

  func testResolveStartsTheReadWithoutAReader() {
    let done = expectation(description: "read ran")
    let capability = NonBlockingCapability {
      done.fulfill()
      return false
    }
    capability.resolve()
    wait(for: [done], timeout: 5)
    capability.resolve()
    XCTAssertFalse(capability.value)
  }

  func testGameTagAvailabilityIsFalseOnTheSimulator() {
    GameTagCenter.resolveAvailability()
    XCTAssertFalse(GameTagCenter.isAvailable)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
