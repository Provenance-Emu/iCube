// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import XCTest

@testable import iCube

/// ICUBE-AC: launched by a debugger for JIT, the app's stdout/stderr are a pipe the debugger reads.
/// Once it detaches nobody drains it, and when the pipe fills every NSLog/printf blocks — on main
/// that is a watchdog kill. Writes to such a pipe must return instead of blocking.
final class DebuggerStdioTests: XCTestCase {

  func test_writesToAnUndrainedPipe_returnInsteadOfBlocking() {
    // A blocked writer is released below by closing the read end; ignore the SIGPIPE that would
    // otherwise kill the test host.
    signal(SIGPIPE, SIG_IGN)
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    let (readEnd, writeEnd) = (fds[0], fds[1])
    defer { close(readEnd); close(writeEnd) }

    DebuggerStdio.makeNonBlocking(writeEnd)

    let returned = expectation(description: "writes returned with nobody reading the pipe")
    DispatchQueue.global(qos: .userInitiated).async {
      let chunk = [UInt8](repeating: 0x41, count: 4096)
      for _ in 0..<64 {  // 256 KB, several times a pipe's buffer
        _ = chunk.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
      }
      returned.fulfill()
    }
    wait(for: [returned], timeout: 2)
  }
}
