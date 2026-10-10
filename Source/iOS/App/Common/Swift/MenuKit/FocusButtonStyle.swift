// Common/Swift/MenuKit/FocusButtonStyle.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Accent ring, scale and spring on focus, identical on both platforms.
///
/// `@Environment(\.isFocused)` is only correct when read INSIDE `makeBody` (iFly's finding); read in an
/// outer modifier it lags or never updates on tvOS. iOS has no focus engine for a game pad, so the
/// polled focus is passed in as `isFocusedOverride`.
struct FocusButtonStyle: ButtonStyle {
  var isFocusedOverride: Bool? = nil
  @Environment(\.isFocused) private var isFocused
  @Environment(\.icube) private var theme

  func makeBody(configuration: Configuration) -> some View {
    let focused = isFocusedOverride ?? isFocused
    configuration.label
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(theme.tileAccent, lineWidth: focused ? theme.focusRingWidth : 0)
      )
      .scaleEffect(focused ? theme.focusScale : 1)
      .zIndex(focused ? 1 : 0)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
      #if os(tvOS)
      .focusEffectDisabled()
      #endif
  }
}
