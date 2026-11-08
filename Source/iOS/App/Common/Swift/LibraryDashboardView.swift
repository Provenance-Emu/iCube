// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

#if !os(tvOS)
/// The top of the iPad library, after iFly's dashboard: Continue Playing beside the status tiles and the
/// nearby devices, then Recent Saves and Recently Played, with the library's own grid below. Everything is
/// scoped to the games on screen, so a platform filter narrows the dashboard along with the grid.
///
/// Owns its save index, so a scan finishing re-renders this view rather than the whole library.
struct LibraryDashboardView<RecentCard: View>: View {
  /// What the library is doing, for the Activity tile.
  struct Activity: Equatable {
    var isScanning = false
    var cachingCount = 0

    var isBusy: Bool { isScanning || cachingCount > 0 }
  }

  /// The library as the platform filter leaves it.
  let games: [TVGameItem]
  /// Side by side when true; stacked in portrait and at the accessibility text sizes either way.
  let isWide: Bool
  let horizontalInset: CGFloat
  let shelfSpacing: CGFloat
  let activity: Activity
  /// Bumped when something outside this view may have changed the saves.
  let refreshToken: Int
  /// Heading for the grid that follows.
  let gridTitle: String
  let platformName: (TVGameItem) -> String
  let onPlay: (TVGameItem) -> Void
  let onBootSave: (SaveStateInfo) -> Void
  let onOpenPeer: (NearbyLibrariesModel.Peer) -> Void
  let onBrowseNearby: () -> Void
  let onShowSaves: () -> Void
  let onShowActivity: () -> Void
  @ViewBuilder let recentCard: (TVGameItem) -> RecentCard

  @StateObject private var data = LibraryDashboardModel()
  @ObservedObject private var nearby = NearbyLibrariesModel.shared
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage("library_disable_artwork") private var disableArtwork = false
  @ScaledMetric(relativeTo: .largeTitle) private var heroHeight = ICubeDesign.LibraryDashboard.heroMinimumHeight

  private typealias Metrics = ICubeDesign.LibraryDashboard
  private static var rowGap: CGFloat { ICubeDesign.Spacing.s.rawValue }
  private static var sectionGap: CGFloat { ICubeDesign.Spacing.l.rawValue }

  var body: some View {
    let recent = recentGames()
    let recentSaves = LibraryDashboardBuilder.recentSaves(
      groups: data.saveGroups, visibleGameIDs: Set(games.map(\.gameID)))
    VStack(alignment: .leading, spacing: Self.sectionGap) {
      topRow(hero: recent.first)
        .padding(.horizontal, horizontalInset)
      if !recentSaves.isEmpty {
        savesSection(recentSaves)
      }
      if !recent.isEmpty {
        recentlyPlayedSection(recent)
      }
      sectionTitle(gridTitle)
        .padding(.horizontal, horizontalInset)
    }
    .padding(.top, Self.rowGap)
    .onAppear { data.reload() }
    .onChange(of: refreshToken) { data.reload() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidEndNotification"))) { _ in
      data.reload()
    }
  }

  /// Newest first, each resolved to the game itself rather than a patched copy that shares its ID.
  private func recentGames() -> [TVGameItem] {
    LibraryDashboardBuilder.recentGameIDs(in: games.map { LibraryGameRef(id: $0.gameID) }, lastPlayed: data.lastPlayed)
      .compactMap { ModdedLibrary.baseGame(withGameID: $0, in: games) }
  }

  // MARK: - Top row

  @ViewBuilder
  private func topRow(hero: TVGameItem?) -> some View {
    if let hero, isWide, !dynamicTypeSize.isAccessibilitySize {
      sideBySide(hero)
    } else {
      VStack(spacing: Self.rowGap) {
        if let hero { heroCard(hero) }
        tiles
        nearbyPanel
      }
    }
  }

