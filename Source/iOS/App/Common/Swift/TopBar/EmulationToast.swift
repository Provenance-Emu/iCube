// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

extension Notification.Name {
  /// Posted with `userInfo["text"]` to show a short, non-blocking message. The library screen has always
  /// observed it, but it renders under the pushed game screen, so `EmulationToastOverlay` shows it in-game.
  static let dolShowSnackbar = Notification.Name("DOLShowSnackbar")
}

enum EmulationToast {
  static let textKey = "text"
  /// How long a message stays up.
  static let displayDuration: TimeInterval = 1.8

  static func post(_ text: String) {
    NotificationCenter.default.post(name: .dolShowSnackbar, object: nil, userInfo: [textKey: text])
  }
}

/// Capsule toast pinned under the top bar, driven by `DOLShowSnackbar`. Never intercepts touches.
struct EmulationToastOverlay: View {
  /// Clears the top bar (12 pt padding + 44 pt controls + 8 pt) so a message never covers it.
  private static let topOffset: CGFloat = 76

  @State private var text: String?
  @State private var dismissTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      if let text {
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color.black.opacity(0.8), in: Capsule())
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, Self.topOffset)
    .allowsHitTesting(false)
    .onReceive(NotificationCenter.default.publisher(for: .dolShowSnackbar)) { note in
      guard let message = note.userInfo?[EmulationToast.textKey] as? String else { return }
      show(message)
    }
  }

  private func show(_ message: String) {
    dismissTask?.cancel()
    withAnimation { text = message }
    AccessibilityNotification.Announcement(message).post()
    dismissTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(EmulationToast.displayDuration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      withAnimation { text = nil }
    }
  }
}
