// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVContinuity

extension XCTestCase {
    /// `XCTUnwrap` equivalent that accepts an `await`ed value.
    ///
    /// `XCTUnwrap` takes its argument as an autoclosure, which cannot contain
    /// `await`; almost every value these tests unwrap comes out of an actor.
    func require<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "unexpectedly nil",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        guard let value else {
            XCTFail(message(), file: file, line: line)
            throw UnwrapFailure()
        }
        return value
    }
}

struct UnwrapFailure: Error {}
