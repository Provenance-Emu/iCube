// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class WebUIModelBuilderTests: XCTestCase {
  func test_rows_showAddresses_asBadges() {
    let m = WebUIModelBuilder.make(webURL: "http://192.168.1.2/", webDavURL: "http://192.168.1.2/", open: { _ in })
    XCTAssertEqual(m.allItems.map(\.id), ["web-ui", "webdav", "learn-more"])
    XCTAssertEqual(m.item(id: "web-ui")?.badge, "http://192.168.1.2/")
    XCTAssertEqual(m.item(id: "webdav")?.badge, "http://192.168.1.2/")
    XCTAssertFalse(m.sections[0].footer?.isEmpty ?? true)
  }

  func test_notRunning_showsNotRunning_andRowsStayDescribed() {
    let m = WebUIModelBuilder.make(webURL: "", webDavURL: "", open: { _ in })
    XCTAssertEqual(m.item(id: "web-ui")?.badge, "Not Running")
    for item in m.allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }
}
