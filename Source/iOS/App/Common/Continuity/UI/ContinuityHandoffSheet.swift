// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// The sending side, reached from the in-game pause menu: offer the running
/// game to another device.
///
/// ## tvOS
///
/// Every control is its own `List` row, and dismissal is a row rather than a
/// toolbar item — a `.toolbar { Done }` behind `#if os(iOS)` would strand a
/// tvOS user in the sheet with no way out.
struct ContinuityHandoffSheet: View {
    let game: TVGameItem

    @ObservedObject private var manager = ContinuityManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ContinuitySecurityNotice()
                }

                Section(header: Text(L("Game"))) {
                    Text(game.title)
                    Text(game.gameID).foregroundColor(.secondary)
                }

                if let error = manager.lastError {
                    Section {
                        Text(error).foregroundColor(.orange)
                    }
                }

                Section(header: Text(L("Hand Off"))) {
                    if manager.activeSession == nil {
                        Button(L("Offer To Nearby Devices")) {
                            Task { await manager.beginHandoff(game: game) }
                        }
                    } else {
                        Text(L("Visible to nearby devices. Open iCube on the other device and pick this one."))
                            .foregroundColor(.secondary)
                        Button(L("Stop Offering"), role: .destructive) {
                            Task { await manager.endHandoff() }
                        }
                    }
                }

                Section {
                    Button(L("Done")) { dismiss() }
                }
            }
            .navigationTitle(L("Continue On Another Device"))
        }
        // A peer that pairs with this device does so while this sheet is up,
        // because this is the device that is serving. The prompt belongs here.
        .continuityPairingPrompt()
    }
}

// MARK: - Pairing prompt

/// Presents the incoming-pairing prompt wherever it is attached.
///
/// An alert rather than a sheet: it has to interrupt, it carries a code the
/// user reads aloud, and it has exactly two answers. `.alert` gives a usable
/// presentation on tvOS, which `Menu` and `Picker` do not.
private struct ContinuityPairingPromptModifier: ViewModifier {
    @ObservedObject private var manager = ContinuityManager.shared

    func body(content: Content) -> some View {
        content.alert(
            L("Pair With This Device?"),
            isPresented: Binding(
                get: { manager.pendingPairing != nil },
                // Dismissal without an explicit answer is a decline. Defaulting
                // the other way would mean a stray tap grants a stranger access
                // to this device's save data.
                set: { if !$0 { manager.pendingPairing?.respond(false) } }
            ),
            presenting: manager.pendingPairing
        ) { prompt in
            Button(L("Allow")) { prompt.respond(true) }
            Button(L("Don't Allow"), role: .cancel) { prompt.respond(false) }
        } message: { prompt in
            Text(String(
                format: L("%@ wants to continue your game. Read this code out to confirm it's them:\n\n%@\n\n%@"),
                prompt.peerName,
                prompt.code,
                ContinuityManager.transportSecurityNotice
            ))
        }
    }
}

extension View {
    /// Attach on any screen that can be live while this device is serving.
    func continuityPairingPrompt() -> some View {
        modifier(ContinuityPairingPromptModifier())
    }
}
