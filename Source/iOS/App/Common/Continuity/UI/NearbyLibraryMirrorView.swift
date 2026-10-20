// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct NearbyLibraryMirrorView: View {
  @ObservedObject private var manager = ContinuityManager.shared
  @ObservedObject private var mirror = ContinuityManager.shared.libraryMirror

  var body: some View {
    SettingsLeafScreen(model: model, title: L("Automatic Game Copying"), sync: mirror.environmentChanged)
      .task { await manager.refreshTrustedPeers() }
      .continuityLibraryPullPrompt()
  }

  private var model: MenuModel {
    let rows = manager.trustedPeers.map { peer in
      SettingsRow.toggle("mirror-\(peer.id)", peer.name, mirror.enabledPeerIDs.contains(peer.id),
                         L("Automatically copy new games from this paired device while both apps are open nearby."),
                         icon: "arrow.down.circle", set: { mirror.setEnabled($0, for: peer.id) })
    }
    var sections = [MenuSection(
      id: "sources", header: L("Copy From These Devices"),
      footer: L("Copies games only. Saves stay on the other device. Removing a game there does not delete your local copy. Both apps must remain open on the same network."),
      items: rows.isEmpty ? [SettingsRow.caption("no-peers", L("No paired devices yet."))] : rows)]
    var status = [SettingsRow.caption("status", statusText)]
    if let progress = mirror.progress {
      let formatter = ByteCountFormatter()
      formatter.countStyle = .file
      status.append(SettingsRow.caption("progress", String(format: L("%@ of %@"),
        formatter.string(fromByteCount: progress.bytesTransferred), formatter.string(fromByteCount: progress.totalBytes))))
    }
    if !mirror.enabledPeerIDs.isEmpty {
      status.append(SettingsRow.action("retry", L("Check Now"), L("Check paired nearby devices for games to copy."),
                                      icon: "arrow.clockwise", run: mirror.retry))
      status.append(SettingsRow.action("disable", L("Turn Off Automatic Copying"),
                                      L("Stop automatic copying from every device. Existing local games are kept."),
                                      icon: "stop.circle", run: mirror.disableAll))
    }
    sections.append(MenuSection(id: "status", header: L("Status"), footer: ContinuityManager.transportSecurityNotice, items: status))
    return MenuModel(sections: sections)
  }

  private var statusText: String {
    switch mirror.state {
    case .disabled: return L("Automatic game copying is off.")
    case .waiting: return L("Waiting for a paired device with both apps open. Copying pauses during gameplay.")
    case .checking(let peer): return String(format: L("Checking %@…"), mirror.peerName(peer))
    case .copying(let peer, let entry):
      return String(format: L("Copying %1$@ from %2$@…"), mirror.entryName(peer: peer, entry: entry), mirror.peerName(peer))
    case .upToDate: return L("All available games have been copied.")
    case .failed(_, let message): return message
    }
  }
}
