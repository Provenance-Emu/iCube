// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

struct ThermalBadgeView: View {
  @State private var state: Int = 0
  private func icon() -> String {
    switch state {
    case 1: return "thermometer"
    case 2: return "thermometer.sun"
    case 3: return "thermometer.high"
    default: return "thermometer"
    }
  }

  private func color() -> Color {
    switch state {
    case 1: return .yellow
    case 2: return .orange
    case 3: return .red
    default: return .green
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon()).foregroundStyle(color())
    }
    .onReceive(NotificationCenter.default.publisher(for: ThermalManager.changedNotification)) { note in
      if let s = note.userInfo?["state"] as? Int { state = s }
    }
    .onAppear { state = 0 }
  }
}
#endif
