// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

/// The owner's side of nearby library sharing: the device switch, the review
/// list of what each paired device may do, and the list of titles held back.
///
/// ## tvOS focus shape
///
/// A `List` row is a **single** focus target on tvOS: a row holding a stack of
/// controls collapses into one focusable element and everything else in it
/// becomes unreachable. So every row here is one control — a `Toggle`, a
/// `Button`, or a `NavigationLink` into a detail screen. There are no `Menu`s
/// and no `Picker`s anywhere in this file: both compile on tvOS and then do
/// nothing when focused, which is worse than not shipping them. Choosing a
/// grant is a `NavigationLink` to a list of `Button`s with a checkmark.
struct ContinuityLibrarySharingView: View {
    @ObservedObject private var manager = ContinuityManager.shared
    @State private var excludedGameIDs: [String] = []

    var body: some View {
        List {
            Section {
                ContinuitySecurityNotice()
            }

            Section(
                header: Text(L("Share This Library")),
                footer: Text(L(
                    "When this is on, devices you've paired with can browse this device's games "
                    + "and copy them. Only the game is sent — never your saves, memory cards or "
                    + "Wii save data."
                ))
            ) {
                Toggle(L("Share My Library"), isOn: Binding(
                    get: { manager.sharesLibrary },
                    set: { newValue in Task { await manager.setSharesLibrary(newValue) } }
                ))
            }

            Section(
                header: Text(L("Paired Devices")),
                footer: Text(L(
                    "\"Ask Every Time\" prompts you when a device tries to copy a game — not when "
                    + "it merely looks at your list."
                ))
            ) {
                if manager.trustedPeers.isEmpty && manager.libraryGrants.isEmpty {
                    Text(L("No paired devices yet."))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(grantRows) { row in
                        NavigationLink(destination: ContinuityGrantDetailView(
                            peerId: row.peerId, peerName: row.name
                        )) {
                            ContinuityGrantRowLabel(name: row.name, grant: row.grant)
                        }
                    }
                }
            }

            Section(
                header: Text(L("Games Not Shared")),
                footer: Text(L(
                    "Excluded games never appear in what this device serves, even to a device "
                    + "that already knows about them."
                ))
            ) {
                if excludedGameIDs.isEmpty {
                    Text(L("Every game in your library is shared."))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(excludedGameIDs, id: \.self) { gameID in
                        // One button per row: the title is the label and
                        // activating it re-includes the game. A row with a
                        // label AND a separate button would be a single focus
                        // target on tvOS.
                        Button {
                            GameProfiles.shared.setExcludedFromNearbySharing(false, forGameID: gameID)
                            reloadExclusions()
                        } label: {
                            HStack {
                                Text(Self.title(forGameID: gameID))
                                Spacer()
                                Text(L("Share Again")).foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Share My Library"))
        .continuityPairingPrompt()
        .continuityLibraryPullPrompt()
        .task {
            await manager.refreshTrustedPeers()
            await manager.refreshLibraryGrants()
            reloadExclusions()
        }
    }

    private func reloadExclusions() {
        excludedGameIDs = GameProfiles.shared.excludedFromNearbySharingGameIDs()
    }

    /// The library's own title for a GameID, falling back to the ID itself.
    ///
    /// The fallback matters: a game excluded and then deleted still has a row
    /// here, and that row is the only way to clear the leftover entry.
    private static func title(forGameID gameID: String) -> String {
        TVLibraryBridge.currentGames()
            .first { $0.gameID == gameID && !$0.isDemoItem }?.title ?? gameID
    }

    /// Every peer worth a row: the paired ones, plus any peer that has a
    /// remembered decision but is no longer paired.
    ///
    /// Including the latter is the whole reason `allGrants()` exists. A
    /// persisted "Don't Share" against a device that was later forgotten would
    /// otherwise be invisible and permanent.
    private var grantRows: [GrantRow] {
        var rows = manager.trustedPeers.map {
            GrantRow(peerId: $0.id, name: $0.name, grant: manager.libraryGrants[$0.id])
        }
        let pairedIds = Set(manager.trustedPeers.map(\.id))
        for (peerId, grant) in manager.libraryGrants where !pairedIds.contains(peerId) {
            rows.append(GrantRow(
                peerId: peerId,
                name: String(format: L("%@ (not paired)"), manager.displayName(forPeerId: peerId)),
                grant: grant
            ))
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct GrantRow: Identifiable {
        let peerId: String
        let name: String
        let grant: ContinuityLibraryGrant?
        var id: String { peerId }
    }
}

/// One peer's row: name and current setting, as a single focusable unit.
private struct ContinuityGrantRowLabel: View {
    let name: String
    let grant: ContinuityLibraryGrant?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(ContinuityGrantDetailView.describe(grant))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

/// Choosing what one peer may do, as a list of buttons with a checkmark.
///
/// Deliberately not a `Picker`: a `Picker` has no usable tvOS presentation, and
/// `.pickerStyle(.segmented)` is no better. A list of `Button`s is focusable,
/// readable and identical on both platforms.
struct ContinuityGrantDetailView: View {
    let peerId: String
    let peerName: String

    @ObservedObject private var manager = ContinuityManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ContinuitySecurityNotice()
            }

            Section(header: Text(L("When This Device Asks"))) {
                ForEach(ContinuityLibraryGrant.allCases, id: \.self) { option in
                    Button {
                        Task { await manager.setLibraryGrant(option, forPeerId: peerId) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.title(for: option))
                                Text(Self.detail(for: option))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if current == option {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            if manager.libraryGrants[peerId] != nil {
                Section(footer: Text(L(
                    "Clearing the setting puts this device back to asking you every time."
                ))) {
                    Button(L("Clear This Setting")) {
                        Task {
                            await manager.clearLibraryGrant(forPeerId: peerId)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(peerName)
    }

    /// Nothing recorded means the default, which is Ask Every Time. Shown as
    /// the checked row rather than as "no selection", because an empty list of
    /// options is not a state the user can act on.
    private var current: ContinuityLibraryGrant {
        manager.libraryGrants[peerId] ?? ContinuityLibraryServer.defaultGrant
    }

    static func describe(_ grant: ContinuityLibraryGrant?) -> String {
        title(for: grant ?? ContinuityLibraryServer.defaultGrant)
    }

    static func title(for grant: ContinuityLibraryGrant) -> String {
        switch grant {
        case .everything: return L("Always Allow")
        case .askPerGame: return L("Ask Every Time")
        case .denied: return L("Don't Share")
        }
    }

    static func detail(for grant: ContinuityLibraryGrant) -> String {
        switch grant {
        case .everything:
            return L("Copies any game without asking.")
        case .askPerGame:
            return L("Can see your list; asks before copying a game.")
        case .denied:
            return L("Can't see your list at all.")
        }
    }
}

// MARK: - Library context-menu item

/// The per-game exclusion switch, as a single context-menu `Button`.
///
/// A `Button` whose label reflects the current state, not a `Toggle`: a
/// `Toggle` inside a `.contextMenu` is inconsistent across iOS and tvOS, and
/// the menu closes on activation anyway, so there is nothing for a switch to
/// animate to.
///
/// It is shown unconditionally rather than only while sharing is on. A user who
/// wants to exclude a game before switching sharing on should be able to, and a
/// control that appears and disappears depending on a setting three screens
/// away is worse than one that is always there.
struct ContinuityExcludeFromSharingButton: View {
    let gameID: String
    /// Bumped on activation so the label re-reads the store. `GameProfiles` is
    /// not observable, and making it so is out of scope for this change.
    @State private var revision = 0

    var body: some View {
        if !gameID.isEmpty {
            let excluded = isExcluded
            Button {
                GameProfiles.shared.setExcludedFromNearbySharing(!excluded, forGameID: gameID)
                revision &+= 1
            } label: {
                Label(
                    excluded ? L("Share With Nearby Devices") : L("Don't Share With Nearby Devices"),
                    systemImage: excluded ? "square.stack.3d.up" : "square.stack.3d.up.slash"
                )
            }
        }
    }

    private var isExcluded: Bool {
        _ = revision
        return GameProfiles.shared.isExcludedFromNearbySharing(gameID: gameID)
    }
}

// MARK: - Per-pull prompt

/// Presents the "a device wants to copy a game" prompt wherever it is attached.
///
/// An alert, for the same reasons as the pairing prompt: it has to interrupt,
/// and `.alert` is the one modal presentation that behaves on tvOS.
///
/// Four answers rather than two, because "yes, and stop asking" and "no, and
/// stop asking" are the decisions a user actually wants to express — and
/// because a two-button prompt that reappears for every game is how people
/// learn to tap Allow without reading it.
private struct ContinuityLibraryPullPromptModifier: ViewModifier {
    @ObservedObject private var manager = ContinuityManager.shared

    func body(content: Content) -> some View {
        content.alert(
            L("Copy This Game?"),
            isPresented: Binding(
                get: { manager.pendingLibraryPull != nil },
                // Dismissal without an answer declines **this** request only.
                // Hardening a stray dismissal into a permanent no would be
                // unrecoverable from the prompt itself.
                set: { if !$0 { manager.pendingLibraryPull?.respond(.denyOnce) } }
            ),
            presenting: manager.pendingLibraryPull
        ) { prompt in
            Button(L("Allow Once")) { prompt.respond(.allowOnce) }
            Button(L("Always Allow This Device")) { prompt.respond(.allowAlways) }
            Button(L("Don't Share"), role: .destructive) { prompt.respond(.denyAlways) }
            Button(L("Not Now"), role: .cancel) { prompt.respond(.denyOnce) }
        } message: { prompt in
            Text(String(
                format: L("%@ wants to copy %@ from this device. Only the game is sent — your saves stay here.\n\n%@"),
                prompt.peerName,
                prompt.gameName,
                ContinuityManager.transportSecurityNotice
            ))
        }
    }
}

extension View {
    /// Attach on any screen that can be live while this device shares its
    /// library.
    func continuityLibraryPullPrompt() -> some View {
        modifier(ContinuityLibraryPullPromptModifier())
    }
}
