// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// Another device's shared library: what it has, and a way to copy one title.
///
/// ## tvOS focus shape
///
/// Every game is **one** `Button`, cover and all. A `List` row is a single
/// focus target on tvOS, so a row with a cover, a title and a separate Copy
/// button would collapse into one focusable element and the button would be
/// unreachable. Activating the row is the copy action, and the row says so.
struct ContinuityPeerLibraryView: View {
    let peerName: String
    let advertisement: ContinuityAdvertisement

    @StateObject private var controller = ContinuityLibraryBrowseController(
        identity: ContinuityManager.shared.identity
    )

    var body: some View {
        List {
            Section {
                ContinuitySecurityNotice()
            }

            switch controller.phase {
            case .idle, .loading:
                Section {
                    Text(L("Looking at what this device is sharing…"))
                        .foregroundColor(.secondary)
                }

            case .browsing(let entries):
                if entries.isEmpty {
                    Section {
                        Text(L("This device isn't sharing any games right now."))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section(
                        header: Text(L("Games")),
                        footer: Text(L("Copying brings the game itself. The other device's saves stay on it."))
                    ) {
                        ForEach(entries) { entry in
                            Button {
                                Task { await controller.copy(entry) }
                            } label: {
                                ContinuityLibraryRow(
                                    entry: entry,
                                    artwork: controller.artwork[entry.key]
                                )
                            }
                            .task { await controller.loadArtwork(for: entry) }
                        }
                    }
                }

            case .copying(let entry, let progress):
                Section(header: Text(L("Copying"))) {
                    Text(entry.game.displayName)
                    if let progress {
                        ProgressView(value: progress.fractionComplete)
                        Text(Self.transferred(progress)).foregroundColor(.secondary)
                    } else {
                        Text(L("Asking the other device…")).foregroundColor(.secondary)
                    }
                }

            case .copied(let entry):
                Section {
                    Text(String(format: L("%@ is now in your library."), entry.game.displayName))
                    Button(L("Back To The List")) {
                        Task { await controller.load(from: advertisement) }
                    }
                }

            case .failed(let message):
                Section(header: Text(L("Didn't Copy"))) {
                    Text(message)
                    Button(L("Try Again")) {
                        Task { await controller.load(from: advertisement) }
                    }
                }
            }
        }
        .navigationTitle(peerName)
        .task { await controller.load(from: advertisement) }
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
}

/// One shared title, as a single focusable unit.
private struct ContinuityLibraryRow: View {
    let entry: ContinuityLibraryEntry
    let artwork: Data?

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.game.displayName)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        // A missing cover is a placeholder, never a blank gap and never an
        // error: the host may simply have no art for that title.
        if let artwork, let image = UIImage(data: artwork) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .cornerRadius(4)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "opticaldisc")
                .foregroundColor(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    private var subtitle: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: entry.sizeBytes)
        guard let gameID = entry.game.gameID, !gameID.isEmpty else { return size }
        return "\(gameID) · \(size)"
    }
}
