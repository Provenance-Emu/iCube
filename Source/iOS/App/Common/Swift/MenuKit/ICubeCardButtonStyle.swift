// Common/Swift/MenuKit/ICubeCardButtonStyle.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The tvOS card focus treatment, ported from iFly's `DreamcastCardButtonStyle`: the style owns the lift (1.06,
/// dipping while pressed), the two coloured glows and the springs, and publishes focus as `\.icubeCardFocused`.
/// The card face draws its own fill and border from that value (`icubeCardSurface`), so the glow wraps exactly the
/// face. The glows are the running game's platform accent (`icubePlatformAccent`) and the app accent.
struct ICubeCardButtonStyle: ButtonStyle {
  /// iOS has no focus engine for a game pad: `MenuScreen` passes the polled focus here.
  var isFocusedOverride: Bool? = nil

  func makeBody(configuration: Configuration) -> some View {
    ICubeCardFocus(configuration: configuration, isFocusedOverride: isFocusedOverride)
  }

  /// Focus is read here: a struct-level `@Environment(\.isFocused)` does not update on tvOS.
  private struct ICubeCardFocus: View {
    let configuration: Configuration
    let isFocusedOverride: Bool?
    @Environment(\.isFocused) private var environmentFocused
    @Environment(\.icubePlatformAccent) private var platformAccent

    private var isFocused: Bool { isFocusedOverride ?? environmentFocused }

    var body: some View {
      let scale = isFocused ? ICubeDesign.Card.focusScale : 1
      let primary = platformAccent ?? ICubeDesign.color(.accent)
      configuration.label
        // A touch press lights the face like focus does: the only feedback a finger gets.
        .environment(\.icubeCardFocused, isFocused || configuration.isPressed)
        .scaleEffect(configuration.isPressed ? scale * ICubeDesign.Card.pressedScale : scale)
        .shadow(color: primary.opacity(isFocused ? ICubeDesign.Card.primaryGlowOpacity : 0),
                radius: ICubeDesign.Card.primaryGlowRadius, y: ICubeDesign.Card.primaryGlowY)
        .shadow(color: ICubeDesign.color(.accent).opacity(isFocused ? ICubeDesign.Card.secondaryGlowOpacity : 0),
                radius: ICubeDesign.Card.secondaryGlowRadius, y: ICubeDesign.Card.secondaryGlowY)
        .zIndex(isFocused ? 1 : 0)
        .animation(ICubeDesign.Card.focusSpring, value: isFocused)
        .animation(ICubeDesign.Card.pressSpring, value: configuration.isPressed)
        .focusEffectDisabled()
    }
  }
}

/// A card face's surface: the card fill (opaque on focus) and a hairline that becomes a 3 pt accent border on focus.
private struct ICubeCardSurface: ViewModifier {
  let cornerRadius: CGFloat
  @Environment(\.icubeCardFocused) private var focused
  @Environment(\.icubePlatformAccent) private var platformAccent

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    content
      .background(shape.fill(ICubeDesign.Card.surface.opacity(focused ? 1 : ICubeDesign.Card.restFillOpacity)))
      .overlay(
        shape.strokeBorder(
          focused ? accent : ICubeDesign.color(.accent).opacity(ICubeDesign.Card.restBorderOpacity),
          lineWidth: focused ? ICubeDesign.Card.borderWidth : ICubeDesign.Line.hairline.rawValue))
  }
}

extension View {
  /// The surface for a label inside `ICubeCardButtonStyle`.
  func icubeCardSurface(cornerRadius: CGFloat = ICubeDesign.Card.cornerRadius) -> some View {
    modifier(ICubeCardSurface(cornerRadius: cornerRadius))
  }
}
