// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigPrivacyModelBuilderTests: XCTestCase {
  func test_crashReportToggle_reflectsAndWrites() {
    var written: Bool?
    let model = ConfigPrivacyModelBuilder.make(crashReports: true) { written = $0 }
    guard case .toggle(let binding)? = model.item(id: "crash-reports")?.role else { return XCTFail("crash-reports is not a toggle") }
    XCTAssertTrue(binding.wrappedValue)
    binding.wrappedValue = false
    XCTAssertEqual(written, false)
  }

  func test_toggleShowsTheStateValue() {
    guard case .toggle(let binding)? = ConfigPrivacyModelBuilder.make(crashReports: false, apply: { _ in }).item(id: "crash-reports")?.role else {
      return XCTFail("crash-reports is not a toggle")
    }
    XCTAssertFalse(binding.wrappedValue)
  }

  func test_everyRow_hasADescription() {
    for item in ConfigPrivacyModelBuilder.make(crashReports: true, apply: { _ in }).allItems {
      XCTAssertFalse((item.description ?? "").isEmpty, item.id)
    }
  }
}
