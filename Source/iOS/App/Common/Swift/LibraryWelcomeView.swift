// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The first thing a new user sees: the animated room, the About screen's moving logo and the three ways forward
/// (add a game, add a remote source, later), with the fork's credit underneath. Full screen over the empty library.
/// Tall screens stack it in one column; a landscape phone and the TV put the hero beside the actions.
struct LibraryWelcomeView: View {
  let onImport: () -> Void
  let onAddSource: () -> Void
  let onDismiss: () -> Void

  #if os(tvOS)
  private enum Action: Hashable { case importGame, addSource, later }
  @FocusState private var focused: Action?
  #else
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  #endif

  var body: some View {
    ZStack {
      ICubeRoom(style: .animated)
      SwimmingDolphinsView(count: 3, direction: .leftToRight, maxSize: 120, opacity: 0.14)
        .allowsHitTesting(false)
      layout
        .padding(.horizontal, ICubeDesign.Spacing.l.rawValue)
        .padding(.vertical, ICubeDesign.Spacing.m.rawValue)
    }
    #if os(tvOS)
    .defaultFocus($focused, .importGame)
    .onExitCommand(perform: onDismiss)
    #endif
  }

  @ViewBuilder private var layout: some View {
    if usesColumns {
      HStack(spacing: ICubeDesign.Welcome.columnGap) {
        hero
          .frame(maxWidth: ICubeDesign.Welcome.columnWidth)
        VStack(spacing: ICubeDesign.Spacing.m.rawValue) {
          actions
          credit
        }
        .frame(maxWidth: ICubeDesign.Welcome.columnWidth)
        #if os(tvOS)
        .focusSection()
        #endif
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // A small phone, or a large text size, scrolls instead of clipping.
      ViewThatFits(in: .vertical) {
        column
        ScrollView { column }
      }
    }
  }

  private var usesColumns: Bool {
    #if os(tvOS)
    true
    #else
    verticalSizeClass == .compact
    #endif
  }

  private var column: some View {
    VStack(spacing: ICubeDesign.Spacing.l.rawValue) {
      hero
      actions
      credit
    }
    .frame(maxWidth: ICubeDesign.Welcome.columnWidth)
    .frame(maxWidth: .infinity)
  }

  private var hero: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      ICubeAnimatedLogo(height: ICubeDesign.Logo.welcomeHeight)
      Text(L("Welcome to iCube"))
        .icubeText(.title)
        .foregroundStyle(ICubeDesign.titleGradient)
        .multilineTextAlignment(.center)
      Text(L("Get started by importing a game or adding a remote source."))
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actions: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      #if os(tvOS)
      // tvOS has no document picker: games arrive through the upload page.
      WelcomeActionCard(title: L("Upload via Wi-Fi…"), detail: L("Send games from a browser on the same Wi-Fi."),
                        systemImage: "wifi", isPrimary: true, action: onImport)
        .focused($focused, equals: .importGame)
      WelcomeActionCard(title: L("Add Remote Source"), detail: L("Browse games on a network share."),
                        systemImage: "externaldrive.badge.plus", isPrimary: false, action: onAddSource)
        .focused($focused, equals: .addSource)
      #else
      WelcomeActionCard(title: L("Import Game"), detail: L("Add ROMs from Files or other apps."),
                        systemImage: "square.and.arrow.down", isPrimary: true, action: onImport)
      WelcomeActionCard(title: L("Add Remote Source"), detail: L("Browse games on a network share."),
                        systemImage: "externaldrive.badge.plus", isPrimary: false, action: onAddSource)
      #endif
      laterButton
    }
  }

  @ViewBuilder private var laterButton: some View {
    #if os(tvOS)
    Button(action: onDismiss) {
      Text(L("Maybe Later"))
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(ICubeRowButtonStyle())
    .focused($focused, equals: .later)
    #else
    Button(action: onDismiss) {
      Text(L("Maybe Later"))
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: ICubeDesign.IconBadge.size)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #endif
  }

  /// iCube is a downstream fork; credit the projects it builds on.
  private var credit: some View {
    VStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text(L("iCube is a fork of DolphiniOS, based on the Dolphin emulator."))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textTertiary))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      #if os(iOS)
      HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
        if let url = URL(string: "https://dolphinios.oatmealdome.me") {
          Link("DolphiniOS", destination: url)
        }
        if let url = URL(string: "https://dolphin-emu.org") {
          Link("Dolphin", destination: url)
        }
      }
      .icubeText(.detail)
      .fontWeight(.semibold)
      .tint(ICubeDesign.color(.accent))
      #endif
    }
  }
}

/// One way forward: an icon badge, a one-line title and a detail line on the card surface. The primary card's
/// badge is filled with the accent; the others are tinted.
private struct WelcomeActionCard: View {
  let title: String
  let detail: String
  let systemImage: String
  let isPrimary: Bool
  let action: () -> Void

  #if os(tvOS)
  private static let badgeSize = ICubeDesign.TileBadge.size
  private static let glyphFont = ICubeDesign.TileBadge.glyphFont(prominent: false)
  #else
  private static let badgeSize = ICubeDesign.IconBadge.size
  private static let glyphFont = ICubeDesign.standard.font(.body).weight(.semibold)
  #endif

  var body: some View {
    Button(action: action) {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        badge
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Text(title)
            .icubeText(.body)
            .fontWeight(.semibold)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(detail)
            .icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .icubeText(.detail)
          .fontWeight(.semibold)
          .foregroundStyle(ICubeDesign.color(.textTertiary))
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .icubeCardSurface(cornerRadius: ICubeDesign.Card.rowCornerRadius)
      .contentShape(RoundedRectangle(cornerRadius: ICubeDesign.Card.rowCornerRadius, style: .continuous))
    }
    .buttonStyle(ICubeCardButtonStyle())
  }

  private var badge: some View {
    let accent = ICubeDesign.color(.accent)
    return RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
      .fill(isPrimary ? accent : accent.opacity(ICubeDesign.IconBadge.tintOpacity))
      .frame(width: Self.badgeSize, height: Self.badgeSize)
      .overlay {
        Image(systemName: systemImage)
          .font(Self.glyphFont)
          .foregroundStyle(isPrimary ? Color.white : accent)
      }
  }
}

/// The empty library's heading, in the welcome's language: the moving logo over a title and a message.
struct LibraryEmptyHeader: View {
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      ICubeAnimatedLogo(height: ICubeDesign.Logo.emptyStateHeight)
      Text(title)
        .icubeText(.title)
        .foregroundStyle(ICubeDesign.titleGradient)
        .multilineTextAlignment(.center)
      Text(message)
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: ICubeDesign.Welcome.columnWidth)
  }
}
