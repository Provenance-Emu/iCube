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
  /// An id the host wants focused after a rebuild. On iOS it only applies when the rebuild MOVED the focused
  /// row (`MenuFocusRouter.reconcile`) and never overrides a focused id that still exists. On tvOS the
  /// `MenuScreen` handler applies it under the same rule: only when the focused row is gone and the requested one exists.
  var focusRequest: String?

  init(sections: [MenuSection] = [], focusRequest: String? = nil) {
    self.sections = sections
    self.focusRequest = focusRequest
  }
}

struct MenuSection: Identifiable {
  /// Stable, e.g. `"gc-players"` — not `UUID()`. See `MenuItem.id`.
  let id: String
  var header: String?
  /// Explanatory text under the section (a `List` footer).
  var footer: String?
  var items: [MenuItem]

  init(id: String, header: String? = nil, footer: String? = nil, items: [MenuItem]) {
    self.id = id
    self.header = header
    self.footer = footer
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
  /// `.custom` rows only: what a controller's A does on iOS. A `.custom` row carries its own touch
  /// and tvOS gestures, so `MenuScreen` cannot activate it by itself; without this a pad could focus
  /// the player screen's capture rows but never arm one.
  var onCustomActivate: (() -> Void)?
  /// `.picker` rows only, tvOS only: ONE row showing the title and the current value, which d-pad
  /// left/right steps through, instead of one row per option. For long value lists (the player
  /// screen's numeric settings), which would otherwise explode into ~20 rows each.
  var isCompactOnTV: Bool = false
  /// One line shown in the info shelf while the item is focused.
  var description: String?
  var longPress: MenuLongPress?
  /// Draws a trailing chevron in a list row, for a row that opens another screen.
  var showsChevron: Bool = false

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    tint: Color? = nil,
    role: MenuItemRole,
    badge: String? = nil,
    isEnabled: Bool = true,
    onCustomActivate: (() -> Void)? = nil,
    isCompactOnTV: Bool = false,
    description: String? = nil,
    longPress: MenuLongPress? = nil,
    showsChevron: Bool = false
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.tint = tint
    self.role = role
    self.badge = badge
    self.isEnabled = isEnabled
    self.onCustomActivate = onCustomActivate
    self.isCompactOnTV = isCompactOnTV
    self.description = description
    self.longPress = longPress
    self.showsChevron = showsChevron
  }
}

/// A numeric setting: a `Slider` row on iOS, a left/right stepper row on tvOS (spec §6.3).
/// `Double`-backed on purpose: Int settings round through it, and `stepped` snaps to the grid.
struct MenuStepper {
  var value: Binding<Double>
  var range: ClosedRange<Double>
  var step: Double
  var format: (Double) -> String

  /// Digits kept when snapping: enough for any step this app uses (0.1 minimum) and few enough that
  /// `0.1 * 3` comes back as exactly `0.3`.
  private static let snapPrecision = 1_000_000.0

  /// `current` moved one `step` in `direction` (+1 / -1), clamped to `range`, then snapped to the
  /// grid `range.lowerBound + n * step`.
  ///
  /// A bound that is off the grid (`0 ... 100` step 30) is still reachable: stepping toward it from
  /// the last grid point lands on the bound, and stepping away from the upper bound lands on the
  /// last grid point below it.
  func stepped(_ current: Double, by direction: Int) -> Double {
    let raw = current + Double(direction) * step
    if raw >= range.upperBound { return range.upperBound }
    if raw <= range.lowerBound { return range.lowerBound }
    if direction < 0, current >= range.upperBound {
      let lastGridIndex = ((range.upperBound - range.lowerBound) / step - Self.gridTolerance).rounded(.up) - 1
      return Self.snap(range.lowerBound + lastGridIndex * step)
    }
    let onGrid = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
    return min(range.upperBound, max(range.lowerBound, Self.snap(onGrid)))
  }

  /// Slack so an upper bound that is exactly on the grid is not mistaken for an off-grid one.
  private static let gridTolerance = 1e-9

