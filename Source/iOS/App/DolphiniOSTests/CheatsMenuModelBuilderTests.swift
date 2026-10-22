// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class CheatsMenuModelBuilderTests: XCTestCase {
  private func actions(
    setEnabledGlobal: @escaping (Bool) -> Void = { _ in },
    requestEnableGlobalCheats: @escaping (CheatItem) -> Void = { _ in },
    toggleCheat: @escaping (CheatItem) -> Void = { _ in },
    downloadCheats: @escaping () -> Void = {},
    refreshCheats: @escaping () -> Void = {},
    setFilter: @escaping (CheatFilter) -> Void = { _ in },
    openSearch: (() -> Void)? = nil
  ) -> CheatsMenuActions {
    CheatsMenuActions(
      setEnabledGlobal: setEnabledGlobal,
      requestEnableGlobalCheats: requestEnableGlobalCheats,
      toggleCheat: toggleCheat,
      downloadCheats: downloadCheats,
      refreshCheats: refreshCheats,
      setFilter: setFilter,
      openSearch: openSearch
    )
  }

  private func cheat(_ id: String, name: String? = nil, enabled: Bool = false) -> CheatItem {
    CheatItem(id: id, name: name ?? "Cheat \(id)", type: "Gecko Code", enabled: enabled, isGecko: true, index: 0)
  }

  // MARK: Download/Refresh always reachable (regression)

  /// Download is the ONLY way to bootstrap cheats for a game that has none
  /// yet. The D18 iOS proof-of-life pass gated the actions section on
  /// `hasAnyCheats`, verbatim from the pre-D18 iOS body -- harmless there
  /// only because iOS never had another way to reach Download either, but a
  /// real regression the moment tvOS (whose pre-D18 bespoke body always
  /// showed Download) shares this same builder. Fixed here: the actions
  /// section is unconditional.
  func test_zeroCheats_downloadAndRefreshStillFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertTrue(model.focusableIDs.contains("download-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("refresh-cheats"))
  }

  func test_withCheats_downloadAndRefreshStillFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertTrue(model.focusableIDs.contains("download-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("refresh-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("cheat-gecko_0"))
  }

  // MARK: Empty state

  func test_zeroCheats_emptyStateIsPresentButNotFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    let emptyItem = model.item(id: "empty-state")
    XCTAssertNotNil(emptyItem)
    XCTAssertEqual(emptyItem?.isEnabled, false, "the empty-state row is not itself focusable/activatable")
    XCTAssertFalse(model.focusableIDs.contains("empty-state"))
  }

  // MARK: Enable-cheats intercept (toggle binding's setter)

  /// Toggling a cheat ON while global cheats are disabled must request the
  /// enable-prompt instead of toggling the cheat directly.
  func test_toggleCheatOn_whileGlobalDisabled_requestsEnablePromptInsteadOfToggling() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: false, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = true
    XCTAssertEqual(requested?.id, "gecko_0")
    XCTAssertNil(toggled, "must not toggle directly while global cheats are off")
  }

  /// Same toggle-on, but with global cheats already enabled: toggles
  /// directly, no enable-prompt.
  func test_toggleCheatOn_whileGlobalEnabled_togglesDirectly() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = true
    XCTAssertNil(requested)
    XCTAssertEqual(toggled?.id, "gecko_0")
  }

  /// Toggling a cheat OFF never needs the prompt, even with global cheats
  /// disabled -- only turning one ON requires cheats to be enabled first.
  func test_toggleCheatOff_neverRequestsEnablePrompt() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: false, cheats: [cheat("gecko_0", enabled: true)])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = false
    XCTAssertNil(requested)
    XCTAssertEqual(toggled?.id, "gecko_0")
  }

  // MARK: tvOS type badge

  func test_typeAsBadge_movesTypeFromSubtitleToBadge() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions(), typeAsBadge: true)
    let item = model.item(id: "cheat-gecko_0")
    XCTAssertEqual(item?.badge, "Gecko Code")
    XCTAssertNil(item?.subtitle)
  }

  func test_defaultKeepsTypeAsSubtitle() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    let item = model.item(id: "cheat-gecko_0")
    XCTAssertEqual(item?.subtitle, "Gecko")
    XCTAssertNil(item?.badge)
  }

  // MARK: Labels

  func test_cheatRow_carriesSourceSubtitle_categoryBadge_andNotesDescription() {
    var item = cheat("g0", name: "Infinite Lives")
    item.creator = "Ralf"
    item.notes = "Infinite Lives\nPress Z to refill"
    let model = CheatsMenuModelBuilder.make(state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [item]), actions: actions())
    let row = model.item(id: "cheat-g0")
    XCTAssertEqual(row?.subtitle, "Gecko · by Ralf")
    XCTAssertEqual(row?.badge, CheatCategory.infinite.displayName)
    XCTAssertEqual(row?.description, "Press Z to refill")
  }

  func test_cheatRow_otherCategoryHasNoBadge() {
    let model = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("g0", name: "Moon Jump")]), actions: actions())
    XCTAssertNil(model.item(id: "cheat-g0")?.badge)
  }

  // MARK: Filter

  func test_filter_narrowsCheatRows_andTitlesTheSection() {
    let cheats = [cheat("g0", name: "Infinite Lives"), cheat("g1", name: "Moon Jump"), cheat("g2", name: "Infinite Ammo")]
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, filter: .category(.infinite))
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertNotNil(model.item(id: "cheat-g0"))
    XCTAssertNil(model.item(id: "cheat-g1"))
    XCTAssertNotNil(model.item(id: "cheat-g2"))
    XCTAssertEqual(model.section(containing: "cheat-g0")?.header, "\(CheatCategory.infinite.displayName) · 2")
  }

  func test_filter_enabled_showsOnlyActiveCheats() {
    let cheats = [cheat("g0", enabled: true), cheat("g1")]
    let model = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, filter: .enabled), actions: actions())
    XCTAssertNotNil(model.item(id: "cheat-g0"))
    XCTAssertNil(model.item(id: "cheat-g1"))
  }

  func test_filter_withNoMatches_showsNonFocusableEmptyFilterRow_notTheNoCheatsState() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("g0", name: "Moon Jump")], filter: .category(.debug))
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertNotNil(model.item(id: "empty-filter"))
    XCTAssertNil(model.item(id: "empty-state"))
    XCTAssertFalse(model.focusableIDs.contains("empty-filter"))
  }

  /// iOS draws chips as host chrome; only tvOS asks for the in-model cycle row.
  func test_filterRow_onlyWhenRequested_andOnlyWithSomethingToFilter() {
    let cheats = [cheat("g0", name: "Infinite Lives"), cheat("g1", name: "Moon Jump")]
    let hidden = CheatsMenuModelBuilder.make(state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats), actions: actions())
    XCTAssertNil(hidden.item(id: CheatsMenuModelBuilder.filterItemID))

    let shown = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, showsFilterRow: true), actions: actions())
    XCTAssertTrue(shown.focusableIDs.contains(CheatsMenuModelBuilder.filterItemID))

    let single = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("g0", name: "Moon Jump")], showsFilterRow: true), actions: actions())
    XCTAssertNil(single.item(id: CheatsMenuModelBuilder.filterItemID), "one category means nothing to filter")
  }

  func test_filterRow_cycleOptionsCarryCounts_andSelectionCallsSetFilter() {
    var chosen: CheatFilter?
    let cheats = [cheat("g0", name: "Infinite Lives", enabled: true), cheat("g1", name: "Moon Jump")]
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, filter: .category(.infinite), showsFilterRow: true)
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions(setFilter: { chosen = $0 }))
    guard case .cycle(let options, let selection) = model.item(id: CheatsMenuModelBuilder.filterItemID)?.role else {
      return XCTFail("expected a cycle role")
    }
    XCTAssertEqual(options.map(\.0), ["All (2)", "On (1)", "Infinite (1)", "Other (1)"])
    XCTAssertEqual(selection.wrappedValue, AnyHashable(CheatFilter.category(.infinite).id))
    selection.wrappedValue = AnyHashable(CheatFilter.enabled.id)
    XCTAssertEqual(chosen, .enabled)
  }

  // MARK: tvOS search row (regression: search and filter were unreachable under a long list)

  /// With a host search action the model LEADS with Search and the Show filter, so the remote
  /// lands on them first; the filter leaves its own later section to sit beside Search.
  func test_searchRow_leadsTheModel_withTheFilterBesideIt_onlyWhenTheHostOpensSearch() {
    let cheats = [cheat("g0", name: "Infinite Lives", enabled: true), cheat("g1", name: "Moon Jump")]
    var opened = 0
    let tv = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, showsFilterRow: true),
      actions: actions(openSearch: { opened += 1 }))
    XCTAssertEqual(tv.sections.first?.id, "find")
    XCTAssertEqual(tv.sections.first?.items.map(\.id), [CheatsMenuModelBuilder.searchItemID, CheatsMenuModelBuilder.filterItemID])
    XCTAssertEqual(tv.focusableIDs.first, CheatsMenuModelBuilder.searchItemID)
    XCTAssertNil(tv.sections.first(where: { $0.id == "filter" }), "the filter moved into the find section")
    XCTAssertTrue(tv.item(id: CheatsMenuModelBuilder.searchItemID)?.activateInPlace() ?? false)
    XCTAssertEqual(opened, 1)

    let ios = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, showsFilterRow: true), actions: actions())
    XCTAssertNil(ios.item(id: CheatsMenuModelBuilder.searchItemID), "iOS keeps search in .searchable")
    XCTAssertEqual(ios.section(containing: CheatsMenuModelBuilder.filterItemID)?.id, "filter", "iOS placement unchanged")
  }

  func test_searchRow_badgeShowsTheQuery_andTheListHeaderCountsMatches() {
    let cheats = [cheat("g0", name: "Infinite Lives"), cheat("g1", name: "Moon Jump")]
    let idle = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: cheats, searchText: "  "), actions: actions(openSearch: {}))
    XCTAssertNil(idle.item(id: CheatsMenuModelBuilder.searchItemID)?.badge, "whitespace is no query")
    XCTAssertEqual(idle.section(containing: "cheat-g0")?.header, L("Cheat Codes"))

    // The host narrows `cheats` before building; the model only reports what it was given.
    let searching = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheats[1]], searchText: "moon"), actions: actions(openSearch: {}))
    XCTAssertEqual(searching.item(id: CheatsMenuModelBuilder.searchItemID)?.badge, "moon")
    XCTAssertEqual(searching.section(containing: "cheat-g1")?.header, String(format: L("%1$ld matching “%2$@”"), 1, "moon"))
  }

  // MARK: Fetch status

  func test_download_disabledWhileFetching_andWhenUnavailable() {
    let fetching = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [], fetchStatus: .fetching), actions: actions())
    XCTAssertFalse(fetching.focusableIDs.contains(CheatsMenuModelBuilder.downloadItemID))
    XCTAssertEqual(fetching.item(id: CheatsMenuModelBuilder.downloadItemID)?.subtitle, "Fetching…")

    let unavailable = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [], fetchStatus: .unavailable), actions: actions())
    XCTAssertFalse(unavailable.focusableIDs.contains(CheatsMenuModelBuilder.downloadItemID))

    let failed = CheatsMenuModelBuilder.make(
      state: CheatsMenuState(cheatsEnabledGlobal: true, cheats: [], fetchStatus: .failed), actions: actions())
    XCTAssertTrue(failed.focusableIDs.contains(CheatsMenuModelBuilder.downloadItemID), "a failure leaves Download as the retry")
  }

  func test_fetchFooter_describesEachStatus() {
    func footer(_ status: CheatFetchStatus, lastFetch: Date? = nil) -> String {
      let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [], fetchStatus: status, lastFetch: lastFetch)
      let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
      return model.section(containing: CheatsMenuModelBuilder.downloadItemID)?.footer ?? ""
    }
    XCTAssertEqual(footer(.fetching), "Fetching codes from codes.rc24.xyz…")
    XCTAssertEqual(footer(.fetched(downloaded: 0, added: 0)), "No community codes for this game yet.")
    XCTAssertEqual(footer(.fetched(downloaded: 12, added: 0)), "12 codes available, nothing new.")
    XCTAssertEqual(footer(.fetched(downloaded: 12, added: 3)), "12 codes available, 3 new.")
    XCTAssertEqual(footer(.failed), "Couldn't reach codes.rc24.xyz. Tap Download Cheats to retry.")
    XCTAssertEqual(footer(.unavailable), "This title has no GameTDB ID, so codes can't be downloaded.")
    XCTAssertEqual(footer(.idle), "Codes download automatically from codes.rc24.xyz.")
    XCTAssertTrue(footer(.idle, lastFetch: Date().addingTimeInterval(-3600)).hasPrefix("Last downloaded "))
  }
}
