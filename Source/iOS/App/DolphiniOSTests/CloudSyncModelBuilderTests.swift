import PVSyncRules
import SwiftUI
import XCTest
@testable import iCube

final class CloudSyncModelBuilderTests: XCTestCase {
  private var changes: [CloudSyncChange] = []
  private func snap(enabled: Bool = true, syncing: Bool = false, reason: String? = nil, conflicts: Int = 0) -> CloudSyncSnapshot {
    CloudSyncSnapshot(isEnabled: enabled, isSyncing: syncing, unavailableReason: reason, lastError: nil, lastSyncDate: nil,
                      countsByType: [.saveState: 3], bytesByType: [.saveState: 2048], totalFiles: 3, formattedTotalSize: "2 KB",
                      errorFiles: 0, pendingConflicts: conflicts, recentEvents: [])
  }
  private func model(_ s: CloudSyncSnapshot) -> MenuModel {
    CloudSyncModelBuilder.make(s, conflicts: AnyView(EmptyView())) { self.changes.append($0) }
  }

  func test_disabled_showsOnlyStatusAndScope() {
    XCTAssertEqual(model(snap(enabled: false)).sections.map(\.id), ["status", "scope"])
  }
  func test_unavailableReason_disablesSyncNow_andIsTheFooter() {
    let m = model(snap(reason: "No iCloud account"))
    XCTAssertEqual(m.item(id: "sync-now")?.isEnabled, false)
    XCTAssertEqual(m.sections[0].footer, "No iCloud account")
  }
  func test_conflicts_sectionAppearsWithCount() {
    let m = model(snap(conflicts: 2))
    XCTAssertTrue(m.sections.map(\.id).contains("conflicts"))
    XCTAssertEqual(m.item(id: "conflicts")?.badge, "2")
  }
  func test_toggle_syncNow_clear_emitChanges() {
    let m = model(snap())
    guard case .toggle(let b) = m.item(id: "enabled")?.role else { return XCTFail() }
    b.wrappedValue = false
    guard case .action(let sync) = m.item(id: "sync-now")?.role else { return XCTFail() }
    sync()
    guard case .destructive(let clear) = m.item(id: "clear")?.role else { return XCTFail() }
    clear()
    XCTAssertEqual(changes, [.enabled(false), .syncNow, .clearCloudData])
  }
}
