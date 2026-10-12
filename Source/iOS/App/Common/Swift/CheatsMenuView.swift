// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

#if os(iOS)
#endif

struct CheatsMenuView: View {
  let game: TVGameItem
  let onBack: () -> Void

  @State private var geckoCodeList: [TVGeckoCodeInfo] = []
  @State private var actionReplayCodeList: [TVActionReplayCodeInfo] = []
  @State private var searchText: String = ""
  @State private var filter: CheatFilter = .all
  @State private var fetchStatus: CheatFetchStatus = .idle
  @State private var lastFetch: Date? = nil

  /// Tracks whether global cheats are enabled
  @State private var cheatsEnabledGlobal: Bool = false
  /// Controls the alert asking to enable cheats
  @State private var showEnableCheatsPrompt: Bool = false
  /// Holds the cheat the user attempted to toggle before enabling cheats
  @State private var pendingCheat: CheatItem? = nil

  /// D18 (`docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`
  /// §4 "Cheats"): the SAME `MenuModel` for both platforms, rendered by
  /// `MenuScreen` — iOS and tvOS previously had two separate bodies (a plain
  /// touch-only `List` on iOS, a bespoke two-column layout on tvOS). Search
  /// stays a host concern (`.searchable` below, iOS-only), matching the
  /// design doc's Settings-root precedent; it is not part of the engine.
  /// Every cheat after the iOS text search (tvOS has none, so this is the full list).
  private var searchedCheats: [CheatItem] {
    createCombinedCheatList().filter { c in
      let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else { return true }
      return c.name.localizedCaseInsensitiveContains(q)
        || c.type.localizedCaseInsensitiveContains(q)
        || c.category.displayName.localizedCaseInsensitiveContains(q)
        || (c.creator?.localizedCaseInsensitiveContains(q) ?? false)
    }
  }

  private var cheatsMenuModel: MenuModel {
    let filtered = searchedCheats
    #if os(tvOS)
    let showsFilterRow = true
    #else
    let showsFilterRow = false
    #endif
    let state = CheatsMenuState(
      cheatsEnabledGlobal: cheatsEnabledGlobal, cheats: filtered, filter: filter,
      fetchStatus: fetchStatus, lastFetch: lastFetch, showsFilterRow: showsFilterRow)
    let actions = CheatsMenuActions(
      setEnabledGlobal: { newValue in
        DOLConfigBridge.setMainEnableCheats(newValue)
        cheatsEnabledGlobal = newValue
      },
      requestEnableGlobalCheats: { cheat in
        pendingCheat = cheat
        showEnableCheatsPrompt = true
      },
      toggleCheat: { cheat in toggleCheat(cheat) },
      downloadCheats: { downloadCheats() },
      refreshCheats: { loadCheats() },
      setFilter: { filter = $0 }
    )
    return CheatsMenuModelBuilder.make(state: state, actions: actions)
  }

  /// Shared by the alert's own "Turn On Cheats" button AND (iOS only)
  /// `MenuScreen`'s `modal:` hook below. Must flip `showEnableCheatsPrompt`
  /// itself: the alert path gets that for free from `isPresented`'s
  /// auto-reset, but the modal path calls this directly with no alert-button
  /// tap involved to reset anything.
  private func confirmEnableCheats() {
    DOLConfigBridge.setMainEnableCheats(true)
    cheatsEnabledGlobal = true
    if let cheat = pendingCheat {
      toggleCheat(cheat)
      pendingCheat = nil
    }
    showEnableCheatsPrompt = false
  }

  private func cancelEnableCheats() {
    pendingCheat = nil
    showEnableCheatsPrompt = false
  }

