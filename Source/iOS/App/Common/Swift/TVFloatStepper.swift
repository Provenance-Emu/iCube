// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// tvOS-friendly float stepper component
struct TVFloatStepper: View {
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let step: CGFloat
  #if os(tvOS)
  @FocusState private var isFocused: Bool
  #endif

  var body: some View {
    #if os(tvOS)
    HStack(spacing: 16) {
      Image(systemName: "minus.circle")
      Text(String(format: "%.3f", value))
        .monospacedDigit()
      Image(systemName: "plus.circle")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .focusable(true)
    .focused($isFocused)
    .padding(8)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 4)
    )
    .animation(.easeInOut(duration: 0.12), value: isFocused)
    .onMoveCommand { direction in
      switch direction {
      case .left:
        value = max(range.lowerBound, value - step)
      case .right:
        value = min(range.upperBound, value + step)
      default:
        break
      }
    }
    #else
    HStack(spacing: 16) {
      Button("−") { value = max(range.lowerBound, value - step) }
      Text(String(format: "%.3f", value))
        .monospacedDigit()
      Button("+") { value = min(range.upperBound, value + step) }
    }
    #endif
  }
}
