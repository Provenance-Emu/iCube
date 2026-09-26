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
  @FocusState private var focused: FocusField?

  enum FocusField: Hashable {
    case back
    case downloadCheats
    case refreshCheats
    case cheat(String)
  }

  /// Tracks whether global cheats are enabled
  @State private var cheatsEnabledGlobal: Bool = false
  /// Controls the alert asking to enable cheats
  @State private var showEnableCheatsPrompt: Bool = false
  /// Holds the cheat the user attempted to toggle before enabling cheats
  @State private var pendingCheat: CheatItem? = nil

  /// D18 proof-of-life (`docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`
  /// §4 "Cheats"): the iOS list as a `MenuModel`, rendered by `MenuScreen` —
  /// this is the part of the screen that previously had zero controller
  /// navigation (plain `List`, touch-only). Search stays a host concern
  /// (`.searchable` below), matching the design doc's Settings-root
  /// precedent; it is not part of the engine.
  private var cheatsMenuModel: MenuModel {
    let filtered = createCombinedCheatList().filter { c in
      let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else { return true }
      return c.name.localizedCaseInsensitiveContains(q) || c.type.localizedCaseInsensitiveContains(q)
    }
    let state = CheatsMenuState(
      cheatsEnabledGlobal: cheatsEnabledGlobal,
      cheats: filtered,
      // Quirk preserved verbatim from the pre-D18 body: this is the
      // UNFILTERED emptiness (not `filtered.isEmpty`), so Download/Refresh
      // stay hidden while a search happens to match nothing even though
      // cheats exist. Looks like a bug; not this pass's job to fix it.
      hasAnyCheats: !(geckoCodeList.isEmpty && actionReplayCodeList.isEmpty)
    )
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
    return CheatsMenuModelBuilder.make(state: state, actions: actions)
  }

  var body: some View {
    #if os(iOS)
    NavigationStack {
      MenuScreen(model: cheatsMenuModel, style: .list, onBack: onBack)
        .navigationTitle(L("Cheat Codes"))
        .searchable(text: $searchText)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("Back")) { onBack() } } }
        .onAppear { cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
          loadCheats()
        }
    }
    .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
      Button(L("Turn On Cheats")) {
        DOLConfigBridge.setMainEnableCheats(true)
        cheatsEnabledGlobal = true
        if let c = pendingCheat { toggleCheat(c)
          pendingCheat = nil
        }
      }
      Button(L("Cancel"), role: .cancel) { pendingCheat = nil }
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
        // Left column — game cover + info, same as parent
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

        // Right column — cheats UI
        VStack(alignment: .leading, spacing: 24) {
          // Back button + title
          HStack(alignment: .center, spacing: 20) {
            Button(action: onBack) {
              HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                  .font(.system(size: 18, weight: .medium))
                Text(L("Back"))
                  .font(.system(size: 18, weight: .medium))
              }
              .foregroundColor(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 12)
              .background(.white.opacity(0.15))
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .back)

            Text(L("Cheat Codes"))
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.white)
          }

          // Global Cheats toggle
          HStack(spacing: 12) {
            Text(L("Enable Cheats")).foregroundColor(.white)
            Spacer()
            Toggle("", isOn: Binding(get: { cheatsEnabledGlobal }, set: { newValue in
              DOLConfigBridge.setMainEnableCheats(newValue)
              cheatsEnabledGlobal = newValue
            }))
            .labelsHidden()
          }

          // Search & actions
          HStack(spacing: 24) {
            // Search field (tvOS-friendly)
            HStack(spacing: 10) {
              Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.7))
              TextField(L("Search cheats"), text: $searchText)
                .textCase(.none)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .foregroundColor(.white)
                .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 360)

            Button(action: {
              TVCheatsBridge.downloadGeckoCodes(forGameId: game.gameID, revision: game.revision, gametdbId: game.gametdbID) { _, _, _ in
                DispatchQueue.main.async { loadCheats() }
              }
            }) {
              HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                  .font(.system(size: 22))
                  .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                  Text(L("Download Cheats"))
                    .font(.system(size: 16, weight: .semibold))
                  Text(L("Get latest codes"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white)
              }
              .padding(.horizontal, 20)
              .padding(.vertical, 14)
              .background(.white.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .downloadCheats)

            Button(action: { loadCheats() }) {
              HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                  .font(.system(size: 22))
                  .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                  Text(L("Refresh List"))
                    .font(.system(size: 16, weight: .semibold))
                  Text(L("Reload codes"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white)
              }
              .padding(.horizontal, 20)
              .padding(.vertical, 14)
              .background(.white.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .refreshCheats)
          }

          // Combined cheats list — clamped size like a page panel
          ScrollView {
            LazyVStack(spacing: 14) {
              let allCheats = createCombinedCheatList().filter { searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? true : $0.name.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText) }
              if allCheats.isEmpty {
                VStack(spacing: 16) {
                  Image(systemName: "gamecontroller")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.5))
                  Text(L("No Cheats Available"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                  Text(L("Download cheats to get started"))
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(30)
              } else {
                ForEach(allCheats, id: \.id) { cheat in
                  CheatRowView(
                    cheat: cheat,
                    isFocused: focused == .cheat(cheat.id),
                    onToggle: {
                      if !cheatsEnabledGlobal {
                        pendingCheat = cheat
                        showEnableCheatsPrompt = true
                      } else {
                        toggleCheat(cheat)
                      }
                    }
                  )
                  .focused($focused, equals: .cheat(cheat.id))
                }
              }
            }
            .padding(.trailing, 10)
          }
          .frame(maxWidth: 820, maxHeight: 520) // clamp like a panel
        }
        .frame(maxWidth: 900, alignment: .leading) // clamp right column width
      }
      .padding(.horizontal, 60)
    }
    #if os(tvOS)
    .onExitCommand { onBack() }
    .focusSection()
    #endif
    .defaultFocus($focused, .back)
    .onAppear { cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
      loadCheats()
    }
    .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
      Button(L("Turn On Cheats")) {
        DOLConfigBridge.setMainEnableCheats(true)
        cheatsEnabledGlobal = true
        if let c = pendingCheat { toggleCheat(c)
          pendingCheat = nil
        }
      }
      Button(L("Cancel"), role: .cancel) { pendingCheat = nil }
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

