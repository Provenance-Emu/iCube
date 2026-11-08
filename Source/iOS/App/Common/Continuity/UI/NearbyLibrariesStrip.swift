// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Nearby libraries as cards across the top of the iOS library, and as rows
/// on the empty-library screen. Shown only while at least one device is
/// sharing. Each card opens that device's library (`NearbyPeerLibraryView`).
struct NearbyLibrariesStrip: View {
    @ObservedObject var model: NearbyLibrariesModel
    let onOpen: (NearbyLibrariesModel.Peer) -> Void

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerSpacing) {
            Label(L("Nearby Libraries"), systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.cardSpacing) {
                    ForEach(model.peers) { peer in
                        Button { onOpen(peer) } label: {
                            NearbyLibraryCard(
                                name: peer.name,
                                glyph: NearbyLibrariesModel.glyph(for: peer.deviceType),
                                subtitle: model.subtitle(for: peer),
                                isLoading: model.status(for: peer) == .loading
                            )
                            .frame(width: cardWidth)
                        }
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        return Metrics.tvCardWidth
        #else
        return horizontalSizeClass == .regular ? Metrics.wideCardWidth : Metrics.compactCardWidth
        #endif
    }

    private enum Metrics {
        static let headerSpacing: CGFloat = 10
        static let cardSpacing: CGFloat = 12
        static let compactCardWidth: CGFloat = 260
        static let wideCardWidth: CGFloat = 280
        static let tvCardWidth: CGFloat = 420
    }
}

/// One nearby device: its kind, name, and what opening it will show.
struct NearbyLibraryCard: View {
    let name: String
    let glyph: String
    let subtitle: String
    var isLoading = false

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: glyph)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .background(Color.accentColor.opacity(Metrics.iconWash), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if isLoading { ProgressView().controlSize(.mini) }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(Metrics.padding)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .stroke(.white.opacity(Metrics.strokeOpacity), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        #if os(tvOS)
        static let iconSize: CGFloat = 64
        static let padding: CGFloat = 20
        #else
        static let iconSize: CGFloat = 40
        static let padding: CGFloat = 12
        #endif
        static let spacing: CGFloat = 12
        static let iconWash: Double = 0.15
        static let cornerRadius: CGFloat = 16
        static let strokeOpacity: Double = 0.08
    }
}

/// A nearby device's library in its own sheet, from an iOS card or the empty
/// library. Falls back to a message if the device leaves while it is open.
struct NearbyPeerLibrarySheet: View {
    let peerID: String
    let ownedGameIDs: Set<String>
    let onDone: () -> Void
    @ObservedObject private var model = NearbyLibrariesModel.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let peer = model.peer(withID: peerID) {
                        NearbyPeerLibraryView(peer: peer, ownedGameIDs: ownedGameIDs)
                            .id(peer.id)
                    } else {
                        Label(L("That device is no longer nearby."), systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle(model.peer(withID: peerID)?.name ?? L("Nearby"))
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done"), action: onDone)
                }
            }
        }
    }
}
