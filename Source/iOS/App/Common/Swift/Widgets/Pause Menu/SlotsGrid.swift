// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Slots grid with tvOS focus
private struct SlotsGrid: View {
  @Binding var selectedSlot: Int
  let focused: FocusState<PauseMenuView.FocusField?>.Binding
  private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...10, id: \.self) { i in
        Button(action: { selectedSlot = i }) {
          HStack {
            if selectedSlot == i { Image(systemName: "checkmark") }
            Text("Slot \(i)")
            Spacer()
          }
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .focused(focused, equals: .slot(i))
      }
    }
  }
}
