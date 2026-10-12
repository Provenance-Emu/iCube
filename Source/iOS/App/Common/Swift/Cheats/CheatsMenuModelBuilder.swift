// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One row of the cheats pane: a Gecko or Action Replay code read through
/// `TVCheatsBridge`, flattened to plain values so the builder and its tests
/// never touch the bridge.
struct CheatItem: Equatable {
  let id: String
  let name: String
  /// Human type label, "Gecko Code" or "Action Replay".
  let type: String
  let enabled: Bool
  let isGecko: Bool
  let index: Int
  /// The `[creator]` from a downloaded Gecko header; nil when unknown.
  var creator: String? = nil
  /// Comment lines under the code, newline-joined; nil when there are none.
  var notes: String? = nil
  /// Shipped in Dolphin's bundled game ini rather than added or downloaded by the user.
  var isBuiltIn: Bool = false
  var lineCount: Int = 0

  var category: CheatCategory { CheatCategory.classify(name: name) }

  /// The first comment line that adds something the title doesn't already say.
  var summary: String? {
    guard let notes else { return nil }
    return notes.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && $0.caseInsensitiveCompare(name) != .orderedSame }
  }

  /// "Gecko · by Ralf", "Action Replay · Built-in", or just the type.
  var sourceLine: String {
    let kind = isGecko ? L("Gecko") : L("Action Replay")
    if isBuiltIn { return "\(kind) · \(L("Built-in"))" }
    if let creator, !creator.isEmpty { return "\(kind) · \(String(format: L("by %@"), creator))" }
    return kind
  }
}

/// What the list is narrowed to. `all` and `enabled` are fixed; one `category` per
/// `CheatCategory` that the game's cheats actually use.
enum CheatFilter: Hashable {
  case all
  case enabled
  case category(CheatCategory)

  private static let categoryPrefix = "category."

  /// Stable string for `MenuItemRole.cycle` selections and `@AppStorage`-style persistence.
  var id: String {
    switch self {
    case .all: return "all"
    case .enabled: return "enabled"
    case .category(let category): return Self.categoryPrefix + category.rawValue
    }
  }

  init?(id: String) {
    switch id {
    case "all": self = .all
    case "enabled": self = .enabled
    default:
      guard id.hasPrefix(Self.categoryPrefix),
            let category = CheatCategory(rawValue: String(id.dropFirst(Self.categoryPrefix.count))) else { return nil }
      self = .category(category)
    }
  }

  var title: String {
    switch self {
    case .all: return L("All")
    case .enabled: return L("On")
    case .category(let category): return category.displayName
    }
  }

  var icon: String? {
    switch self {
    case .all: return nil
    case .enabled: return "checkmark.circle.fill"
    case .category(let category): return category.icon
    }
  }

  func matches(_ cheat: CheatItem) -> Bool {
    switch self {
    case .all: return true
    case .enabled: return cheat.enabled
    case .category(let category): return cheat.category == category
    }
  }

  func count(in cheats: [CheatItem]) -> Int { cheats.filter(matches).count }

  /// `all` plus a single other filter would show the same rows twice over, so a chip
  /// row or cycle row only earns its place with at least two real alternatives.
  static func isWorthShowing(_ filters: [CheatFilter]) -> Bool { filters.count > 2 }

  /// `all`, then `enabled` when anything is on, then every category present, in
  /// `CheatCategory` order. Empty categories never get a chip.
  static func available(in cheats: [CheatItem]) -> [CheatFilter] {
    var filters: [CheatFilter] = [.all]
    if cheats.contains(where: \.enabled) { filters.append(.enabled) }
    let present = Set(cheats.map(\.category))
    filters += CheatCategory.allCases.filter(present.contains).map(CheatFilter.category)
    return filters
  }
}

// MARK: - D18 model (shared by iOS and tvOS — see `CheatsMenuView.cheatsMenuModel`)

/// Plain snapshot — no `TVCheatsBridge` reads inside `CheatsMenuModelBuilder`,
/// so it is constructible from a test with a synthetic cheat list.
struct CheatsMenuState {
  var cheatsEnabledGlobal: Bool
  /// Every cheat after the host's text search, before `filter`.
  var cheats: [CheatItem]
  var filter: CheatFilter = .all
  var fetchStatus: CheatFetchStatus = .idle
  var lastFetch: Date? = nil
  /// tvOS: put a "Show" cycle row in the model, since that platform has no chip row
  /// (one control per row, per the menu engine's tvOS contract). iOS draws
  /// `CheatFilterChips` as host chrome instead and leaves this false.
  var showsFilterRow: Bool = false
}

/// Plain closures — no `TVCheatsBridge`/`DOLConfigBridge` calls inside
/// `CheatsMenuModelBuilder` either. Mirrors `ControllerAssignmentService`'s
/// "provider, not inline bridge calls" split (design doc §1).
struct CheatsMenuActions {
  var setEnabledGlobal: (Bool) -> Void
  var requestEnableGlobalCheats: (CheatItem) -> Void
  var toggleCheat: (CheatItem) -> Void
  var downloadCheats: () -> Void
  var refreshCheats: () -> Void
  var setFilter: (CheatFilter) -> Void = { _ in }
}

enum CheatsMenuModelBuilder {
  static let filterItemID = "filter"
  static let downloadItemID = "download-cheats"

