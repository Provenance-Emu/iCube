// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// One nearby device's shared library as covers, opened from the main
/// library: inline in the tvOS content column, in a sheet on iOS.
///
/// Opening it is the explicit user action, so it is the one place pairing may
/// start (`load(from:)` with pairing allowed): an unpaired device asks for the
/// code here, inline, instead of sending the user through Settings.
///
/// Settings' Nearby screen keeps its own list-based `ContinuityPeerLibraryView`;
/// both drive the same `ContinuityLibraryBrowseController`.
struct NearbyPeerLibraryView: View {
    let peer: NearbyLibrariesModel.Peer
    /// Disc IDs already in this library, to mark covers "In Library".
    let ownedGameIDs: Set<String>
    /// Shows the device name and glyph above the content. The tvOS library
    /// already titles its column, so it passes false.
    var showsHeader = true
    /// tvOS: the first control takes this focus, so the rail can hand focus
    /// into the column.
    var initialFocus: FocusState<Bool>.Binding?

    @StateObject private var controller = ContinuityLibraryBrowseController(
        identity: ContinuityManager.shared.identity
    )
    @State private var pairingCode = ""
    @State private var codeRejected = false
    /// The catalog stays on screen while a copy runs and after it lands.
    @State private var entries: [ContinuityLibraryEntry] = []
    @State private var hasCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if showsHeader { header }
            statusContent
            if hasCatalog { grid }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: peer.id) { await load() }
        .onChange(of: controller.phase) { _, phase in
            if case .browsing(let list) = phase {
                entries = list
                hasCatalog = true
                NearbyLibrariesModel.shared.noteCatalog(peerID: peer.id, count: list.count)
            }
        }
        .onDisappear { controller.cancel() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Metrics.headerSpacing) {
            Image(systemName: NearbyLibrariesModel.glyph(for: peer.deviceType))
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.headline)
                Text(hasCatalog ? Self.gameCount(entries.count) : L("Nearby Library"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch controller.phase {
        case .idle, .loading:
            HStack(spacing: Metrics.headerSpacing) {
                ProgressView()
                Text(String(format: L("Looking at what %@ is sharing…"), peer.name))
                    .foregroundStyle(.secondary)
            }

        case .awaitingPairing:
            pairingCard

        case .browsing(let list):
            if list.isEmpty {
                Text(String(format: L("%@ isn't sharing any games right now."), peer.name))
                    .foregroundStyle(.secondary)
            }

        case .copying(let entry, let progress):
            card {
                Text(String(format: L("Copying %@"), entry.game.displayName)).font(.headline)
                if let progress {
                    ProgressView(value: progress.fractionComplete)
                    Text(Self.transferred(progress)).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(String(format: L("Asking %@…"), peer.name)).foregroundStyle(.secondary)
                }
                actionButton(L("Cancel"), systemImage: "xmark", role: .destructive) { cancelCopy() }
                    .modifier(FirstFocus(binding: initialFocus))
            }

        case .copied(let entry):
            Label(String(format: L("%@ is now in your library."), entry.game.displayName),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failed(let message):
            card {
                Text(message)
                actionButton(L("Try Again"), systemImage: "arrow.clockwise", prominent: true) { Task { await load() } }
                    .modifier(FirstFocus(binding: initialFocus))
            }
        }
    }

    private var pairingCard: some View {
        card {
            Text(String(format: L("Pair with %@"), peer.name)).font(.headline)
            Text(String(format: L("Enter the 6-digit code shown on %@."), peer.name))
                .foregroundStyle(.secondary)
            ContinuityPairingCodeField(code: $pairingCode, onSubmit: submit)
                .frame(maxWidth: Metrics.codeFieldWidth)
                .modifier(FirstFocus(binding: initialFocus))
            if codeRejected {
                Text(L("That code didn't match. Check the other device and try again."))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            actionStack {
                actionButton(L("Pair"), systemImage: "link", prominent: true) { submit(pairingCode) }
                    .disabled(!ContinuityPairingCodeField.isComplete(pairingCode))
                actionButton(L("Cancel"), systemImage: "xmark", role: .cancel) { controller.cancel() }
            }
            ContinuitySecurityNotice()
                .font(.footnote)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing, alignment: .top)],
            alignment: .leading,
            spacing: Metrics.gridSpacing
        ) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Button { Task { await controller.copy(entry) } } label: {
                    NearbyGameTile(
                        entry: entry,
                        artwork: controller.artwork[entry.key],
                        isOwned: entry.game.gameID.map { ownedGameIDs.contains($0) } ?? false
                    )
                }
                #if os(tvOS)
                .buttonStyle(.card)
                #else
                .buttonStyle(.plain)
                #endif
                .disabled(isCopying)
                .modifier(FirstFocus(binding: index == 0 && !hasStatusControl ? initialFocus : nil))
                .task { await controller.loadArtwork(for: entry) }
            }
        }
    }

    /// The card's actions. tvOS draws them as the app's focus rows (a system bordered button inside the library
    /// column rendered as an empty tinted pill, label missing), stacked so each is its own focus target; iOS
    /// keeps the standard pills side by side.
    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        #if os(tvOS)
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .icubeText(.body)
                .foregroundStyle(ICubeDesign.color(.textPrimary))
        }
        .buttonStyle(ICubeRowButtonStyle())
        .frame(maxWidth: Metrics.codeFieldWidth)
        #else
        if prominent {
            Button(title, systemImage: systemImage, role: role, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, systemImage: systemImage, role: role, action: action).buttonStyle(.bordered)
        }
        #endif
    }

    @ViewBuilder
    private func actionStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.headerSpacing) { content() }
        #else
        HStack(spacing: Metrics.headerSpacing) { content() }
        #endif
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) { content() }
            .padding(Metrics.cardPadding)
            .frame(maxWidth: Metrics.cardMaxWidth, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
    }

    // MARK: - Actions

    private var isCopying: Bool {
        if case .copying = controller.phase { return true }
        return false
    }

    /// The status area holds a focusable control, which then gets first focus
    /// instead of the first cover.
    private var hasStatusControl: Bool {
        switch controller.phase {
        case .awaitingPairing, .copying, .failed: return true
        default: return false
        }
    }

    private func load() async {
        codeRejected = false
        await controller.load(from: peer.advertisement)
    }

    /// The controller drops back to `.awaitingPairing` on a wrong code without
    /// saying so; `codeRejected` is how the user finds out.
    private func submit(_ code: String) {
        guard ContinuityPairingCodeField.isComplete(code) else { return }
        pairingCode = ""
        codeRejected = false
        Task {
            await controller.submitPairingCode(code)
            codeRejected = controller.phase == .awaitingPairing
        }
    }

    /// Cancelling a copy returns to the covers, not to an error screen.
    private func cancelCopy() {
        controller.cancel()
        Task { await load() }
    }

    // MARK: - Formatting

    static func gameCount(_ count: Int) -> String {
        count == 1 ? L("1 game") : String(format: L("%d games"), count)
    }

    private static func transferred(_ progress: PullProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return String(
            format: L("%@ of %@"),
            formatter.string(fromByteCount: progress.bytesTransferred),
            formatter.string(fromByteCount: progress.totalBytes)
        )
    }

    private enum Metrics {
        #if os(tvOS)
        static let tileWidth: CGFloat = 220
        static let gridSpacing: CGFloat = 48
        static let codeFieldWidth: CGFloat = 360
        static let cardMaxWidth: CGFloat = 900
        #else
        static let tileWidth: CGFloat = 110
        static let gridSpacing: CGFloat = 16
        static let codeFieldWidth: CGFloat = 220
        static let cardMaxWidth: CGFloat = 520
        #endif
        static let sectionSpacing: CGFloat = 20
        static let headerSpacing: CGFloat = 12
        static let cardSpacing: CGFloat = 12
        static let cardPadding: CGFloat = 16
        static let cornerRadius: CGFloat = 16
    }
}

/// Applies a focus binding when there is one; tvOS inline use only.
private struct FirstFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

/// One shared title: cover, name, and whether it is already here.
private struct NearbyGameTile: View {
    let entry: ContinuityLibraryEntry
    let artwork: Data?
    let isOwned: Bool

    /// GameCube/Wii case proportions, as the library's own cards.
    private static let coverAspect: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .aspectRatio(Self.coverAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isOwned {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.title3)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
            Text(entry.game.displayName)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(isOwned ? L("In Library") : Self.size(entry.sizeBytes))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("Copies this game to this device."))
    }

    @ViewBuilder
    private var cover: some View {
        // A missing cover is a placeholder, never a gap or an error: the host
        // may simply have no art for that title.
        if let artwork, let image = UIImage(data: artwork) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "opticaldisc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
