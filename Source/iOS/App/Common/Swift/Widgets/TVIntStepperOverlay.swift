// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(tvOS)
import SwiftUI

// Simple tvOS-friendly stepper used inside the quick overlay
struct TVIntStepperOverlay: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let step: Int
  @FocusState private var isFocused: Bool
  var body: some View {
    HStack(spacing: 16) {
      Button("−") { value = max(range.lowerBound, value - step) }
      Text("\(value)").frame(minWidth: 44)
      Button("+") { value = min(range.upperBound, value + step) }
    }
    .focusable(true)
    .focused($isFocused)
    .padding(6)
    .background(.white.opacity(isFocused ? 0.15 : 0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onMoveCommand { direction in
      switch direction {
      case .left: value = max(range.lowerBound, value - step)
      case .right: value = min(range.upperBound, value + step)
      default: break
      }
    }
  }
}
#endif
