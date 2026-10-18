// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The pause screen's game hero (iFly layout, iCube tokens): the cover, "PAUSED" in the platform accent, the title in
/// the display face, the game ID and the running engine. tvOS and the iPad use the tall column beside the tiles; an
/// iPhone gets a banner above them (portrait) or a narrow column without the cover (landscape).
struct PauseHeroView: View {
  enum Layout {
    /// Cover above the text, `artWidth` wide.
    case column(artWidth: CGFloat)
    /// Cover beside the text, for the top of an iPhone screen.
    case banner
    /// No cover: an iPhone in landscape has no height for one.
    case textOnly
  }

  let game: TVGameItem
  let layout: Layout
  /// "JIT ON" while the JIT is acquired, otherwise the engine that is running (INT, CIR, CIR-IR).
  let engineChip: String
  let jitAcquired: Bool
  @Environment(\.icubePlatformAccent) private var platformAccent

  private typealias Metrics = ICubeDesign.PauseHero

  private var accent: Color { platformAccent ?? ICubeDesign.color(.accent) }

  var body: some View {
    switch layout {
    case .column(let artWidth):
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.m.rawValue) {
        art(width: artWidth)
          .shadow(color: .black.opacity(0.5), radius: ICubeDesign.TVPause.heroArtShadowRadius, x: 0, y: ICubeDesign.TVPause.heroArtShadowY)
          .padding(.bottom, ICubeDesign.Spacing.xs.rawValue)
        text(titleLines: Metrics.columnTitleLines)
      }
    case .banner:
      HStack(alignment: .center, spacing: ICubeDesign.Spacing.m.rawValue) {
        art(width: Metrics.bannerArtWidth)
        text(titleLines: Metrics.bannerTitleLines)
      }
    case .textOnly:
      text(titleLines: Metrics.columnTitleLines)
    }
  }

  private func text(titleLines: Int) -> some View {
    VStack(alignment: .leading, spacing: Metrics.textSpacing) {
      Label(L("Paused"), systemImage: "pause.fill")
        .icubeText(.nav)
        .tracking(ICubeDesign.TVPause.pausedTracking)
        .foregroundStyle(accent)
      Text(game.title)
        .font(Metrics.titleFont)
        // Before `icubeText`: the role's own `textCase(nil)` would otherwise sit closer to the text and win.
        .textCase(.uppercase)
        .icubeText(.title)
        .foregroundStyle(LinearGradient(colors: [ICubeDesign.color(.textPrimary), accent], startPoint: .top, endPoint: .bottom))
        .lineLimit(titleLines)
        .minimumScaleFactor(Metrics.titleMinimumScale)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        Text(game.gameID)
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
        Text(engineChip)
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
          .background(Capsule().fill(jitAcquired ? ICubeDesign.color(.selectedFill) : ICubeDesign.color(.rowSurface)))
      }
    }
  }

  /// The cover, filled into a 2:3 case and clipped; without one, the platform's case template on its accent, never a
  /// stretched placeholder glyph.
  private func art(width: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: width < Metrics.smallArtThreshold ? ICubeDesign.Radius.small.rawValue : ICubeDesign.Radius.large.rawValue,
                                 style: .continuous)
    return ZStack {
      if game.hasCoverArt {
        Image(uiImage: game.coverImage).resizable().scaledToFill()
      } else {
        shape.fill(accent.opacity(ICubeDesign.IconBadge.tintOpacity))
        Image(LibraryGameSystem.from(item: game).templateImageName)
          .resizable().scaledToFill()
          .opacity(0.5)
      }
    }
    .frame(width: width, height: width * 3 / 2)
    .clipShape(shape)
    .overlay(shape.stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue))
  }
}

extension ICubeDesign {
  enum PauseHero {
    static let columnTitleLines = 3
    static let bannerTitleLines = 2
    static let bannerArtWidth: CGFloat = 64
    /// Below this the cover takes the small radius.
    static let smallArtThreshold: CGFloat = 120
    static let titleMinimumScale: CGFloat = 0.6
    #if os(tvOS)
    static let textSpacing: CGFloat = Spacing.m.rawValue
    static let titleFont: Font = ICubeDesign.standard.font(.title)
    #else
    static let textSpacing: CGFloat = Spacing.xs.rawValue
    /// The title role is 34 pt on iOS, too big beside a cover at the top of a phone.
    static let titleFont: Font = ICubeDesign.displayFont(size: 24, relativeTo: .title2, bold: true)
    #endif
  }
}
