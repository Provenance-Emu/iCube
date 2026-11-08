// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import PVContinuity

/// The nearby libraries the main library shows: other iCube devices on this
/// network that share their library, with a game count for the paired ones.
///
/// ## Discovery
///
/// Bonjour browsing runs while the library is on screen and no game is
/// running (`setLibraryVisible`), through its own requirement flag on
/// `ContinuityManager`, so leaving Settings' Nearby screen cannot stop it.
///
/// ## Never pair passively
///
/// A catalog is fetched only for a device this one is already paired with,
/// and always with `allowsPairing: false`. Asking an unpaired host for its
/// catalog starts pairing, which puts a code prompt on the *other* device:
/// doing that for every device in view whenever the library opened would
/// spam everyone nearby. An unpaired device is listed as "Pair to browse" and
/// pairing starts only when the user opens it.
@MainActor
final class NearbyLibrariesModel: ObservableObject {
    static let shared = NearbyLibrariesModel()

    struct Peer: Identifiable, Equatable {
        /// The device's pairing identity (`advertisement.peerId`), not the
        /// Bonjour session id, which changes when the device re-advertises.
        let id: String
        let name: String
        let deviceType: String?
        let advertisement: ContinuityAdvertisement
        let isPaired: Bool
    }

    enum Status: Equatable {
        case notPaired
        case loading
        case games(Int)
        /// Paired, but the catalog didn't come back (stopped sharing, revoked,
        /// unreachable). Opening the device says which and offers to pair again.
        case unavailable
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var statuses: [String: Status] = [:]

    private let manager: ContinuityManager
    private var cancellables: Set<AnyCancellable> = []
    private var fetches: [String: Task<Void, Never>] = [:]
    private var libraryVisible = false
    private var emulating = false

    init(manager: ContinuityManager = .shared) {
        self.manager = manager
        emulating = EmulationState.shared.isActive
        manager.$discoveredPeers
            .combineLatest(manager.$trustedPeers)
            .sink { [weak self] discovered, trusted in
                MainActor.assumeIsolated { self?.rebuild(discovered: discovered, trusted: trusted) }
            }
            .store(in: &cancellables)
        EmulationState.shared.addTransitionHandler { [weak self] active in
            guard let self else { return }
            self.emulating = active
            self.reconcileBrowsing()
            self.fetchMissingCounts()
        }
    }

    /// The library screen appeared or went away.
    func setLibraryVisible(_ visible: Bool) {
        guard libraryVisible != visible else { return }
        libraryVisible = visible
        if visible {
            // Counts go stale while the library is away; refetch on return.
            for (id, status) in statuses where status != .loading { statuses[id] = nil }
            if !manager.hasLoadedTrustedPeers {
                Task { await manager.refreshTrustedPeers() }
            }
            fetchMissingCounts()
        }
        reconcileBrowsing()
    }

    /// Re-reads one device's catalog, e.g. after it was paired from its sheet.
    func refresh(peerID: String) {
        fetches[peerID]?.cancel()
        fetches[peerID] = nil
        statuses[peerID] = nil
        fetchMissingCounts()
    }

    /// A browse the user opened read the catalog; keep the count it saw, which
    /// also clears an `.unavailable` left over from before pairing again.
    func noteCatalog(peerID: String, count: Int) {
        fetches[peerID]?.cancel()
        fetches[peerID] = nil
        statuses[peerID] = .games(count)
    }

    func peer(withID id: String) -> Peer? {
        peers.first { $0.id == id }
    }

    func status(for peer: Peer) -> Status {
        guard peer.isPaired else { return .notPaired }
        return statuses[peer.id] ?? .loading
    }

    func subtitle(for peer: Peer) -> String {
        switch status(for: peer) {
        case .notPaired: return L("Pair to browse")
        case .loading: return L("Loading library…")
        case .games(let count):
            return count == 1 ? L("1 game") : String(format: L("%d games"), count)
        case .unavailable: return L("Unavailable · open to retry")
        }
    }

    static func glyph(for deviceType: String?) -> String {
        switch deviceType {
        case "tv": return "appletv"
        case "pd": return "ipad"
        case "mc": return "desktopcomputer"
        default: return "iphone"
        }
    }

    // MARK: - Private

    private func reconcileBrowsing() {
        manager.setLibraryBrowsingRequired(libraryVisible && !emulating)
    }

    private func rebuild(discovered: [ContinuityPeer], trusted: [TrustedPeer]) {
        let trustedIDs = Set(trusted.map(\.id))
        var seen = Set<String>()
        var next: [Peer] = []
        for peer in discovered {
            guard let ad = peer.advertisement, ad.sharesLibrary, !ad.urlCandidates.isEmpty,
                  let id = ad.peerId, !id.isEmpty, id != manager.identity.id,
                  seen.insert(id).inserted else { continue }
            next.append(Peer(
                id: id,
                name: peer.serviceName,
                deviceType: ad.deviceType,
                advertisement: ad,
                isPaired: trustedIDs.contains(id)
            ))
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // A device that re-advertised (relaunched, turned sharing back on) may answer now: retry a failed count.
        let previous = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.advertisement) })
        for peer in next where statuses[peer.id] == .unavailable && previous[peer.id] != peer.advertisement {
            statuses[peer.id] = nil
        }
        if next != peers { peers = next }
        // A device that left, or was unpaired, loses its count.
        let pairedIDs = Set(next.filter(\.isPaired).map(\.id))
        for id in statuses.keys where !pairedIDs.contains(id) {
            statuses[id] = nil
            fetches[id]?.cancel()
            fetches[id] = nil
        }
        fetchMissingCounts()
    }

    private func fetchMissingCounts() {
        guard libraryVisible, !emulating else { return }
        for peer in peers where peer.isPaired && statuses[peer.id] == nil && fetches[peer.id] == nil {
            statuses[peer.id] = .loading
            let advertisement = peer.advertisement
            let id = peer.id
            fetches[id] = Task { [weak self, manager] in
                let browser = ContinuityLibraryBrowseController(identity: manager.identity)
                await browser.load(from: advertisement, allowsPairing: false)
                guard let self, !Task.isCancelled else { return }
                self.fetches[id] = nil
                if case .browsing(let entries) = browser.phase {
                    self.statuses[id] = .games(entries.count)
                } else {
                    self.statuses[id] = .unavailable
                }
            }
        }
    }
}
