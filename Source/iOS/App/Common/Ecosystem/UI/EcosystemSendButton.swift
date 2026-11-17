// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Send to Provenance": hand this game's disc image to Provenance
/// (`EcosystemShareCenter.send`). It goes straight into Provenance's drop-box
/// inbox when the installed Provenance receives hand-offs, and through the
/// system share sheet ("Copy to Provenance") when it is an older build.
///
/// Offered when the game has an id and `EcosystemShareCenter.canSend` says the
/// send can work: on iPhone, iPad and Mac whenever Provenance is installed, on
/// Apple TV (no share sheet) only when the direct route is available.
struct EcosystemSendButton: View {
  let gameID: String
  @ObservedObject private var center = EcosystemShareCenter.shared

  var body: some View {
    if !gameID.isEmpty, center.canSend(toScheme: EcosystemSchemes.provenanceScheme) {
      Button {
        center.send(gameID: gameID)
      } label: {
        Label(L("Send to Provenance"), systemImage: "arrow.up.forward.app")
      }
    }
  }
}
