// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The iOS control of a `.stepper` row: a `Slider` with the formatted value beside it. tvOS has no
/// `Slider`; `MenuScreen.tvRow` builds that row itself (see `tvSteppedRow`).
struct ValueStepper: View {
  let stepper: MenuStepper
  let isEnabled: Bool

  private static let valueMinWidth: CGFloat = 56

  var body: some View {
    HStack(spacing: 12) {
      Slider(value: stepper.value, in: stepper.range, step: stepper.step)
      Text(stepper.format(stepper.value.wrappedValue)).monospacedDigit()
        .frame(minWidth: Self.valueMinWidth, alignment: .trailing)
    }
    .disabled(!isEnabled)
  }
}
#endif
