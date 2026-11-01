// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Design-only surface until an iCube app session adapter exists. No network operation is simulated here.
struct NetworkPlayRequest: Identifiable {
  let id = UUID()
  let game: TVGameItem?
}

struct NetworkPlayView: View {
  let items: [TVGameItem]
  var initialGame: TVGameItem? = nil
  @Environment(\.dismiss) private var dismiss
  @AppStorage("network_play_show_unverified_v1") private var showUnverified = false
  @State private var libraryGames: [NetworkPlayLibrary.Game] = []
  @State private var filter: NetworkPlayLibrary.Filter = .suggested
  @State private var search = ""
  @State private var roomsTab = false
  @State private var settings = false
  @State private var selected: TVGameItem?
  private enum FocusTarget: Hashable { case back, settings, search, unverified }
  @FocusState private var focus: FocusTarget?

  private var visibleGames: [NetworkPlayLibrary.Game] {
    NetworkPlayLibrary.games(libraryGames, filter: filter,
                             showUnverified: showUnverified, search: search)
  }

  var body: some View {
    ZStack {
      Color(uiColor: ICubeDesign.roomStops[0]).ignoresSafeArea()
      ICubeRoom(style: .gradient)
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
            header
            if settings {
              settingsContent
            } else if let selected {
              detail(selected, wide: geometry.size.width > ICubeDesign.NetworkPlay.splitWidth)
            } else {
              hub(wide: geometry.size.width > ICubeDesign.NetworkPlay.splitWidth)
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
      #if os(tvOS)
      focus = .back
      #endif
      libraryGames = items.map(NetworkPlayLibrary.Game.init)
    }
    .onChange(of: items.map(\.filePath)) { _, _ in
      libraryGames = items.map(NetworkPlayLibrary.Game.init)
    }
    .onChange(of: settings) { _, _ in
      #if os(tvOS)
      focus = .back
      #endif
    }
    .onChange(of: showUnverified) { _, enabled in
      if !enabled, filter == .unverified { filter = .suggested }
    }
    #if os(tvOS)
    .onExitCommand {
      if focus == .search { focus = .back } else { back() }
    }
    #endif
  }

  private func back() {
    if settings { settings = false }
    else if selected != nil { selected = nil }
    else { dismiss() }
    #if os(tvOS)
    focus = .back
    #endif
  }

  #if os(tvOS)
  private func moveDownFromHeader(_ direction: MoveCommandDirection) {
    guard direction == .down else { return }
    if settings { focus = .unverified }
    else if selected == nil { focus = .search }
  }
  #endif

  private var header: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      HStack {
        Button(action: back) {
          Label(settings || selected != nil ? L("Back") : L("Library"), systemImage: "chevron.left")
            .icubeText(.body)
            .padding(ICubeDesign.Spacing.s.rawValue)
        }
        .buttonStyle(ICubeRowButtonStyle())
        .accessibilityIdentifier("networkPlay.back")
        .focused($focus, equals: .back)
        #if os(tvOS)
        .onMoveCommand(perform: moveDownFromHeader)
        #endif
        Spacer()
        if !settings {
          Button { settings = true } label: {
            Label(L("Settings"), systemImage: "gearshape")
              .icubeText(.body)
              .padding(ICubeDesign.Spacing.s.rawValue)
          }
          .buttonStyle(ICubeRowButtonStyle())
          .accessibilityIdentifier("networkPlay.settings")
          .focused($focus, equals: .settings)
          #if os(tvOS)
          .onMoveCommand(perform: moveDownFromHeader)
          #endif
        }
      }
      ICubeLeafHeader(title: settings ? L("Network Play Settings") : L("Network Play"), subtitle: "iCube")
    }
  }

  @ViewBuilder private func hub(wide: Bool) -> some View {
    notice(L("Network Play is not available in this iCube build."),
           detail: L("This version cannot host, join or discover rooms. You can still review your games."),
           icon: "network.slash")
    if wide {
      HStack(alignment: .top, spacing: ICubeDesign.Spacing.xl.rawValue) {
        gamesContent.frame(maxWidth: .infinity, alignment: .topLeading)
        roomsContent.frame(maxWidth: .infinity, alignment: .topLeading)
      }
      #if os(tvOS)
      .focusSection()
      #endif
    } else {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        tab(L("Your Games"), selected: !roomsTab) { roomsTab = false }
        tab(L("Nearby Rooms"), selected: roomsTab) { roomsTab = true }
      }
      if roomsTab { roomsContent } else { gamesContent }
    }
  }

  private var gamesContent: some View {
    let games = visibleGames
    let itemsByPath = Dictionary(items.map { ($0.filePath, $0) }, uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
      ICubeAccentHeader(text: L("Your Games"))
      Text(L("Choose a game to review its multiplayer details."))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
      TextField(L("Search games or systems"), text: $search,
                prompt: Text(L("Search games or systems")).foregroundStyle(ICubeDesign.color(.textSecondary)))
        .icubeText(.body)
        .focused($focus, equals: .search)
        .padding(ICubeDesign.Spacing.s.rawValue)
        .background(ICubeDesign.Card.surface, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
        .accessibilityIdentifier("networkPlay.search")
        #if os(tvOS)
        .onMoveCommand { direction in
          if direction == .up { focus = .back }
        }
        #endif
      ScrollView(.horizontal) {
        HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
          ForEach(NetworkPlayLibrary.Filter.allCases.filter { showUnverified || $0 != .unverified }, id: \.self) { value in
            tab(value.title, selected: filter == value) { filter = value }
          }
        }
        .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
        .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
      }
      .scrollClipDisabled()
      if games.isEmpty {
        notice(search.isEmpty ? L("No games to recommend yet") : L("No matching games"),
               detail: L("Recommendations require documented multiplayer and a working Network Play connection. Unknown games stay in the opt-in Unverified list."),
               icon: "gamecontroller")
        if !showUnverified {
          Button { settings = true } label: {
            Label(L("Review unverified browsing"), systemImage: "slider.horizontal.3")
              .icubeText(.body)
              .padding(ICubeDesign.Spacing.m.rawValue)
              .frame(maxWidth: .infinity, alignment: .leading)
              .icubeCardSurface()
          }
          .buttonStyle(ICubeCardButtonStyle())
        }
      } else {
        Text(L("Unverified means multiplayer and netplay have not been established for this dump."))
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ICubeDesign.NetworkPlay.cardWidth))], spacing: ICubeDesign.Spacing.l.rawValue) {
          ForEach(games) { game in
            if let item = itemsByPath[game.id] {
              gameCard(item)
            }
          }
        }
      }
    }
    #if os(tvOS)
    .focusSection()
    #endif
  }

  private func gameCard(_ item: TVGameItem) -> some View {
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
        Text(NetworkPlayLibrary.Game(item: item).system).icubeText(.tag)
        Label(L("Unverified"), systemImage: "questionmark.circle").icubeText(.detail)
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
      ICubeAccentHeader(text: L("Nearby Rooms"))
      notice(L("Room discovery unavailable"),
             detail: L("This build cannot search for or join rooms. An empty list here does not mean there are no hosts on your network."), icon: "wifi.slash")
      Label(L("Join unavailable"), systemImage: "lock.fill")
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    #if os(tvOS)
    .focusSection()
    #endif
  }

  private var settingsContent: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
      ICubeAccentHeader(text: L("Suggestions"))
      unverifiedControl
      Text(L("Unverified games never appear in Suggested, All Supported, Recent or Favorites. Browsing them does not enable hosting."))
        .icubeText(.detail)
      notice(L("How recommendations work"),
             detail: L("Compatible open rooms rank first, then favorites and recent play. Recommendations require documented game modes and a working Network Play connection."), icon: "line.3.horizontal.decrease")
      notice(L("Connection settings unavailable"),
             detail: L("Player limits, spectators, relay and timing are unavailable because this version cannot connect to Network Play."), icon: "network.slash")
    }
  }

  @ViewBuilder private var unverifiedControl: some View {
    #if os(tvOS)
    // A stock Toggle outside a Form/List is not a directional focus target on tvOS.
    Button { showUnverified.toggle() } label: {
      HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
        Label(L("Show unverified games"), systemImage: showUnverified ? "checkmark.square.fill" : "square")
        Spacer()
        Text(showUnverified ? L("On") : L("Off"))
      }
      .icubeText(.body)
      .padding(ICubeDesign.Spacing.m.rawValue)
      .icubeCardSurface()
    }
    .buttonStyle(ICubeCardButtonStyle())
    .focused($focus, equals: .unverified)
    .onMoveCommand { direction in
      if direction == .up { focus = .back }
    }
    .accessibilityValue(showUnverified ? L("On") : L("Off"))
    .accessibilityIdentifier("networkPlay.unverifiedToggle")
    #else
    Toggle(L("Show unverified games"), isOn: $showUnverified)
      .icubeText(.body)
      .accessibilityIdentifier("networkPlay.unverifiedToggle")
      .padding(ICubeDesign.Spacing.m.rawValue)
      .background(ICubeDesign.Card.surface, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue))
    #endif
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
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
      Text(item.title).icubeText(.title)
      Text(NetworkPlayLibrary.Game(item: item).system).icubeText(.tag)
      notice(L("Documented multiplayer"),
             detail: L("Unknown for this dump. A game title, disc ID or cover does not verify multiplayer modes or identify a patched game."), icon: "book")
      notice(L("Connection availability"), detail: L("Network Play is not available in this iCube build."), icon: "network.slash")
      notice(L("Test evidence"),
             detail: L("No netplay test evidence is recorded for this game, core version, app build and platform."), icon: "checklist")
      Label(L("Host unavailable"), systemImage: "lock.fill").icubeText(.body)
      Text(L("Hosting requires a working Network Play connection in iCube."))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
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

  private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).icubeText(.body).fixedSize(horizontal: true, vertical: false)
        .padding(ICubeDesign.Spacing.s.rawValue)
    }
    .buttonStyle(ICubeRowButtonStyle(isSelected: selected))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private extension NetworkPlayLibrary.Filter {
  var title: String {
    switch self {
    case .suggested: L("Suggested")
    case .supported: L("All Supported")
    case .recent: L("Recent")
    case .favorites: L("Favorites")
    case .unverified: L("Unverified")
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
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: item.filePath, isDirectory: &isDirectory)
    local = !item.isDemoItem && exists && !isDirectory.boolValue && [0, 2, 3].contains(item.platform)
    favorite = item.isFavorite
    lastPlayed = LastPlayedStore.lastPlayed(gameID: item.gameID)
    // There is no trusted per-dump multiplayer store in iCube. A disc ID alone cannot
    // establish whether a dump is patched. Do not borrow catalog facts using title or prefix matches.
    documentation = nil
  }
}
