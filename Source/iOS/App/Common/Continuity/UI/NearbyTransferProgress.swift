// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI

struct NearbyTransferProgress: View {
  @Environment(\.icube) private var icube
  let bytes: Int64
  let total: Int64
  var body: some View {
    VStack(alignment: .leading) {
      ProgressView(value: total > 0 ? min(1, Double(bytes) / Double(total)) : 0)
      Text(NearbyTransferFormat.label(bytes: total, total: total))
        .hidden()
        .overlay(alignment: .leading) { Text(NearbyTransferFormat.label(bytes: bytes, total: total)) }
        .font(icube.font(.detail).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NearbyTransferFormat.label(bytes: bytes, total: total))
    }
  }
}
