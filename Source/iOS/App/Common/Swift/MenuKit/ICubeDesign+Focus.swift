// Common/Swift/MenuKit/ICubeDesign+Focus.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The art half of the iCube card focus effect (spec §2.7), frozen from GameGridItem. Its 8 pt ring
/// and 2 pt highlight are not tokens and are used nowhere else. `ICubeCardFocusTests` pins it.
private struct ICubeCardArtFocus: ViewModifier {
  let isFocused: Bool

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(
            LinearGradient(
              colors: isFocused ? [
                Color.cyan.opacity(0.95),
                Color(.dolphinTint).opacity(0.9),
                Color.purple.opacity(0.95),
                Color.cyan.opacity(0.95)
              ] : [Color.clear],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: isFocused ? 8 : 0
          )
          .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
          .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
          .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
          .animation(.easeInOut(duration: 0.6), value: isFocused)
      )
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(Color.white.opacity(isFocused ? 0.4 : 0), lineWidth: isFocused ? 2 : 0)
          .padding(4)
          .animation(.easeInOut(duration: 0.4), value: isFocused)
      )
      .shadow(color: Color.black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 6)
      .overlay {
        // Top sheen while focused.
        if isFocused {
          VStack {
            LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
            Spacer()
          }
          .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
          .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
          .allowsHitTesting(false)
        }
      }
  }
}

/// The container half: lift, tilt (2° at rest, 5° focused) and shadow (spec §2.7).
private struct ICubeCardFocus: ViewModifier {
  let isFocused: Bool

  func body(content: Content) -> some View {
    content
      .scaleEffect(isFocused ? 1.08 : 1.0)
      .rotation3DEffect(.degrees(isFocused ? 5 : 2), axis: (x: 0.1, y: 1.0, z: 0), perspective: isFocused ? 0.8 : 1.0)
      .shadow(color: .black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 4)
      .animation(ICubeDesign.Motion.focusSpring, value: isFocused)
  }
}

extension View {
  /// Apply to the card art (cover or placeholder), inside the card's ZStack.
  func icubeCardArtFocus(isFocused: Bool) -> some View { modifier(ICubeCardArtFocus(isFocused: isFocused)) }

  /// Apply to the whole card (art + title), before its focus/gesture modifiers. A modifier, not a
  /// ButtonStyle: the card keeps its own tap, long-press, play/pause and context menu.
  func icubeCardFocus(isFocused: Bool) -> some View { modifier(ICubeCardFocus(isFocused: isFocused)) }
}

/// Shared focus treatment for rows, tiles and rail items (spec §2.4, §2.6, §3): a 4 pt focus-gradient
/// ring, a cyan glow, a scale, and no system focus capsule. `@Environment(\.isFocused)` is only
/// correct when read inside `makeBody`; iOS has no focus engine for a pad, so the router's polled
/// focus comes in as `isFocusedOverride`.
private struct ICubeFocusChrome: ViewModifier {
  let focused: Bool
  let pressed: Bool
  let radius: CGFloat
  let scale: CGFloat

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(ICubeDesign.focusGradient, lineWidth: focused ? ICubeDesign.Line.focus.rawValue : 0)
      )
      .shadow(color: Color(uiColor: .systemCyan).opacity(focused ? 0.5 : 0), radius: focused ? 20 : 0, x: 0, y: 0)
      .scaleEffect(focused ? scale : 1)
      .zIndex(focused ? 1 : 0)
      .opacity(pressed ? 0.85 : 1)
      .animation(ICubeDesign.Motion.focusSpring, value: focused)
      .focusEffectDisabled()
  }
}

/// Settings, hub, list and sheet rows (spec §3 Row).
struct ICubeRowButtonStyle: ButtonStyle {
  var isFocusedOverride: Bool? = nil
  @Environment(\.isFocused) private var isFocused

  #if os(tvOS)
  private static let minHeight: CGFloat = 72
  #else
  private static let minHeight: CGFloat = 44
  #endif

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
      .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
          .fill(ICubeDesign.color(.rowSurface))
      )
      .modifier(ICubeFocusChrome(focused: isFocusedOverride ?? isFocused, pressed: configuration.isPressed,
                                 radius: ICubeDesign.Radius.small.rawValue, scale: ICubeDesign.Motion.rowFocusScale))
  }
}

/// Pause and hub tiles (spec §3 Tile).
struct ICubeTileButtonStyle: ButtonStyle {
  var isFocusedOverride: Bool? = nil
  /// Overrides the spec's tile height where a screen must fit a fixed number of rows (the tvOS pause grid).
  var minHeight: CGFloat? = nil
  @Environment(\.isFocused) private var isFocused

  #if os(tvOS)
  private static let minHeight: CGFloat = 180
  #else
  private static let minHeight: CGFloat = 96
  #endif

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, minHeight: minHeight ?? Self.minHeight, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .fill(ICubeDesign.color(.rowSurface))
      )
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
      )
      .modifier(ICubeFocusChrome(focused: isFocusedOverride ?? isFocused, pressed: configuration.isPressed,
                                 radius: ICubeDesign.Radius.large.rawValue, scale: ICubeDesign.Motion.tileFocusScale))
  }
}

extension View {
  /// The one blur layer (spec §2.6): rail, sheets, info shelf, pause scrim. Never nest panels.
  func icubePanel() -> some View {
    background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
      )
  }
}
