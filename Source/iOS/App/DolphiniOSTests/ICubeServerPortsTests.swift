// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import iCube
import XCTest

/// iFly, iCube and Provenance can share one device; each keeps its own home port
/// and falls back only into its own range.
final class ICubeServerPortsTests: XCTestCase {
    func testPortMap() {
        XCTAssertEqual(ICubeServerPorts.candidates, [8091, 8190, 8191, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199])
    }

    func testFallbacksNeverTakeAnotherAppsHomePort() {
        let fallbacks = Set(ICubeServerPorts.candidates.dropFirst())
        XCTAssertTrue(fallbacks.isDisjoint(with: ICubeServerPorts.ecosystemHomePorts))
        // Nor iFly's (8092–8099) or Provenance's (8180–8189) fallback ranges.
        XCTAssertTrue(fallbacks.isDisjoint(with: Set(8092...8099).union(8180...8189)))
    }

    func testNoLowPorts() {
        // Root-only below 1024 in the simulator and on a Mac.
        XCTAssertTrue(ICubeServerPorts.candidates.allSatisfy { $0 >= 1024 })
    }
}
