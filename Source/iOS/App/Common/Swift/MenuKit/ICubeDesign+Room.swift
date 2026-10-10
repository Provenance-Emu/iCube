// Common/Swift/MenuKit/ICubeDesign+Room.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The room every iCube screen sits in (spec §2.5 `room`), in the user's Background Style.
struct ICubeRoom: View {
  let style: LibraryBackgroundStyle

  var body: some View {
    switch style {
    case .clean:
      Self.clean
    case .gradient:
      Self.gradient
    case .animated:
      // The static gradient while a game runs: the orbs and drifting tiles are perpetual animations
      // on a layer behind a screen nobody is looking at.
      EmulationQuiet(idle: LibraryAnimatedBackground(), whileEmulating: Self.gradient)
    }
  }

  /// Follows the appearance: a fixed black here put light-mode (black) titles on black.
  private static var clean: some View {
    #if os(tvOS)
    // tvOS has no .systemBackground; this is what it resolves to on iOS.
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
      .ignoresSafeArea()
    #else
    Color(uiColor: .systemBackground)
      .ignoresSafeArea()
    #endif
  }

  private static var gradient: some View {
    LinearGradient(colors: ICubeDesign.roomStops.map { Color(uiColor: $0) },
                   startPoint: .topLeading, endPoint: .bottomTrailing)
      .ignoresSafeArea()
  }
}
