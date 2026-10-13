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

  /// Only the App Store build scrubs game ids, so only it may say reports never include games.
  func test_footer_matchesTheBuildConfiguration() {
    let footer = ConfigPrivacyModelBuilder.make(crashReports: true, apply: { _ in }).item(id: "crash-reports")?.description
    #if APPSTORE
    XCTAssertTrue(footer?.contains("never include your games") == true)
    #else
    XCTAssertEqual(footer, "Sends crash and performance reports to the iCube developers. Reports can include the ID of the game you were playing.")
    #endif
  }
}
