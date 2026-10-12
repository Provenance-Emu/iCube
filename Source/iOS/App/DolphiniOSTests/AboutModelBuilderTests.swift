import SwiftUI
import XCTest
@testable import iCube

final class AboutModelBuilderTests: XCTestCase {
  private var opened: [URL] = []
  private var resets = 0
  private func model() -> MenuModel {
    AboutModelBuilder.make(appVersion: "3.4.0 (12)", coreVersion: "5.0-2345", open: { self.opened.append($0) },
                           blog: AnyView(EmptyView()), help: AnyView(EmptyView()), resetAll: { self.resets += 1 })
  }

  func test_sections_andOrder() {
    XCTAssertEqual(model().sections.map(\.header), ["Version", "iCube", "Dolphin", "Help", nil])
    XCTAssertEqual(model().allItems.map(\.id),
                   ["version", "core", "icube-site", "source", "author-github", "author-site",
                    "dolphinios", "dolphin", "blog", "help", "reset-all"])
  }

  func test_linkRows_openTheirURL() {
    let m = model()
    for (id, url) in [("icube-site", AboutLinks.icube), ("source", AboutLinks.source), ("dolphin", AboutLinks.dolphin)] {
      guard case .action(let run) = m.item(id: id)?.role else { return XCTFail(id) }
      opened = []; run(); XCTAssertEqual(opened, [url], id)
    }
  }

  func test_resetAll_isDestructive_andEveryRowDescribed() {
    guard case .destructive = model().item(id: "reset-all")?.role else { return XCTFail() }
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }
}
