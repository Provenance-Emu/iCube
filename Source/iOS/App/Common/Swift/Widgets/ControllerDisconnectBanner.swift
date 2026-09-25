// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Shown while emulation is paused because an assigned physical controller dropped
/// mid-game. Reconnecting that controller auto-resumes and dismisses the banner
/// (handled in `ControllerManager.startObserving()`'s connect handler), and this
/// view additionally offers an explicit way out instead of being purely
/// informational (audit defect #11):
///
/// - "Use Touch Controls" (iOS only — tvOS has no touchscreen) hands the vacated
///   slot to the on-screen overlay and resumes immediately
///   (`ControllerManager.useTouchControlsForDisconnectedSlot()`).
/// - "Wait for Controller" is an explicit acknowledgement of the default
///   behavior (stay paused until the pad reconnects). It is intentionally a
///   no-op on this view's side — the caller may hook it for telemetry/haptics —
///   so tapping it does not change anything the banner already communicates.
struct ControllerDisconnectBanner: View {
  var onUseTouchControls: (() -> Void)?
  var onWait: () -> Void = {}

  var body: some View {
    VStack {
      VStack(spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: "gamecontroller.fill")
            .foregroundStyle(.white)
          Text("Controller disconnected")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 12) {
          if let onUseTouchControls {
            Button(action: onUseTouchControls) {
              Text("Use Touch Controls")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Capsule(style: .continuous).fill(.white.opacity(0.22)))
            .buttonStyle(.plain)
            .focusable(true)
          }

          Button(action: onWait) {
            Text("Wait for Controller")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
          }
          .background(Capsule(style: .continuous).fill(.white.opacity(0.1)))
          .buttonStyle(.plain)
          .focusable(true)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(.black.opacity(0.78))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(.white.opacity(0.15), lineWidth: 1)
      )
      .padding(.top, 24)
      .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
