// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVHelp
import XCTest

@testable import iCube

final class WikiHelpViewModelTests: XCTestCase {
  func test_storeBuildWithoutJIT_hidesTheJitGuide() {
    XCTAssertEqual(WikiHelpViewModel.hiddenPaths(isAppStore: true, jitSupported: false), [WikiConstants.Paths.jitGuide])
  }

  func test_storeBuildWithJIT_showsTheJitGuide() {
    XCTAssertTrue(WikiHelpViewModel.hiddenPaths(isAppStore: true, jitSupported: true).isEmpty)
  }

  func test_otherBuilds_neverHideAnything() {
    XCTAssertTrue(WikiHelpViewModel.hiddenPaths(isAppStore: false, jitSupported: false).isEmpty)
    XCTAssertTrue(WikiHelpViewModel.hiddenPaths(isAppStore: false, jitSupported: true).isEmpty)
  }
}
