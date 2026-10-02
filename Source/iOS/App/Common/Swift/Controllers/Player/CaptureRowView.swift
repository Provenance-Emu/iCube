// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One Buttons row: the control's name and its binding, or "Press a button…" while armed. It is a
/// `.custom` menu row, so it carries its own gestures:
/// - Tap or select arms the capture, or cancels it on the armed row.
/// - Long-press (and swipe on iOS) clears the binding, only while the row is enabled (not on a
///   Touchscreen, No Device or disconnected port, nor while another row is armed). These are
///   gesture-raised on the row's own, visible cell, so they are not the lazily-built-row
///   presentations the hub removed; the raw-expression editor's Clear is the pad path.
/// - A controller's A on iOS reaches it through the row's `MenuItem.onCustomActivate`.
///
/// One `Button`, so on tvOS it is one focus target.
struct CaptureRowView: View {
  let title: String
  let binding: String
  let isArmed: Bool
  let isEnabled: Bool
  let onActivate: () -> Void
  let onClear: () -> Void

  var body: some View {
    Button(action: onActivate) {
      HStack {
        Text(title)
        Spacer()
        Text(isArmed ? L("Press a button…") : binding)
          .font(.callout)
          .foregroundStyle(isArmed ? Color.accentColor : Color.secondary)
          .lineLimit(1)
      }
    }
    .disabled(!isEnabled)
    // The gestures are attached unconditionally and offer nothing when the row is not enabled:
    // `.disabled` does not stop a context menu or a swipe action, and a conditional modifier would
    // change the view's identity every time arming flips `isEnabled`, which can drop tvOS focus.
    .contextMenu {
      if isEnabled {
        Button(L("Clear"), role: .destructive, action: onClear)
      }
    }
    #if os(iOS)
    .swipeActions(edge: .trailing) {
      if isEnabled {
        Button(L("Clear"), role: .destructive, action: onClear)
      }
    }
    #endif
    .accessibilityLabel("\(title), \(isArmed ? L("Press a button…") : binding)")
  }
}
