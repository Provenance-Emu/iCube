// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Uniform action button used in the tvOS pause overlay
private struct ActionButton: View {
  let title: String
  let equals: PauseMenuView.FocusField
  let action: () -> Void
  let focused: FocusState<PauseMenuView.FocusField?>.Binding
  init(_ title: String, equals: PauseMenuView.FocusField, focused: FocusState<PauseMenuView.FocusField?>.Binding, action: @escaping () -> Void) {
    self.title = title
    self.equals = equals
    self.action = action
    self.focused = focused
  }
  var body: some View {
    Button(title, action: action)
      .buttonStyle(.bordered)
      .frame(maxWidth: .infinity)
      .focused(focused, equals: equals)
  }
}