  /// `typeAsBadge`: tvOS shows the Gecko/Action Replay type as the row's trailing badge (no subtitle, no category badge).
  static func make(state: CheatsMenuState, actions: CheatsMenuActions, typeAsBadge: Bool = false) -> MenuModel {
    var sections: [MenuSection] = []

    sections.append(MenuSection(id: "enable", items: [
      MenuItem(
        id: "enable-cheats",
        title: L("Enable Cheats"),
        role: .toggle(Binding(
          get: { state.cheatsEnabledGlobal },
          set: { actions.setEnabledGlobal($0) }
        ))
      ),
    ]))

    // Always shown, even with zero cheats — fixed here (was gated on
    // `hasAnyCheats` in the D18 proof-of-life pass, verbatim from the
    // pre-D18 iOS body it replaced): Download is the ONLY way to bootstrap
    // cheats for a game that doesn't have any yet, on either platform, so
    // hiding it made a fresh game's cheats unreachable — invisible on iOS
    // (no other affordance existed there either) but a real regression for
    // tvOS's pre-D18 bespoke body, which always showed Download regardless.
    // Since the on-demand fetch it is the manual retry/refresh; the footer
    // carries the fetch status so the row itself stays a plain action.
    let canDownload = state.fetchStatus != .fetching && state.fetchStatus != .unavailable
    sections.append(MenuSection(id: "actions", footer: fetchFooter(state), items: [
      MenuItem(
        id: downloadItemID,
        title: L("Download Cheats"),
        subtitle: state.fetchStatus == .fetching ? L("Fetching…") : nil,
        icon: "arrow.down.circle",
        role: .action(actions.downloadCheats),
        isEnabled: canDownload
      ),
      MenuItem(id: "refresh-cheats", title: L("Refresh List"), role: .action(actions.refreshCheats)),
    ]))

    let filters = CheatFilter.available(in: state.cheats)
    if state.showsFilterRow, CheatFilter.isWorthShowing(filters) {
      sections.append(MenuSection(id: "filter", items: [filterItem(state: state, actions: actions, filters: filters)]))
    }

    let visible = state.cheats.filter(state.filter.matches)
    if state.cheats.isEmpty {
      sections.append(MenuSection(id: "empty", items: [
        MenuItem(id: "empty-state", title: L("No Cheats Available"), role: .custom(emptyStateView), isEnabled: false),
      ]))
    } else if visible.isEmpty {
      sections.append(MenuSection(id: "empty", items: [
        MenuItem(id: "empty-filter", title: L("No cheats match this filter"), role: .action {}, isEnabled: false),
      ]))
    } else {
      let header = state.filter == .all ? L("Cheat Codes") : "\(state.filter.title) · \(visible.count)"
      sections.append(MenuSection(id: "cheats", header: header, items: visible.map { cheat in
        MenuItem(
          id: "cheat-\(cheat.id)",
          title: cheat.name,
          subtitle: typeAsBadge ? nil : cheat.sourceLine,
          role: .toggle(Binding(
            get: { cheat.enabled },
            set: { newValue in
              if newValue, !state.cheatsEnabledGlobal {
                actions.requestEnableGlobalCheats(cheat)
              } else {
                actions.toggleCheat(cheat)
              }
            }
          )),
          badge: typeAsBadge ? cheat.type : (cheat.category == .other ? nil : cheat.category.displayName),
          description: cheat.summary
        )
      }))
    }
    return MenuModel(sections: sections)
  }

  /// The tvOS "Show" row: d-pad left/right (or A) steps through the available filters.
  private static func filterItem(state: CheatsMenuState, actions: CheatsMenuActions, filters: [CheatFilter]) -> MenuItem {
    let options: [(String, AnyHashable)] = filters.map { filter in
      ("\(filter.title) (\(filter.count(in: state.cheats)))", AnyHashable(filter.id))
    }
    let current = filters.contains(state.filter) ? state.filter : .all
    return MenuItem(
      id: filterItemID,
      title: L("Show"),
      icon: "line.3.horizontal.decrease.circle",
      role: .cycle(
        options: options,
        selection: Binding(
          get: { AnyHashable(current.id) },
          set: { newValue in
            if let id = newValue as? String, let filter = CheatFilter(id: id) { actions.setFilter(filter) }
          }
        )
      ),
      description: L("Narrow the list to one kind of cheat.")
    )
  }

  /// One line under the Download/Refresh rows describing the last on-demand fetch.
  static func fetchFooter(_ state: CheatsMenuState) -> String {
    switch state.fetchStatus {
    case .fetching:
      return L("Fetching codes from codes.rc24.xyz…")
    case .fetched(let downloaded, let added):
      if downloaded == 0 { return L("No community codes for this game yet.") }
      if added == 0 { return String(format: L("%d codes available, nothing new."), downloaded) }
      return String(format: L("%d codes available, %d new."), downloaded, added)
    case .failed:
      return L("Couldn't reach codes.rc24.xyz. Tap Download Cheats to retry.")
    case .unavailable:
      return L("This title has no GameTDB ID, so codes can't be downloaded.")
    case .idle:
      if let lastFetch = state.lastFetch {
        return String(format: L("Last downloaded %@."), Self.relativeFormatter.localizedString(for: lastFetch, relativeTo: Date()))
      }
      return L("Codes download automatically from codes.rc24.xyz.")
    }
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  private static var emptyStateView: AnyView {
    AnyView(
      VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        Image(systemName: "gamecontroller")
          .font(ICubeDesign.symbolFont(.tile))
          .foregroundStyle(ICubeDesign.color(.textSecondary))
        Text(L("No Cheats Available")).icubeText(.body).fontWeight(.semibold)
        Text(L("Codes download automatically when this game has any."))
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
    )
  }
}
