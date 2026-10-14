// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Send to Provenance" — hand this game's disc image to Provenance through
/// the system share sheet (`EcosystemShareCenter.send`), where it appears as
/// "Copy to Provenance" because Provenance declares the GameCube and Wii disc
/// types.
///
/// Offered only when Provenance is installed (`EcosystemBridge.peerInstalled`
/// probes its URL scheme) and the game has an id. iOS-only: tvOS has no share
/// sheet, and the call site (`GameGridItem`'s iOS context menu) never reaches
/// this on tvOS.
struct EcosystemSendButton: View {
    let gameID: String

    var body: some View {
        if !gameID.isEmpty, EcosystemBridge.peerInstalled(scheme: EcosystemSchemes.provenanceScheme) {
            Button {
                EcosystemShareCenter.shared.send(gameID: gameID)
            } label: {
                Label(L("Send to Provenance"), systemImage: "arrow.up.forward.app")
            }
        }
    }
}
