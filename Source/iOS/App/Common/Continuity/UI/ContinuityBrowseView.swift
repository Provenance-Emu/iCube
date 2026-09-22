// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// The receiving side: what iCube devices are nearby, and what they are
/// offering.
///
/// ## tvOS focus shape
///
/// A `List` row is a **single** focus target on tvOS, so a row containing
/// several controls collapses into one focusable element and the rest become
/// unreachable. Every row here is therefore either a `NavigationLink` into a
/// detail screen or a single `Button` — never a stack of controls. The actions
/// for a peer live on `ContinuityPeerDetailView`, one per row, for the same
/// reason.
struct ContinuityBrowseView: View {
    @ObservedObject private var manager = ContinuityManager.shared
    @Environment(\.dismiss) private var dismiss
    /// Whether this view owns its own dismissal affordance. False when it is
    /// pushed inside an existing navigation stack (Settings), true in a sheet.
    let showsDoneRow: Bool

    init(showsDoneRow: Bool = false) {
        self.showsDoneRow = showsDoneRow
    }

    var body: some View {
        List {
            Section {
                ContinuitySecurityNotice()
            }

            Section(header: Text(L("Nearby Devices"))) {
                if manager.discoveredPeers.isEmpty {
                    Text(L("Looking for other devices running iCube on this network…"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.discoveredPeers) { peer in
                        NavigationLink(destination: ContinuityPeerDetailView(peer: peer)) {
                            ContinuityPeerRow(peer: peer)
                        }
                    }
                }
            }

            // The owner's side of nearby sharing. Its own row, not a Toggle
            // inline here, because the screen it leads to has three separate
            // things on it (the switch, the per-device grants, the excluded
            // games) and each needs its own focus target on tvOS.
            Section(header: Text(L("This Device"))) {
                NavigationLink(destination: ContinuityLibrarySharingView()) {
                    HStack {
                        Label(L("Share My Library"), systemImage: "square.stack.3d.up")
                        Spacer()
                        Text(manager.sharesLibrary ? L("On") : L("Off"))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !manager.trustedPeers.isEmpty {
                Section(header: Text(L("Paired Devices"))) {
                    ForEach(manager.trustedPeers) { peer in
                        NavigationLink(destination: ContinuityTrustedPeerDetailView(peer: peer)) {
                            Text(peer.name)
                        }
                    }
                }
            }

            if showsDoneRow {
                // tvOS has no toolbar Done; an iOS-only toolbar button would
                // strand a tvOS user in the sheet. A row works on both.
                Section {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .navigationTitle(L("Nearby"))
        // This device can be serving while its user browses (sharing a library
        // is not mutually exclusive with looking at someone else's), so an
        // incoming pairing request has to be answerable from here too — and so
        // does a peer asking to copy a game.
        .continuityPairingPrompt()
        .continuityLibraryPullPrompt()
        .task {
            manager.startBrowsing()
            await manager.refreshTrustedPeers()
            await manager.refreshLibraryGrants()
        }
        .onDisappear { manager.stopBrowsing() }
    }
}

/// One discovered peer, rendered as a single focusable unit.
private struct ContinuityPeerRow: View {
    let peer: ContinuityPeer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.glyph(for: peer.advertisement?.deviceType))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.serviceName)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var subtitle: String {
        guard let advertisement = peer.advertisement else {
            return L("Not compatible with this version of iCube")
        }
        if let game = advertisement.game {
            return String(format: L("Playing %@"), game.displayName)
        }
        if advertisement.sharesLibrary {
            return L("Sharing its library")
        }
        return L("No game in progress")
    }

    private static func glyph(for deviceType: String?) -> String {
        switch deviceType {
        case "tv": return "appletv"
        case "pd": return "ipad"
        case "mc": return "desktopcomputer"
        default: return "iphone"
        }
    }
}

/// Actions for one discovered peer, each on its own row so tvOS can focus them
/// individually.
private struct ContinuityPeerDetailView: View {
    let peer: ContinuityPeer

    @StateObject private var controller = ContinuityReceiveController(
        identity: ContinuityManager.shared.identity
    )
    @State private var pairingCode = ""

    var body: some View {
        List {
            Section {
                ContinuitySecurityNotice()
            }

            if let advertisement = peer.advertisement, let game = advertisement.game {
                Section(header: Text(L("In Progress"))) {
                    Text(game.displayName)
                    if let gameID = game.gameID { Text(gameID).foregroundColor(.secondary) }
                }
                Section {
                    Button(L("Continue On This Device")) {
                        Task { await controller.receive(from: advertisement) }
                    }
                    .disabled(isBusy)
                }
            } else {
                Section {
                    Text(L("This device isn't offering a game right now."))
                        .foregroundColor(.secondary)
                }
            }

            if let advertisement = peer.advertisement, advertisement.sharesLibrary {
                // Its own row rather than a second action inside the section
                // above: on tvOS a row holding two buttons is one focus target
                // and the second one is unreachable.
                Section(header: Text(L("Library"))) {
                    NavigationLink(destination: ContinuityPeerLibraryView(
                        peerName: peer.serviceName, advertisement: advertisement
                    )) {
                        Label(L("Browse Its Games"), systemImage: "square.stack.3d.up")
                    }
                }
            }

            Section(header: Text(L("Status"))) {
                statusRows
            }
        }
        .navigationTitle(peer.serviceName)
    }

    @ViewBuilder
    private var statusRows: some View {
        switch controller.phase {
        case .idle:
            Text(L("Ready")).foregroundColor(.secondary)
        case .authenticating:
            Text(L("Connecting…")).foregroundColor(.secondary)
        case .awaitingPairing:
            // A code entry field and a submit button are separate rows: on tvOS
            // a row holding both would collapse into one focus target and the
            // button would be unreachable.
            Text(L("Enter the 6-digit code shown on the other device."))
                .foregroundColor(.secondary)
            TextField(L("000000"), text: $pairingCode)
            Button(L("Pair")) {
                Task { await controller.submitPairingCode(pairingCode) }
            }
            .disabled(pairingCode.count != 6)
            Button(L("Cancel"), role: .destructive) { controller.cancel() }
        case .fetchingManifest:
            Text(L("Asking the other device to save…")).foregroundColor(.secondary)
        case .pulling(let progress):
            Text(progress.currentFile.relativePath).foregroundColor(.secondary)
            ProgressView(value: progress.fractionComplete)
        case .finished(let outcome):
            Text(Self.describe(outcome))
        }
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .idle, .finished: return false
        default: return true
        }
    }

    /// Every outcome gets a sentence. A failure in particular must never read
    /// as a shrug — the user is told what happened and what it means for them.
    private static func describe(_ outcome: ContinuityOutcome) -> String {
        switch outcome {
        case .proceedWithPulledState:
            return L("Transferred. Starting where the other device left off.")
        case .proceedWithPulledStatePartial(let missing):
            return String(
                format: L("Starting where the other device left off. %d file(s) didn't transfer."),
                missing.count
            )
        case .bootWithLatestLocalState:
            return L("Couldn't get the other device's save. Starting from your most recent save instead.")
        case .bootFresh:
            return L("Couldn't get the other device's save. Starting the game from the beginning.")
        case .failed(let error):
            return error.localizedDescription
        }
    }
}

/// A paired device, with revocation on its own row.
private struct ContinuityTrustedPeerDetailView: View {
    let peer: TrustedPeer
    @ObservedObject private var manager = ContinuityManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(header: Text(L("Paired"))) {
                Text(DateFormatter.localizedString(
                    from: peer.addedAt, dateStyle: .medium, timeStyle: .short
                ))
                .foregroundColor(.secondary)
            }
            Section {
                Button(L("Forget This Device"), role: .destructive) {
                    Task {
                        await manager.revokeTrust(peerId: peer.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(peer.name)
    }
}
