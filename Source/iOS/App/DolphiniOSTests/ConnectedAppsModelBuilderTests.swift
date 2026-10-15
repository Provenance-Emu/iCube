// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConnectedAppsModelBuilderTests: XCTestCase {
  private func makeModel(provenance: Bool, ifly: Bool, opened: @escaping (String) -> Void = { _ in }) -> MenuModel {
    ConnectedAppsModelBuilder.make(apps: [
      .init(id: "provenance", name: "Provenance", icon: "square.grid.3x3.fill", installed: provenance) { opened("provenance") },
      .init(id: "ifly", name: "iFly", icon: "circle.circle", installed: ifly) { opened("ifly") },
    ])
  }

  func test_installedAppShowsInstalledBadge_andMissingOneOffersToGetIt() {
    let model = makeModel(provenance: true, ifly: false)
    XCTAssertEqual(model.item(id: "provenance")?.badge, "Installed")
    XCTAssertEqual(model.item(id: "ifly")?.badge, "Get")
  }

  func test_rowTapRunsTheAppsOpenAction() {
    var opened: [String] = []
    let model = makeModel(provenance: true, ifly: true) { opened.append($0) }
    guard case .action(let run)? = model.item(id: "ifly")?.role else { return XCTFail("ifly is not an action row") }
    run()
    XCTAssertEqual(opened, ["ifly"])
  }

  func test_scanTagRowOnlyWhereTagsCanBeRead() {
    XCTAssertNil(makeModel(provenance: true, ifly: true).item(id: "scan-tag"))
    var scanned = 0
    let model = ConnectedAppsModelBuilder.make(apps: [], scanTag: { scanned += 1 })
    guard case .action(let run)? = model.item(id: "scan-tag")?.role else { return XCTFail("scan-tag is not an action row") }
    run()
    XCTAssertEqual(scanned, 1)
  }

  func test_sharingSectionExplainsBothDirections() {
    let model = makeModel(provenance: false, ifly: false)
    XCTAssertNotNil(model.item(id: "send"))
    XCTAssertNotNil(model.item(id: "receive"))
  }
}
