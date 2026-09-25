// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Send to Provenance" — push this game to a sibling emulator app the same
/// way iFly does: open a local share session and hand Provenance a fetch URL
/// it downloads from over HTTP (the reverse of Provenance asking iCube for a
/// game).
///
/// Offered only when a FETCH-CAPABLE Provenance is installed
/// (`EcosystemBridge.peerCapable()` probes the capability marker scheme, so an
/// old build that can't handle `?fetch=` doesn't show a button that silently
/// no-ops) and the game has an id. iOS-only: opening a foreign URL scheme has
/// no tvOS equivalent, and the call site (`GameGridItem`'s iOS context menu)
/// never reaches this on tvOS.
struct EcosystemSendButton: View {
    let gameID: String

    var body: some View {
        if !gameID.isEmpty, EcosystemBridge.peerCapable() {
            Button {
                EcosystemShareCenter.shared.send(gameID: gameID)
            } label: {
                Label(L("Send to Provenance"), systemImage: "arrow.up.forward.app")
            }
        }
    }
}
