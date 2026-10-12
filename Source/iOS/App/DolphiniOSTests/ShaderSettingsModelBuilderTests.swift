import SwiftUI
import XCTest
@testable import iCube

final class ShaderSettingsModelBuilderTests: XCTestCase {
  private var changes: [ShaderSettingsChange] = []
  private func model(enabled: Bool = true, error: String? = nil, debug: Bool = false) -> MenuModel {
    ShaderSettingsModelBuilder.make(.init(enabled: enabled, presetLabel: "crt-royale", flipVertically: false, preCopy: false, lastError: error, isDebug: debug),
                                    picker: AnyView(EmptyView()), debugTools: AnyView(EmptyView())) { self.changes.append($0) }
  }
  func test_rows_andPresetDisabledWhenOff() {
    XCTAssertEqual(model().allItems.map(\.id), ["enabled", "preset", "flip", "precopy"])
    XCTAssertEqual(model().item(id: "preset")?.badge, "crt-royale")
    XCTAssertEqual(model(enabled: false).item(id: "preset")?.isEnabled, false)
  }
  func test_error_isACaption_andDebugAddsASection() {
    XCTAssertEqual(model(error: "compile failed").item(id: "error")?.isEnabled, false)
    XCTAssertEqual(model(debug: true).sections.last?.id, "developer")
  }
  func test_toggles_emitChanges() {
    let m = model()
    for (id, change) in [("enabled", ShaderSettingsChange.enabled(false)), ("flip", .flipVertically(false)), ("precopy", .preCopy(false))] {
      guard case .toggle(let b) = m.item(id: id)?.role else { return XCTFail(id) }
      changes = []; b.wrappedValue = false; XCTAssertEqual(changes, [change], id)
    }
  }
}
