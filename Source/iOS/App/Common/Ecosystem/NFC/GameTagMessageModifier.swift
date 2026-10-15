// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Shows `GameTagCenter.message` (tag written, sibling tag, error) as an alert.
/// Attached once at the app root like the ecosystem share prompt, because a
/// scan or write can be started from the library or from Settings.
struct GameTagMessageModifier: ViewModifier {
    @ObservedObject var center: GameTagCenter

    func body(content: Content) -> some View {
        content.alert(
            L("NFC Tag"),
            isPresented: Binding(
                get: { center.message != nil },
                set: { if !$0 { center.message = nil } }
            )
        ) {
            Button(L("OK"), role: .cancel) { center.message = nil }
        } message: {
            Text(center.message ?? "")
        }
    }
}

extension View {
    func gameTagMessages() -> some View {
        modifier(GameTagMessageModifier(center: .shared))
    }
}
