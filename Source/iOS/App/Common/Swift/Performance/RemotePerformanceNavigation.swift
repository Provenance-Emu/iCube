// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Manual remote focus: this deliberately does not participate in tvOS gamepad focus.
struct RemotePerformanceNavigation: Equatable {
  struct Row: Equatable {
    let id: String
    var enabled = true
  }
  private var rows: [Row] = []
  private(set) var selectedID: String?
  private(set) var choiceIndex: Int?
  private var choiceCount = 0

  mutating func reconcile(_ updated: [Row]) {
    rows = updated
    if !rows.contains(where: { $0.id == selectedID && $0.enabled }) {
      selectedID = rows.first(where: \.enabled)?.id
      cancelChoices()
    }
  }

  mutating func move(_ delta: Int) {
    let direction = delta.signum()
    guard direction != 0 else { return }
    if let choiceIndex {
      self.choiceIndex = min(choiceCount - 1, max(0, choiceIndex + direction))
      return
    }
    let enabled = rows.filter(\.enabled)
    guard !enabled.isEmpty else { selectedID = nil; return }
    let index = enabled.firstIndex(where: { $0.id == selectedID }) ?? 0
    selectedID = enabled[min(enabled.count - 1, max(0, index + direction))].id
  }

  mutating func openChoices(for id: String, count: Int, selected: Int) {
    guard selectedID == id, count > 0,
          rows.contains(where: { $0.id == id && $0.enabled }) else { cancelChoices(); return }
    choiceCount = count
    choiceIndex = min(count - 1, max(0, selected))
  }

  mutating func cancelChoices() {
    choiceIndex = nil
    choiceCount = 0
  }
}
