// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// D18 (`docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`): a
/// data-driven description of one menu screen, rendered by `MenuScreen`.
///
/// Builders take a plain snapshot struct + an actions struct and return a
/// `MenuModel` — never reach into a bridge (`DOLConfigBridge`,
/// `TVControllerMappingBridge`, `TVCheatsBridge`, …) directly. That is what
/// makes every builder unit-testable with no core/bridge involvement (design
/// doc §1, mirroring `ControllerAssignmentService`'s `ControllerConfigWriting`
/// protocol split).
struct MenuModel {
  var sections: [MenuSection]

  init(sections: [MenuSection] = []) {
    self.sections = sections
  }
}

struct MenuSection: Identifiable {
  /// Stable, e.g. `"gc-players"` — not `UUID()`. See `MenuItem.id`.
  let id: String
  var header: String?
  var items: [MenuItem]

  init(id: String, header: String? = nil, items: [MenuItem]) {
    self.id = id
    self.header = header
    self.items = items
  }
}

struct MenuItem: Identifiable {
  /// Stable, e.g. `"resume"`, `"gc-port-2"`, `"cheat-\(cheat.id)"` — **not**
  /// `UUID()`. `MenuScreen` tracks the focused id, resolving it to an index
  /// only at render/move time, so focus survives a model rebuild (a toggle
  /// flips a title, a badge count changes, a platform-conditional row
  /// appears) instead of the `ForEach`-keyed-on-offset anti-pattern this
  /// replaces (design doc §1).
  let id: String
  var title: String
  var subtitle: String?
  /// SF Symbol name.
  var icon: String?
  var tint: Color?
  var role: MenuItemRole
  /// Pre-formatted, e.g. "3 active" — never computed in `body`. See design
  /// doc §8 "Badge cost": a badge is a snapshot taken when the model is
  /// built, not a live read on every render.
  var badge: String?
  var isEnabled: Bool = true

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    tint: Color? = nil,
    role: MenuItemRole,
    badge: String? = nil,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.tint = tint
    self.role = role
    self.badge = badge
    self.isEnabled = isEnabled
  }
}

enum MenuItemRole {
  case action(() -> Void)
  case toggle(Binding<Bool>)
  case picker(options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  /// Pushes a child `MenuScreen` built lazily (the child's own model may
  /// depend on state that changed since the parent model was built).
  case navigation(() -> MenuModel)
  /// Adapter escape hatch — Settings' 15 plain `Form`/`List` leaf screens
  /// stay untouched behind this (design doc §4's "Not modeled" section).
  case destination(AnyView)
  /// Opaque leaf with its own gesture handling (a save-state filmstrip card,
  /// a shader thumbnail) — `MenuScreen` renders it and otherwise leaves it
  /// alone; it does not intercept controller-activate for this role.
  case custom(AnyView)
  case destructive(() -> Void)
}

// MARK: - Lookup

/// Pure model queries — no SwiftUI, no bridges — the surface the design
/// doc's §7 "model unit tests" and `MenuFocusRouter` exercise.
extension MenuModel {
  /// All items across all sections, in on-screen order.
  var allItems: [MenuItem] { sections.flatMap(\.items) }

  /// Ids of items that can currently receive focus/activation, in on-screen
  /// order — disabled items are skipped, matching `RemapPlayerView`'s
  /// `.disabled` sections never appearing in `focusOrder`.
  var focusableIDs: [String] { allItems.filter(\.isEnabled).map(\.id) }

  func item(id: String) -> MenuItem? {
    allItems.first { $0.id == id }
  }

  /// The section that contains `itemID`, if any.
  func section(containing itemID: String) -> MenuSection? {
    sections.first { section in section.items.contains { $0.id == itemID } }
  }

  func sectionIndex(containing itemID: String) -> Int? {
    sections.firstIndex { section in section.items.contains { $0.id == itemID } }
  }

  /// First focusable item id of the section `offset` sections away from
  /// `itemID`'s section — or `nil` when `itemID`'s section is already at that
  /// end of the section array. `nil` here means "no-op": the caller
  /// (`MenuFocusRouter`) leaves focus exactly where it was, matching
  /// `movePauseFocus`'s existing clamp behaviour (`PauseMenuView.swift:497`,
  /// which this is designed to replace) — a shoulder press at the last
  /// section must not reset focus to that section's first item. Used by the
  /// L1/R1 shoulder jump (design doc §2). Skips sections with no focusable
  /// items in the jump direction rather than landing nowhere.
  func firstFocusableID(sectionOffsetFrom itemID: String, by offset: Int) -> String? {
    guard offset != 0, !sections.isEmpty else { return focusableIDs.first }
    guard let current = sectionIndex(containing: itemID) else { return focusableIDs.first }
    let target = current + offset
    guard target >= 0, target < sections.count else { return nil }
    let range = offset > 0 ? Array(target ..< sections.count) : Array((0 ... target).reversed())
    for index in range {
      if let id = sections[index].items.first(where: \.isEnabled)?.id {
        return id
      }
    }
    return nil
  }
}
