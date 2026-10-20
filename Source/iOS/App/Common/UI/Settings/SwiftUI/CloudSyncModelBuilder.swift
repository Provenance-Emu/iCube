// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVSyncRules
import SwiftUI

struct CloudSyncSnapshot {
  var isEnabled: Bool
  var isSyncing: Bool
  var unavailableReason: String?
  var lastError: String?
  var lastSyncDate: Date?
  var countsByType: [SyncableFileType: Int]
  var bytesByType: [SyncableFileType: Int64]
  var totalFiles: Int
  var formattedTotalSize: String
  var errorFiles: Int
  var pendingConflicts: Int
  var recentEvents: [(message: String, file: String?)]
}

enum CloudSyncChange: Equatable { case enabled(Bool), syncNow, clearCloudData }

/// Pure: mirrors `CloudSyncSettingsView`'s Form section for section. Read-only lines are captions.
enum CloudSyncModelBuilder {
  static func make(_ s: CloudSyncSnapshot, conflicts: AnyView, apply: @escaping (CloudSyncChange) -> Void) -> MenuModel {
    var sections: [MenuSection] = []

    var statusItems: [MenuItem] = [
      SettingsRow.toggle("enabled", L("Sync This Device"), s.isEnabled,
                         L("Keeps save states, memory cards, Wii saves and settings in step across your devices."),
                         icon: "icloud", set: { apply(.enabled($0)) }),
    ]
    if s.isEnabled {
      if let last = s.lastSyncDate {
        statusItems.append(SettingsRow.caption("last-synced", String(format: L("Last synced %@"), last.formatted(date: .abbreviated, time: .shortened))))
      }
      statusItems.append(SettingsRow.action("sync-now", L("Sync Now"), L("Runs a sync pass right away."), icon: "arrow.triangle.2.circlepath",
                                            enabled: !s.isSyncing && s.unavailableReason == nil) { apply(.syncNow) })
    }
    let footer = s.unavailableReason ?? s.lastError
      ?? L("Save states, memory cards, Wii saves and settings are kept in step across your devices. Games are never uploaded.")
    sections.append(MenuSection(id: "status", header: L("iCloud Sync"), footer: footer, items: statusItems))

    if s.isEnabled {
      if s.pendingConflicts > 0 {
        sections.append(MenuSection(id: "conflicts", header: L("Needs Your Decision"), items: [
          SettingsRow.destination("conflicts", L("Conflicts"), L("Files changed on two devices. Choose which copy to keep."),
                                  icon: "exclamationmark.icloud.fill", view: conflicts)
            .with { $0.badge = "\(s.pendingConflicts)" },
        ]))
      }
      var contents: [MenuItem] = []
      if s.totalFiles == 0 {
        contents.append(SettingsRow.caption("nothing", L("Nothing synced yet.")))
      } else {
        for type in SyncableFileType.allCases.sorted(by: { $0.pullPriority < $1.pullPriority }) {
          let count = s.countsByType[type] ?? 0
          if count > 0 {
            let bytes = ByteCountFormatter.string(fromByteCount: s.bytesByType[type] ?? 0, countStyle: .file)
            contents.append(SettingsRow.caption("type-\(type)", "\(CloudSyncSettingsView.displayName(for: type)): \(count) · \(bytes)"))
          }
        }
        contents.append(SettingsRow.caption("total", "\(L("Total")): \(s.totalFiles) · \(s.formattedTotalSize)"))
        if s.errorFiles > 0 { contents.append(SettingsRow.caption("errors", "\(L("Files With Errors")): \(s.errorFiles)")) }
      }
      sections.append(MenuSection(id: "contents", header: L("Synced Contents"), items: contents))
      sections.append(MenuSection(id: "maintenance", footer: L("Removes this app's data from iCloud. Files on this device are not touched."), items: [
        SettingsRow.destructive("clear", L("Clear iCloud Data"), L("Deletes iCube's data from iCloud. Asks first."),
                                icon: "trash", enabled: !s.isSyncing, run: { apply(.clearCloudData) }),
      ]))
      if !s.recentEvents.isEmpty {
        sections.append(MenuSection(id: "activity", header: L("Recent Activity"),
                                    items: s.recentEvents.prefix(20).enumerated().map { i, e in
                                      SettingsRow.caption("event-\(i)", e.file.map { "\(e.message) — \($0)" } ?? e.message) }))
      }
    }
    sections.append(MenuSection(id: "scope", header: L("What Is Synced"), items: [
      SettingsRow.caption("scope-1", "✓ " + L("Save states and resume points")),
      SettingsRow.caption("scope-2", "✓ " + L("GameCube memory cards")),
      SettingsRow.caption("scope-3", "✓ " + L("Wii save data")),
      SettingsRow.caption("scope-4", "✓ " + L("Settings, per-game settings and cheats")),
      SettingsRow.caption("scope-5", "✗ " + L("Games are never uploaded")),
      SettingsRow.caption("scope-6", "✓ " + L("Custom titles, covers and classification tags")),
      SettingsRow.caption("scope-7", "✓ " + L("Firmware and Wii channels sync only when enabled")),
    ]))
    return MenuModel(sections: sections)
  }
}

private extension MenuItem {
  func with(_ edit: (inout MenuItem) -> Void) -> MenuItem { var c = self; edit(&c); return c }
}