// MARK: - D18 model (iOS list only — see `CheatsMenuView.cheatsMenuModel`)

/// Plain snapshot — no `TVCheatsBridge` reads inside `CheatsMenuModelBuilder`,
/// so it is constructible from a test with a synthetic cheat list.
struct CheatsMenuState {
  var cheatsEnabledGlobal: Bool
  var cheats: [CheatItem]
  var hasAnyCheats: Bool
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
  static func make(state: CheatsMenuState, actions: CheatsMenuActions) -> MenuModel {
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

    if state.hasAnyCheats {
      sections.append(MenuSection(id: "actions", items: [
        MenuItem(id: "download-cheats", title: L("Download Cheats"), icon: "arrow.down.circle", role: .action(actions.downloadCheats)),
        MenuItem(id: "refresh-cheats", title: L("Refresh List"), role: .action(actions.refreshCheats)),
      ]))
    }

    if state.cheats.isEmpty {
      sections.append(MenuSection(id: "empty", items: [
        MenuItem(id: "empty-state", title: L("No Cheats Available"), role: .custom(emptyStateView), isEnabled: false),
      ]))
    } else {
      sections.append(MenuSection(id: "cheats", header: L("Cheat Codes"), items: state.cheats.map { cheat in
        MenuItem(
          id: "cheat-\(cheat.id)",
          title: cheat.name,
          subtitle: cheat.type,
          role: .toggle(Binding(
            get: { cheat.enabled },
            set: { newValue in
              if newValue, !state.cheatsEnabledGlobal {
                actions.requestEnableGlobalCheats(cheat)
              } else {
                actions.toggleCheat(cheat)
              }
            }
          ))
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

struct CheatRowView: View {
  let cheat: CheatItem
  let isFocused: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 20) {
        Image(systemName: cheat.enabled ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundColor(cheat.enabled ? .green : .white.opacity(0.5))
        VStack(alignment: .leading, spacing: 4) {
          Text(cheat.name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
          Text(cheat.type)
            .font(.system(size: 13))
            .foregroundColor(cheat.isGecko ? .blue.opacity(0.8) : .orange.opacity(0.8))
        }
        Spacer()
        Text(cheat.enabled ? L("Enabled") : L("Disabled"))
          .font(.system(size: 15, weight: .medium))
          .foregroundColor(cheat.enabled ? .green : .white.opacity(0.6))
      }
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.white.opacity(isFocused ? 0.15 : 0.08))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(.white.opacity(isFocused ? 0.35 : 0.1), lineWidth: isFocused ? 2 : 1)
          )
      )
      .zIndex(isFocused ? 10 : 0)
    }
    .buttonStyle(.plain)
    .scaleEffect(isFocused ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.2), value: isFocused)
  }
}
