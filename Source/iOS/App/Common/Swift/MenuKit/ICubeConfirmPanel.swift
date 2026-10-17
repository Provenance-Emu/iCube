// Common/Swift/MenuKit/ICubeConfirmPanel.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// An in-place modal card over a scrim: title, message, then the model's rows (pause Reset/Exit confirms, the
/// save-slot manage menu). The model's sections carry no header, so `MenuScreen` draws no second title.
/// Unlike a `.sheet`, the rows' `MenuScreen` claims its own controller scope and never touches the pause
/// menu's child-presented state.
struct ICubeConfirmPanel: View {
  let title: String
  let message: String
  let model: MenuModel
  /// tvOS look: centred, wider, roomier and a darker scrim, so it reads as modal from across the room.
  let isTV: Bool
  let onBack: () -> Void

  private static let tvWidth: CGFloat = 760
  private static let touchWidth: CGFloat = 380
  private static let tvScrimOpacity: Double = 0.7
  private static let touchScrimOpacity: Double = 0.55

  var body: some View {
    ZStack {
      Color.black.opacity(isTV ? Self.tvScrimOpacity : Self.touchScrimOpacity).ignoresSafeArea()
      VStack(alignment: isTV ? .center : .leading, spacing: isTV ? ICubeDesign.Spacing.l.rawValue : ICubeDesign.Spacing.xs.rawValue) {
        VStack(alignment: isTV ? .center : .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
          Text(title)
            .icubeText(.title)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
          Text(message)
            .icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .multilineTextAlignment(isTV ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Intrinsic height: the card is as tall as its rows, however the type scales.
        #if os(tvOS)
        MenuScreen(model: model, style: .list, onBack: onBack, tvClaimsFocus: true)
          .fixedSize(horizontal: false, vertical: true)
          .focusSection()
        #else
        MenuScreen(model: model, style: .grid, onBack: onBack)
          .fixedSize(horizontal: false, vertical: true)
        #endif
      }
      .padding(isTV ? ICubeDesign.Spacing.xl.rawValue : ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: isTV ? Self.tvWidth : Self.touchWidth)
      .background(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
      )
      .padding(ICubeDesign.Spacing.l.rawValue)
    }
    .transition(.opacity)
  }
}
