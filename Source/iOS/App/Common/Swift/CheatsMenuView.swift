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
  private var cheatsMenuModel: MenuModel {
    let filtered = createCombinedCheatList().filter { c in
      let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else { return true }
      return c.name.localizedCaseInsensitiveContains(q) || c.type.localizedCaseInsensitiveContains(q)
    }
    let state = CheatsMenuState(cheatsEnabledGlobal: cheatsEnabledGlobal, cheats: filtered)
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
      downloadCheats: {
        TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: game.gametdbID) { _, _, _ in
          DispatchQueue.main.async { loadCheats() }
        }
      },
      refreshCheats: { loadCheats() }
    )
    #if os(tvOS)
    return CheatsMenuModelBuilder.make(state: state, actions: actions, typeAsBadge: true)
    #else
    return CheatsMenuModelBuilder.make(state: state, actions: actions)
    #endif
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
      .navigationTitle(L("Cheat Codes"))
      .searchable(text: $searchText)
      .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("Back")) { onBack() } } }
      .onAppear { cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
        loadCheats()
      }
    }
    .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
      Button(L("Turn On Cheats")) { confirmEnableCheats() }
      Button(L("Cancel"), role: .cancel) { cancelEnableCheats() }
    } message: {
      Text(L("Cheats can affect performance and stability. Enable global cheats to apply this code?"))
    }
    #else
    ZStack {
      // Blurred cover backdrop; the material keeps the list legible with no hard-coded scrim colour.
      Image(uiImage: game.coverImage)
        .resizable()
        .scaledToFill()
        .blur(radius: 25)
        .opacity(0.8)
        .ignoresSafeArea()

      Rectangle()
        .fill(.ultraThinMaterial)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        // Search stays an inline field above the list (the engine has no search of its own).
        TextField(L("Search"), text: $searchText)
          .icubeText(.body)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
          .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
          .background(
            RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
              .fill(ICubeDesign.color(.rowSurface))
          )
          .padding(.horizontal, ICubeDesign.Spacing.xl.rawValue)

        MenuScreen(
          model: cheatsMenuModel,
          style: .list,
          onBack: onBack,
          tvHeader: ICubeLeafHeader(title: L("Cheats"), subtitle: game.title),
          tvInset: .xl
        )
      }
    }
    .onAppear { cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
      loadCheats()
    }
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
      allCheats.append(CheatItem(id: "gecko_\(index)", name: code.name, type: "Gecko Code", enabled: code.enabled, isGecko: true, index: index))
    }
    for (index, code) in actionReplayCodeList.enumerated() {
      allCheats.append(CheatItem(id: "ar_\(index)", name: code.name, type: "Action Replay", enabled: code.enabled, isGecko: false, index: index))
    }
    return allCheats
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

struct CheatItem {
  let id: String
  let name: String
  let type: String
  let enabled: Bool
  let isGecko: Bool
  let index: Int
}

// MARK: - D18 model (shared by iOS and tvOS — see `CheatsMenuView.cheatsMenuModel`)

/// Plain snapshot — no `TVCheatsBridge` reads inside `CheatsMenuModelBuilder`,
/// so it is constructible from a test with a synthetic cheat list.
struct CheatsMenuState {
  var cheatsEnabledGlobal: Bool
  var cheats: [CheatItem]
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
}

enum CheatsMenuModelBuilder {
  /// `typeAsBadge`: tvOS shows the Gecko/Action Replay type as the row's trailing badge instead of a subtitle.
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
    sections.append(MenuSection(id: "actions", items: [
      MenuItem(id: "download-cheats", title: L("Download Cheats"), icon: "arrow.down.circle", role: .action(actions.downloadCheats)),
      MenuItem(id: "refresh-cheats", title: L("Refresh List"), role: .action(actions.refreshCheats)),
    ]))

    if state.cheats.isEmpty {
      sections.append(MenuSection(id: "empty", items: [
        MenuItem(id: "empty-state", title: L("No Cheats Available"), role: .custom(emptyStateView), isEnabled: false),
      ]))
    } else {
      sections.append(MenuSection(id: "cheats", header: L("Cheat Codes"), items: state.cheats.map { cheat in
        MenuItem(
          id: "cheat-\(cheat.id)",
          title: cheat.name,
          subtitle: typeAsBadge ? nil : cheat.type,
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
          badge: typeAsBadge ? cheat.type : nil
        )
      }))
    }
    return MenuModel(sections: sections)
  }

  private static var emptyStateView: AnyView {
    AnyView(
      VStack(spacing: 12) {
        Image(systemName: "gamecontroller").font(.title)
          .foregroundColor(.secondary)
        Text(L("No Cheats Available")).font(.headline)
        Text(L("Download cheats to get started")).font(.subheadline).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
    )
  }
}
