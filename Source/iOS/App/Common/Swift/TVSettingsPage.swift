// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - SwiftUI Settings for tvOS

internal struct TVSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsRootView()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .background(Color.black)
    }
}
