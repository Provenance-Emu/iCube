// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Persistent banner shown while emulation is paused because an assigned physical
/// controller dropped mid-game. Reconnecting that controller auto-resumes and
/// dismisses the banner (handled in `ControllerManager`), so this view is purely
/// informational — there is no manual dismiss affordance.
struct ControllerDisconnectBanner: View {
  var body: some View {
    VStack {
      HStack(spacing: 10) {
        Image(systemName: "gamecontroller.fill")
          .foregroundStyle(.white)
        Text("Controller disconnected — reconnect to resume.")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .background(
        Capsule(style: .continuous)
          .fill(.black.opacity(0.78))
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(.white.opacity(0.15), lineWidth: 1)
      )
      .padding(.top, 24)
      .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .allowsHitTesting(false)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
