// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsSearchHit: Hashable {
  let entryID: String
  /// The matching row inside a migrated leaf, or nil when the leaf itself matched.
  let rowTitle: String?
}

/// Generated from the root entries and, for migrated leaves, their row titles and descriptions
/// (a hand-built leaf has no model, so only its keywords count). Built once when Settings appears:
/// walking four models per keystroke is wasted work.
struct SettingsSearchIndex {
  private struct Row {
    let hit: SettingsSearchHit
    let terms: [String]
  }

  private let rows: [Row]

  init(sections: [SettingsRootSection]) {
    var rows: [Row] = []
    for entry in sections.flatMap(\.entries) {
      rows.append(Row(hit: SettingsSearchHit(entryID: entry.id, rowTitle: nil), terms: [entry.title, entry.description] + entry.keywords))
      guard let model = entry.makeModel?() else { continue }
      for item in model.allItems {
        rows.append(Row(hit: SettingsSearchHit(entryID: entry.id, rowTitle: item.title), terms: [item.title, item.description ?? ""]))
      }
    }
    self.rows = rows
  }

  func hits(query: String) -> [SettingsSearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    return rows.filter { row in row.terms.contains { $0.localizedCaseInsensitiveContains(q) } }.map(\.hit)
  }
}

/// Search results, shared by the iPhone list and the iPad sidebar.
struct SettingsSearchResults: View {
  let hits: [SettingsSearchHit]
  let entries: [SettingsLeafEntry]
  let onSelect: (SettingsLeafEntry) -> Void

  var body: some View {
    List(hits, id: \.self) { hit in
      if let entry = entries.first(where: { $0.id == hit.entryID }) {
        Button { onSelect(entry) } label: {
          VStack(alignment: .leading, spacing: 2) {
            Label(entry.title, systemImage: entry.icon)
            if let row = hit.rowTitle { Text(row).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
    }
  }
}
