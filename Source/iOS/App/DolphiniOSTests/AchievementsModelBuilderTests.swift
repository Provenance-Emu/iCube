import SwiftUI
import XCTest
@testable import iCube

final class AchievementsModelBuilderTests: XCTestCase {
  private var changes: [AchievementsChange] = []
  private func model(enabled: Bool = true) -> MenuModel {
    AchievementsModelBuilder.make(.init(enabled: enabled, hardcore: true, spectator: true, discordPresence: true, progress: true, isSignedIn: false)) { self.changes.append($0) }
  }
  func test_rows_inOrder_andAllDescribed() {
    let m = model()
    XCTAssertEqual(m.allItems.map(\.id), ["enabled", "hardcore", "spectator", "discord", "progress"])
    for item in m.allItems { XCTAssertFalse(item.description?.isEmpty ?? true, item.id) }
  }
  func test_dependentToggles_disabledWhenIntegrationOff() {
    let m = model(enabled: false)
    XCTAssertEqual(m.item(id: "enabled")?.isEnabled, true)
    for id in ["hardcore", "spectator", "discord", "progress"] { XCTAssertEqual(m.item(id: id)?.isEnabled, false, id) }
  }
  func test_toggles_emitChanges() {
    let m = model()
    let cases: [(String, AchievementsChange)] = [("enabled", .enabled(false)), ("hardcore", .hardcore(false)), ("spectator", .spectator(false)),
                                                 ("discord", .discordPresence(false)), ("progress", .progress(false))]
    for (id, change) in cases {
      guard case .toggle(let b) = m.item(id: id)?.role else { return XCTFail(id) }
      changes = []; b.wrappedValue = false; XCTAssertEqual(changes, [change], id)
    }
  }
}
