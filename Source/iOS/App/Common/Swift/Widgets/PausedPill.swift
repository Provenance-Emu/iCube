// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Centered HUD pill shown while emulation is paused (and the full pause menu is
/// not open). Per the approved decision, BOTH tapping the pill body and tapping
/// the (x) glyph resume emulation, so `onResume` is invoked from either target.
struct PausedPill: View {
  var onResume: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "pause.fill")
        .foregroundStyle(.white)
      Text("Paused")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.white.opacity(0.7))
        .contentShape(Circle())
        .onTapGesture { onResume() }
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
    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    .contentShape(Capsule(style: .continuous))
    .onTapGesture { onResume() }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .transition(.scale.combined(with: .opacity))
  }
}
