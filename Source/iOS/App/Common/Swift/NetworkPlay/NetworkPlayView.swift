// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Every library game is offered. Hosting and joining wait for an iCube session adapter around Dolphin's
/// NetPlay; until then this screen says so and simulates no network operation.
struct NetworkPlayRequest: Identifiable {
  let id = UUID()
  let game: TVGameItem?
}

struct NetworkPlayView: View {
  let items: [TVGameItem]
  var initialGame: TVGameItem? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var libraryGames: [NetworkPlayLibrary.Game] = []
  @State private var filter: NetworkPlayLibrary.Filter = .all
  @State private var search = ""
  @State private var tab: Tab = .games
  @State private var selected: TVGameItem?
  private enum Tab: String, CaseIterable {
    case games, rooms, settings

    var title: String {
      switch self {
      case .games: L("Your Games")
      case .rooms: L("Nearby Rooms")
      case .settings: L("Settings")
      }
    }
  }
  private enum FocusTarget: Hashable { case tab(Tab), search }
  @FocusState private var focus: FocusTarget?

  private var visibleGames: [NetworkPlayLibrary.Game] {
    NetworkPlayLibrary.games(libraryGames, filter: filter, search: search)
  }

  var body: some View {
    ZStack {
      Color(uiColor: ICubeDesign.roomStops[0]).ignoresSafeArea()
      ICubeRoom(style: .gradient)
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
            header
            if let selected {
              detail(selected, wide: geometry.size.width > ICubeDesign.NetworkPlay.splitWidth)
            } else {
              tabStrip
              switch tab {
              case .games: gamesContent
              case .rooms: roomsContent
              case .settings: settingsContent
              }
            }
          }
          .padding(ICubeDesign.Spacing.l.rawValue)
          .frame(maxWidth: ICubeDesign.NetworkPlay.contentWidth, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
      }
    }
    .foregroundStyle(ICubeDesign.color(.textPrimary))
    .onAppear {
      selected = initialGame
      libraryGames = items.map(NetworkPlayLibrary.Game.init)
      #if os(tvOS)
      focus = .tab(tab)
      #endif
    }
    .onChange(of: items.map(\.filePath)) { _, _ in
      libraryGames = items.map(NetworkPlayLibrary.Game.init)
    }
    #if os(tvOS)
    .onExitCommand {
      if focus == .search { focus = .tab(tab) } else { back() }
    }
    #endif
  }

  private func back() {
    if selected != nil {
      selected = nil
      #if os(tvOS)
      focus = .tab(tab)
      #endif
    } else {
      dismiss()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      #if !os(tvOS)
      // On Apple TV the remote's Back button does this.
      Button(action: back) {
        Label(selected != nil ? L("Back") : L("Library"), systemImage: "chevron.left")
          .icubeText(.body)
          .padding(ICubeDesign.Spacing.s.rawValue)
      }
      .buttonStyle(ICubeRowButtonStyle())
      .fixedSize()
      .accessibilityIdentifier("networkPlay.back")
      #endif
      ICubeLeafHeader(title: L("Network Play"), subtitle: selected == nil ? "iCube" : L("Network Play"))
    }
  }

  private var tabStrip: some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      ForEach(Tab.allCases, id: \.self) { value in
        chip(value.title, selected: tab == value) { tab = value }
          .focused($focus, equals: .tab(value))
          .accessibilityIdentifier("networkPlay.tab.\(value.rawValue)")
      }
    }
    #if os(tvOS)
    .focusSection()
    #endif
  }

  private var gamesContent: some View {
    let games = visibleGames
    let itemsByPath = Dictionary(items.map { ($0.filePath, $0) }, uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      notice(L("Network Play is not available in this iCube build."),
             detail: L("This version cannot host, join or discover rooms yet. Every game in your library is listed here."),
             icon: "network.slash")
      NetworkPlaySearchField(text: $search)
        .focused($focus, equals: .search)
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        ForEach(NetworkPlayLibrary.Filter.allCases, id: \.self) { value in
          chip(value.title, selected: filter == value) { filter = value }
            .accessibilityIdentifier("networkPlay.filter.\(value.rawValue)")
        }
      }
      #if os(tvOS)
      .focusSection()
      #endif
      if games.isEmpty {
        notice(libraryGames.isEmpty ? L("No games in your library yet") : L("No matching games"),
               detail: libraryGames.isEmpty ? L("Add games to your library to see them here.")
                 : L("Try another search, or choose All Games."),
               icon: "gamecontroller")
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ICubeDesign.NetworkPlay.cardWidth),
                                     spacing: ICubeDesign.Spacing.l.rawValue)],
                  spacing: ICubeDesign.Spacing.l.rawValue) {
          ForEach(games) { game in
            if let item = itemsByPath[game.id] {
              gameCard(item, game: game)
            }
          }
        }
        #if os(tvOS)
        .focusSection()
        #endif
      }
    }
  }

  private func gameCard(_ item: TVGameItem, game: NetworkPlayLibrary.Game) -> some View {
    Button {
      focus = nil
      selected = item
    } label: {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        Image(uiImage: item.coverImage)
          .resizable().scaledToFit()
          .frame(maxWidth: .infinity)
          .frame(height: ICubeDesign.NetworkPlay.coverHeight)
          .accessibilityHidden(true)
        Text(item.title).icubeText(.body).lineLimit(2)
        Text(game.system).icubeText(.tag)
        if let label = game.hint.label {
          Label(label, systemImage: game.hint.symbol).icubeText(.detail)
        }
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .icubeCardSurface()
    }
    .buttonStyle(ICubeCardButtonStyle())
    .accessibilityIdentifier("networkPlay.game")
  }

  private var roomsContent: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      notice(L("Room discovery unavailable"),
             detail: L("This build cannot search for or join rooms. An empty list here does not mean there are no hosts on your network."), icon: "wifi.slash")
      Label(L("Join unavailable"), systemImage: "lock.fill")
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var settingsContent: some View {
    notice(L("Connection settings unavailable"),
           detail: L("Player limits, spectators, relay and timing are unavailable because this version cannot connect to Network Play."), icon: "network.slash")
  }

  @ViewBuilder private func detail(_ item: TVGameItem, wide: Bool) -> some View {
    if wide {
      HStack(alignment: .top, spacing: ICubeDesign.Spacing.xl.rawValue) {
        artwork(item).frame(maxWidth: ICubeDesign.NetworkPlay.heroWidth)
        gameDetails(item)
      }
    } else {
      artwork(item)
      gameDetails(item)
    }
  }

  private func artwork(_ item: TVGameItem) -> some View {
    Image(uiImage: item.coverImage).resizable().scaledToFit()
      .frame(maxWidth: .infinity)
      .frame(height: ICubeDesign.NetworkPlay.heroHeight)
      .accessibilityHidden(true)
  }

  private func gameDetails(_ item: TVGameItem) -> some View {
    let game = NetworkPlayLibrary.Game(item: item)
    return VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
      Text(item.title).icubeText(.title)
      Text(game.system).icubeText(.tag)
      if let label = game.hint.label {
        Label(label, systemImage: game.hint.symbol).icubeText(.body)
      }
      notice(L("Host unavailable"), detail: L("Network Play is not available in this iCube build."), icon: "network.slash")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func notice(_ title: String, detail: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
      Label(title, systemImage: icon).icubeText(.body).fontWeight(.semibold)
      Text(detail).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .padding(ICubeDesign.Spacing.m.rawValue)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ICubeDesign.Card.surface, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue))
  }

  /// A tab or filter choice: the standard row, as wide as its label.
  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).icubeText(.body).fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(ICubeRowButtonStyle(isSelected: selected))
    .fixedSize()
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The games search field. On Apple TV the system field draws its own white focus plate, so the field is drawn
/// plain inside the standard row surface and focus ring.
private struct NetworkPlaySearchField: View {
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image(systemName: "magnifyingglass").foregroundStyle(ICubeDesign.color(.textSecondary))
      TextField(L("Search games or systems"), text: $text,
                prompt: Text(L("Search games or systems")).foregroundStyle(ICubeDesign.color(.textSecondary)))
        .textFieldStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityIdentifier("networkPlay.search")
    }
    .icubeText(.body)
    .padding(ICubeDesign.Spacing.s.rawValue)
    .background(shape.fill(ICubeDesign.color(focused ? .selectedFill : .rowSurface)))
    .overlay(shape.stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue))
    .overlay(shape.stroke(ICubeDesign.focusGradient, lineWidth: Self.ringWidth(focused)))
    .animation(ICubeDesign.Motion.focusSpring, value: focused)
  }

  /// The focus ring is an Apple TV affordance; a touch keyboard already shows where typing goes.
  private static func ringWidth(_ focused: Bool) -> CGFloat {
    #if os(tvOS)
    focused ? ICubeDesign.Line.focus.rawValue : 0
    #else
    0
    #endif
  }
}

private extension NetworkPlayLibrary.Filter {
  var title: String {
    switch self {
    case .all: L("All Games")
    case .recent: L("Recent")
    case .favorites: L("Favorites")
    }
  }
}

private extension NetworkPlayLibrary.Hint {
  /// Nothing is drawn for a game nobody has reported on.
  var label: String? {
    switch self {
    case .unknown: nil
    case .works: L("Reported working")
    case .reportedBroken: L("Reported broken")
    }
  }

  var symbol: String {
    switch self {
    case .unknown: "questionmark.circle"
    case .works: "checkmark.circle"
    case .reportedBroken: "exclamationmark.triangle"
    }
  }
}

extension NetworkPlayLibrary.Game {
  init(item: TVGameItem) {
    id = item.filePath
    title = item.title
    switch item.platform {
    case 0: system = "GameCube"
    case 2, 3: system = "Wii"
    default: system = L("Unknown")
    }
    favorite = item.isFavorite
    lastPlayed = LastPlayedStore.lastPlayed(gameID: item.gameID)
    hint = NetworkPlayLibrary.hint(forGameID: item.gameID)
  }
}
