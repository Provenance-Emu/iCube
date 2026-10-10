// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The iOS control of a `.stepper` row: a `Slider` with the formatted value beside it. tvOS has no
/// `Slider`; `MenuScreen.tvRow` builds that row itself (see `tvSteppedRow`).
///
/// A drag shows its live value in the label but writes `stepper.value` only when the drag ends, so a
/// setting backed by the config does not save on every tick. A change that is not a drag (VoiceOver's
/// adjustable actions) writes straight away.
struct ValueStepper: View {
  let stepper: MenuStepper
  /// The row title, read out by VoiceOver as the slider's name.
  let title: String
  let isEnabled: Bool

  @State private var isDragging = false
  @State private var dragValue: Double?

  private static let valueMinWidth: CGFloat = 56

  var body: some View {
    HStack(spacing: 12) {
      Slider(
        value: Binding(
          get: { dragValue ?? stepper.value.wrappedValue },
          set: { newValue in
            if isDragging { dragValue = newValue } else { stepper.value.wrappedValue = newValue }
          }),
        in: stepper.range, step: stepper.step,
        onEditingChanged: { editing in
          isDragging = editing
          if !editing, let finished = dragValue {
            stepper.value.wrappedValue = finished
            dragValue = nil
          }
        }
      )
      .accessibilityLabel(title)
      Text(stepper.format(dragValue ?? stepper.value.wrappedValue)).monospacedDigit()
        .frame(minWidth: Self.valueMinWidth, alignment: .trailing)
    }
    .disabled(!isEnabled)
  }
}
#endif