  var body: some View {
    #if os(iOS)
    NavigationStack {
      VStack(spacing: 0) {
        // Host chrome, like `.searchable` below: the chip row narrows the SAME
        // model the engine renders, so the builder stays platform-agnostic.
        CheatFilterChips(cheats: searchedCheats, selection: $filter)
        MenuScreen(
          model: cheatsMenuModel,
          style: .list,
          onBack: onBack,
          // D18 engine gap #2: without this, A/d-pad keep acting on the rows
          // behind this alert while it's up. See `MenuModal`'s doc comment.
          modal: showEnableCheatsPrompt
            ? MenuModal(onConfirm: confirmEnableCheats, onCancel: cancelEnableCheats)
            : nil
        )
      }
      .navigationTitle(L("Cheat Codes"))
      .searchable(text: $searchText)
      .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("Back")) { onBack() } } }
      .onAppear { appear() }
    }
    .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
      Button(L("Turn On Cheats")) { confirmEnableCheats() }
      Button(L("Cancel"), role: .cancel) { cancelEnableCheats() }
    } message: {
      Text(L("Cheats can affect performance and stability. Enable global cheats to apply this code?"))
    }
    #else
    ZStack {
      // Match parent background
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      LinearGradient(
        colors: [
          Color.black.opacity(0.85),
          Color.black.opacity(0.4),
          Color.black.opacity(0.85)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      // Match parent content structure
      HStack(spacing: 80) {
        // Left column — game cover + info, same as parent. Non-focusable
        // host chrome around `MenuScreen`: the design doc's §2 tvOS
        // contract bars a compound ROW, not a hero slot alongside the list
        // (the "keep the cover-image flavour" option this migration took).
        VStack(alignment: .leading, spacing: 16) {
          Image(uiImage: game.coverImage)
            .resizable()
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

          VStack(alignment: .leading, spacing: 6) {
            Text(game.title)
              .font(.system(size: 24, weight: .bold))
              .foregroundColor(.white)
              .lineLimit(2)

            Text(game.gameID)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(width: 180)

        // Right column — title + the SAME `MenuModel`/`MenuScreen` iOS
        // renders. This used to be a bespoke layout (Enable Cheats toggle,
        // search, Download/Refresh buttons and `CheatRowView` rows all
        // hand-laid with `@FocusState`, no `MenuFocusRouter` involvement);
        // now it is one `List` -- every `MenuItem` a single-control row per
        // §2's tvOS contract -- sharing its model, its Download-always-
        // visible fix, and its toggle behaviour with iOS instead of
        // drifting from it. The bespoke Back button is also gone: Menu
        // (`MenuScreen`'s own `.onExitCommand`) is back, matching every
        // other tvOS pane in the app. Search is dropped for tvOS -- no host
        // affordance replaces it, so `searchText` stays "" and every cheat
        // is always listed; a `TextField` sibling's on-screen-keyboard
        // detour isn't worth the focus-order risk on a 10-foot UI for a
        // filter this screen can live without.
        VStack(alignment: .leading, spacing: 20) {
          Text(L("Cheat Codes"))
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(.white)

          MenuScreen(model: cheatsMenuModel, style: .list, onBack: onBack)
            .frame(maxWidth: 860, maxHeight: 620)
        }
        .frame(maxWidth: 900, alignment: .leading)
      }
      .padding(.horizontal, 60)
    }
    .onAppear { appear() }
    .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
      Button(L("Turn On Cheats")) { confirmEnableCheats() }
      Button(L("Cancel"), role: .cancel) { cancelEnableCheats() }
    } message: {
      Text(L("Cheats can affect performance and stability. Enable global cheats to apply this code?"))
    }
    #endif
  }

  private func createCombinedCheatList() -> [CheatItem] {
    var allCheats: [CheatItem] = []
    for (index, code) in geckoCodeList.enumerated() {
      allCheats.append(CheatItem(
        id: "gecko_\(index)", name: code.name, type: "Gecko Code", enabled: code.enabled, isGecko: true, index: index,
        creator: code.creator.isEmpty ? nil : code.creator,
        notes: code.notes.isEmpty ? nil : code.notes,
        isBuiltIn: !code.userDefined,
        lineCount: code.lineCount))
    }
    for (index, code) in actionReplayCodeList.enumerated() {
      allCheats.append(CheatItem(
        id: "ar_\(index)", name: code.name, type: "Action Replay", enabled: code.enabled, isGecko: false, index: index,
        isBuiltIn: !code.userDefined,
        lineCount: code.lineCount))
    }
    return allCheats
  }

  private func appear() {
    cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
    loadCheats()
    autoFetchIfNeeded()
  }

  /// On-demand download, the way iFly and Provenance load a game's cheats when
  /// the pane opens: once per game per launch, and only when the last fetch is
  /// missing or stale (`CheatAutoFetchPolicy`). The manual Download row stays
  /// as the retry/refresh.
  private func autoFetchIfNeeded() {
    let gametdbId = game.gametdbID
    if gametdbId.isEmpty {
      fetchStatus = .unavailable
      return
    }
    lastFetch = CheatFetchLedger.shared.lastFetch(for: gametdbId)
    guard CheatFetchLedger.shared.shouldAutoFetch(gametdbId: gametdbId) else { return }
    downloadCheats()
  }

  private func downloadCheats() {
    let gametdbId = game.gametdbID
    guard !gametdbId.isEmpty, fetchStatus != .fetching else { return }
    CheatFetchLedger.shared.markAttempted(gametdbId)
    fetchStatus = .fetching
    TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: gametdbId) { success, downloaded, added in
      DispatchQueue.main.async {
        if success {
          CheatFetchLedger.shared.recordFetch(for: gametdbId)
          lastFetch = CheatFetchLedger.shared.lastFetch(for: gametdbId)
          fetchStatus = .fetched(downloaded: downloaded, added: added)
        } else {
          fetchStatus = .failed
        }
        loadCheats()
      }
    }
  }

  private func toggleCheat(_ cheat: CheatItem) {
    if cheat.isGecko {
      TVCheatsBridge.setGeckoCodeEnabled(!cheat.enabled, at: cheat.index, forGameId: game.gameID, revision: game.revision)
    } else {
      TVCheatsBridge.setActionReplayCodeEnabled(!cheat.enabled, at: cheat.index, forGameId: game.gameID, revision: game.revision)
    }
    loadCheats()
  }

  private func loadCheats() {
    geckoCodeList = TVCheatsBridge.geckoCodes(forGameId: game.gameID, revision: game.revision)
    actionReplayCodeList = TVCheatsBridge.actionReplayCodes(forGameId: game.gameID, revision: game.revision)
  }

  /// D15: cheap count of currently-enabled Gecko + Action Replay codes for a game,
  /// for the pause menu's "N active" subtitle on the Cheats item. Reads the same
  /// per-game ini via `TVCheatsBridge` that `loadCheats()` above uses — no core
  /// involvement, no extra state machine, safe to call every time the pause menu
  /// appears or the user backs out of the Cheats pane.
  static func activeCheatCount(forGameId gameId: String, revision: Int) -> Int {
    let geckoActive = TVCheatsBridge.geckoCodes(forGameId: gameId, revision: revision).filter(\.enabled).count
    let arActive = TVCheatsBridge.actionReplayCodes(forGameId: gameId, revision: revision).filter(\.enabled).count
    return geckoActive + arActive
  }
}