  private static func snap(_ value: Double) -> Double {
    (value * snapPrecision).rounded() / snapPrecision
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
  /// a shader thumbnail, a capture row) — `MenuScreen` renders it and
  /// otherwise leaves it alone. A controller's A reaches it only through the
  /// item's `onCustomActivate`.
  case custom(AnyView)
  case destructive(() -> Void)
  /// Activate advances to the next option and wraps; the tile shows the current option as its badge.
  /// A long-press opens the full list. Unlike `.picker`, this never explodes into rows on tvOS.
  case cycle(options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  /// A numeric value: a slider on iOS, left/right steps on tvOS. A does nothing; left/right adjust,
  /// and hold repeats.
  case stepper(MenuStepper)
}

/// What a long-press of A (or a touch long-press) on an item does (unified menu UX spec §4.2).
enum MenuLongPress {
  /// A picker of every value; the `.cycle` role derives this from its own options.
  case options(title: String, options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  /// Something else, e.g. the Shaders tile opening the full picker.
  case action(() -> Void)
}

extension MenuItem {
  /// The explicit long-press, else the one a `.cycle` role implies.
  var effectiveLongPress: MenuLongPress? {
    if let longPress { return longPress }
    if case .cycle(let options, let selection) = role {
      return .options(title: title, options: options, selection: selection)
    }
    return nil
  }

  /// The value a tile badge shows. `"—"` for a cycle/picker whose value matches no option (spec §8).
  var currentValueTitle: String? {
    switch role {
    case .cycle(let options, let selection), .picker(let options, let selection):
      return MenuItemRole.selectedTitle(options: options, current: selection.wrappedValue) ?? "—"
    case .toggle(let binding):
      return binding.wrappedValue ? L("On") : L("Off")
    case .stepper(let stepper):
      return stepper.format(stepper.value.wrappedValue)
    default:
      return nil
    }
  }
}

extension MenuModel {
  /// Applies a controller left/right step to the item `id`, resolved from THIS model: a held stepper
  /// repeats up to ~12 times a second, and every step must read the value as it is now, not as it was
  /// when the hold began. A stepper moves on its grid; a picker or cycle row wraps through its options.
  func applyAdjust(id: String, step: Int) {
    guard let item = item(id: id), item.isEnabled else { return }
    if case .stepper(let stepper) = item.role {
      stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: step)
    } else if let stepping = item.role.steppable,
              let next = MenuItemRole.cycled(options: stepping.options, current: stepping.selection.wrappedValue, step: step) {
      stepping.selection.wrappedValue = next
    }
  }
}

extension MenuItemRole {
  /// The options and selection of a role d-pad left/right steps through (`.picker`, `.cycle`).
  var steppable: (options: [(String, AnyHashable)], selection: Binding<AnyHashable>)? {
    switch self {
    case .picker(let options, let selection), .cycle(let options, let selection): return (options, selection)
    default: return nil
    }
  }

  /// The option `step` places after `current`, wrapping both ways. An unknown `current` starts
  /// from before the first option, so +1 lands on the first. `nil` when there are no options.
  static func cycled(options: [(String, AnyHashable)], current: AnyHashable, step: Int) -> AnyHashable? {
    guard !options.isEmpty else { return nil }
    let index = options.firstIndex { $0.1 == current } ?? -1
    let count = options.count
    return options[((index + step) % count + count) % count].1
  }

  /// The title of the option `current` selects, or nil when no option matches.
  static func selectedTitle(options: [(String, AnyHashable)], current: AnyHashable) -> String? {
    options.first { $0.1 == current }?.0
  }
}

// MARK: - Lookup

/// Pure model queries — no SwiftUI, no bridges — the surface the design
/// doc's §7 "model unit tests" and `MenuFocusRouter` exercise.
extension MenuModel {
  /// All items across all sections, in on-screen order.
  var allItems: [MenuItem] { sections.flatMap(\.items) }

  /// Ids of items that can currently receive focus/activation, in on-screen
  /// order — disabled items are skipped.
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