  /// The hero alone sets the row's height: the right column is an overlay over a zero-height spacer of its width,
  /// so the panel takes what the tiles leave and scrolls past that, rather than stretching the row.
  private func sideBySide(_ hero: TVGameItem) -> some View {
    HStack(alignment: .top, spacing: Self.sectionGap) {
      heroCard(hero).frame(maxWidth: .infinity)
      Color.clear.frame(width: Metrics.sideColumnWidth, height: 0)
    }
    .overlay(alignment: .topTrailing) {
      VStack(spacing: Self.rowGap) {
        tiles
        nearbyPanel.frame(maxHeight: .infinity, alignment: .top)
      }
      .frame(width: Metrics.sideColumnWidth)
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  // MARK: - Hero

  private func heroCard(_ game: TVGameItem) -> some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.heroCornerRadius, style: .continuous)
    return Button { onPlay(game) } label: {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
        Text(L("Continue Playing"))
          .icubeText(.tag)
          .foregroundStyle(.white.opacity(Metrics.heroEyebrowOpacity))
        HStack(alignment: .top, spacing: ICubeDesign.Spacing.m.rawValue) {
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
            Text(LibraryMetadataService.customTitle(for: game) ?? game.title)
              .icubeText(.title)
              .foregroundStyle(.white)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
              .multilineTextAlignment(.leading)
            Text(platformName(game))
              .icubeText(.body)
              .foregroundStyle(.white.opacity(Metrics.heroDetailOpacity))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if !disableArtwork, !dynamicTypeSize.isAccessibilitySize {
            heroCover(game)
          }
        }
        Spacer(minLength: 0)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Self.rowGap) {
            playLabel(game)
            Spacer(minLength: 0)
            heroContext(game)
          }
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
            playLabel(game)
            heroContext(game)
          }
        }
      }
      .padding(ICubeDesign.Spacing.l.rawValue)
      .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .topLeading)
      .background {
        if !disableArtwork {
          Image(uiImage: game.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: Metrics.heroBackdropBlur)
            .overlay {
              LinearGradient(
                colors: [.black.opacity(Metrics.heroScrimLeadingOpacity), .black.opacity(Metrics.heroScrimTrailingOpacity)],
                startPoint: .leading,
                endPoint: .trailing
              )
            }
            .accessibilityHidden(true)
        }
      }
      // White words in either appearance, so the card is dark with or without art.
      .background(.black)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(.white.opacity(Metrics.heroStrokeOpacity), lineWidth: ICubeDesign.Line.hairline.rawValue)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
  }

  private func heroCover(_ game: TVGameItem) -> some View {
    Image(uiImage: game.coverImage)
      .resizable()
      .scaledToFill()
      .frame(width: Metrics.heroCoverSize.width, height: Metrics.heroCoverSize.height)
      .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
      .rotationEffect(.degrees(Metrics.heroCoverTilt))
      .shadow(
        color: .black.opacity(Metrics.heroCoverShadowOpacity),
        radius: Metrics.heroCoverShadowRadius,
        y: ICubeDesign.Spacing.xs.rawValue
      )
      .padding(.trailing, ICubeDesign.Spacing.xs.rawValue)
      .accessibilityHidden(true)
  }

  private func playLabel(_ game: TVGameItem) -> some View {
    let canResume = LibraryDashboardBuilder.canResume(
      gameID: game.gameID, groups: data.saveGroups, resumeEnabled: SaveStateService.resumeEnabled)
    return Label(canResume ? L("Resume") : L("Play"), systemImage: "play.fill")
      .icubeText(.body)
      .fontWeight(.semibold)
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(.black)
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
      .background(Color.accentColor, in: Capsule())
  }

  @ViewBuilder
  private func heroContext(_ game: TVGameItem) -> some View {
    if let text = heroContextText(game) {
      Text(text)
        .icubeText(.detail)
        .foregroundStyle(.white.opacity(Metrics.heroDetailOpacity))
        .lineLimit(1)
    }
  }

  private func heroContextText(_ game: TVGameItem) -> String? {
    if let saved = data.saveGroups[game.gameID]?.first?.modifiedAt {
      return String(format: L("Saved %@"), Self.relative(saved))
    }
    if let played = data.lastPlayed[game.gameID] {
      return String(format: L("Played %@"), Self.relative(played))
    }
    return nil
  }

  private static func relative(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
  }

  // MARK: - Tiles

  @ViewBuilder
  private var tiles: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: ICubeDesign.Spacing.xs.rawValue) { tileRow }
    } else {
      HStack(alignment: .top, spacing: ICubeDesign.Spacing.xs.rawValue) { tileRow }
    }
  }

  @ViewBuilder
  private var tileRow: some View {
    nearbyTile
    Button(action: onShowActivity) {
      DashboardTile(
        title: activityTitle,
        detail: L("Manage Sources"),
        systemImage: "arrow.triangle.2.circlepath",
        isBusy: activity.isBusy
      )
    }
    .buttonStyle(.plain)
    Button(action: onShowSaves) {
      DashboardTile(
        title: savesTitle,
        detail: data.hasLoadedSaves ? L("Browse save states") : L("Indexing saves…"),
        systemImage: "clock.arrow.circlepath"
      )
    }
    .buttonStyle(.plain)
  }

  /// One device opens straight away; several ask which, since the tile has room for only a count.
  @ViewBuilder
  private var nearbyTile: some View {
    let tile = DashboardTile(title: nearbyTitle, detail: L("Nearby Libraries"), systemImage: "ipad.and.iphone")
    if nearby.peers.count > 1 {
      Menu {
        ForEach(nearby.peers) { peer in
          Button(peer.name) { onOpenPeer(peer) }
        }
      } label: {
        tile
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
    } else {
      Button {
        if let peer = nearby.peers.first { onOpenPeer(peer) } else { onBrowseNearby() }
      } label: {
        tile
      }
      .buttonStyle(.plain)
    }
  }

  private var nearbyTitle: String {
    switch nearby.peers.count {
    case 0: return L("No devices")
    case 1: return L("1 device")
    default: return String(format: L("%d devices"), nearby.peers.count)
    }
  }

  private var activityTitle: String {
    if activity.isScanning { return L("Scanning") }
    if activity.cachingCount > 0 { return L("Caching") }
    return L("Idle")
  }

  private var savesTitle: String {
    guard data.hasLoadedSaves else { return L("Saves") }
    let count = LibraryDashboardBuilder.saveCount(groups: data.saveGroups)
    return count == 1 ? L("1 save") : String(format: L("%d saves"), count)
  }

  // MARK: - Nearby panel

  /// Replaces `NearbyLibrariesStrip` at this width. Lists every device, scrolling if the row left it too little room.
  private var nearbyPanel: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
    return VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      Text(L("Nearby"))
        .icubeText(.tag)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .accessibilityAddTraits(.isHeader)
      if nearby.peers.isEmpty {
        Button(action: onBrowseNearby) {
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
            Text(L("No nearby libraries"))
              .icubeText(.body)
              .fontWeight(.semibold)
              .foregroundStyle(ICubeDesign.color(.textPrimary))
            Text(L("Turn on Share My Library on another iCube device on this Wi-Fi."))
              .icubeText(.detail)
              .foregroundStyle(ICubeDesign.color(.textSecondary))
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else {
        ViewThatFits(in: .vertical) {
          nearbyRows
          ScrollView(showsIndicators: false) { nearbyRows }
        }
      }
    }
    .padding(Self.rowGap)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.thinMaterial, in: shape)
    .overlay {
      shape.strokeBorder(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
    }
  }

  private var nearbyRows: some View {
    VStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
      ForEach(nearby.peers) { peer in
        Button { onOpenPeer(peer) } label: { nearbyRow(peer) }
          .buttonStyle(.plain)
          .accessibilityElement(children: .combine)
      }
    }
  }

  private func nearbyRow(_ peer: NearbyLibrariesModel.Peer) -> some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image(systemName: NearbyLibrariesModel.glyph(for: peer.deviceType))
        .foregroundStyle(Color.accentColor)
        .frame(width: Metrics.peerIconSize, height: Metrics.peerIconSize)
        .background(Color.accentColor.opacity(Metrics.peerIconWash), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(peer.name)
          .icubeText(.body)
          .fontWeight(.semibold)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
        HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
          if nearby.status(for: peer) == .loading {
            ProgressView().controlSize(.mini)
          }
          Text(nearby.subtitle(for: peer))
            .icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
        }
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textTertiary))
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
  }

  // MARK: - Shelves

  private func savesSection(_ saves: [SaveStateInfo]) -> some View {
    VStack(alignment: .leading, spacing: Self.rowGap) {
      sectionTitle(L("Recent Saves"))
        .padding(.horizontal, horizontalInset)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: shelfSpacing) {
          // `SaveStateInfo.id` is minted on every scan; the path is what stays the same across one.
          ForEach(saves, id: \.path) { save in
            Button { onBootSave(save) } label: {
              DashboardSaveCard(save: save, gameTitle: title(forGameID: save.gameID))
            }
            .buttonStyle(.plain)
            .disabled(!save.isCompatible)
            .accessibilityHint(L("Starts the game from this save"))
          }
        }
        .padding(.horizontal, horizontalInset)
      }
    }
  }

  private func title(forGameID gameID: String) -> String {
    guard let game = ModdedLibrary.baseGame(withGameID: gameID, in: games) else { return gameID }
    return LibraryMetadataService.customTitle(for: game) ?? game.title
  }

  private func recentlyPlayedSection(_ recent: [TVGameItem]) -> some View {
    VStack(alignment: .leading, spacing: Self.rowGap) {
      sectionTitle(L("Recently Played"))
        .padding(.horizontal, horizontalInset)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: shelfSpacing) {
          ForEach(recent, id: \.filePath) { recentCard($0) }
        }
        .padding(.horizontal, horizontalInset)
      }
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .icubeText(.section)
      .foregroundStyle(ICubeDesign.color(.textPrimary))
      .accessibilityAddTraits(.isHeader)
  }
}

