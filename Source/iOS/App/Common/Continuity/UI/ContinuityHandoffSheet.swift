// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// The sending side, reached from the in-game pause menu: offer the running
/// game to another device.
///
/// ## tvOS
///
/// The same rows on the menu engine, over the pause menu's room, like every other
/// pause pane: the stock phone `List` left the notice and status as unfocusable
/// footnote text at 10 feet. Dismissal is a row rather than a toolbar item — a
/// `.toolbar { Done }` behind `#if os(iOS)` would strand a tvOS user in the sheet
/// with no way out; Menu on the remote also closes it through `MenuScreen`'s back.
struct ContinuityHandoffSheet: View {
    let game: TVGameItem

    @ObservedObject private var manager = ContinuityManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            ICubeTVRoomBackground(art: game.bannerImage ?? (game.hasCoverArt ? game.coverImage : nil))
                .environment(\.colorScheme, .dark)
            MenuScreen(
                model: ContinuityHandoffModelBuilder.make(
                    gameTitle: game.title, gameID: game.gameID,
                    isOffering: manager.activeSession != nil, error: manager.lastError,
                    begin: { Task { await manager.beginHandoff(game: game) } },
                    stop: { Task { await manager.endHandoff() } },
                    done: { dismiss() }
                ),
                style: .list,
                onBack: { dismiss() },
                tvHeader: ICubeLeafHeader(title: L("Continue Elsewhere"), subtitle: game.title),
                tvInset: .xl,
                tvClaimsFocus: true
            )
            .frame(maxWidth: 1000)
        }
    }
    #endif

    private var listBody: some View {
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
    }
}

// MARK: - Pairing prompt

/// Presents incoming pairing from the app root, which owns the single alert.
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
                format: L("%@ wants to pair with this device. Read this code out to confirm it's them:\n\n%@\n\n%@"),
                prompt.peerName,
                prompt.code,
                ContinuityManager.transportSecurityNotice
            ))
        }
    }
}

extension View {
    /// Attach once at the app root so library-only hosts can approve pairing.
    func continuityPairingPrompt() -> some View {
        modifier(ContinuityPairingPromptModifier())
    }
}