/// A status tile: glyph, what it says now, what tapping it reaches.
private struct DashboardTile: View {
  let title: String
  let detail: String
  let systemImage: String
  var isBusy = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      if isBusy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
      }
      Text(title)
        .icubeText(.body)
        .fontWeight(.semibold)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(detail)
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .lineLimit(2, reservesSpace: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(ICubeDesign.Spacing.s.rawValue)
    .background(.thinMaterial, in: shape)
    .overlay {
      shape.strokeBorder(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
    }
    .contentShape(shape)
    .accessibilityElement(children: .combine)
  }
}

/// One save on the Recent Saves strip. A save from another build's format stays visible but dimmed, as on the
/// filmstrip, since it can't load.
private struct DashboardSaveCard: View {
  let save: SaveStateInfo
  let gameTitle: String

  @State private var thumbnail: UIImage?

  private typealias Metrics = ICubeDesign.LibraryDashboard

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      ICubeDesign.color(.rowSurface)
        .aspectRatio(Metrics.saveThumbnailAspect, contentMode: .fit)
        .overlay {
          if let thumbnail {
            Image(uiImage: thumbnail)
              .resizable()
              .scaledToFill()
          } else {
            Image(systemName: "photo")
              .foregroundStyle(ICubeDesign.color(.textTertiary))
          }
        }
        .clipShape(shape)
        .overlay {
          shape.strokeBorder(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
        }
        .accessibilityHidden(true)
      Text(gameTitle)
        .icubeText(.detail)
        .fontWeight(.semibold)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
      Text(subtitle)
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .lineLimit(1)
    .frame(width: Metrics.saveCardWidth)
    .opacity(save.isCompatible ? 1 : Metrics.incompatibleSaveOpacity)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .task(id: save.thumbnailURL) { thumbnail = await Self.loadThumbnail(save.thumbnailURL) }
  }

  private var subtitle: String {
    guard save.isCompatible else { return L("Incompatible") }
    guard let date = save.modifiedAt ?? save.createdAt else { return save.displayName }
    return "\(save.displayName) · \(date.formatted(.relative(presentation: .named)))"
  }

  private static func loadThumbnail(_ url: URL?) async -> UIImage? {
    guard let url else { return nil }
    return await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
  }
}
#endif
