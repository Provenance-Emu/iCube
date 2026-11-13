// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import PVContinuity
import RomMClient

/// The other libraries the main library shows: iCube devices on this network
/// that share their library, Emulation Servers (found over Bonjour or saved),
/// and saved RomM servers, each with a game count once it can be read.
///
/// ## Servers
///
/// An Emulation Server advertises `_pvcontent._tcp`; one that is not connected
/// yet is listed as "Connect to browse". A saved server stays listed when it is
/// not on the network, so its library is one tap away again when it returns.
/// RomM has no Bonjour advert, so a RomM server is listed once it is added.
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
        let advertisement: ContinuityAdvertisement?
        var server: EmulationServer? = nil
        var romm: RomMServer? = nil
        let isPaired: Bool
        var serverConnected = false
        var canLoadCatalog: Bool { isPaired || serverConnected }
        /// An Emulation Server or RomM server, as opposed to another device.
        var isServer: Bool { server != nil || romm != nil }
        var needsServerConnection: Bool { isServer && !serverConnected }

        /// The server's catalog with its saved login, or nil for a device.
        func remoteCatalog() -> (any RemoteGameCatalog)? {
            if let server {
                return EmulationServerLibrary(server: server, token: KeychainService.getPassword(for: server.id))
            }
            if let romm { return try? RomMLibrary(server: romm, login: RomMLoginStore.login(for: romm)) }
            return nil
        }

        /// Where a game copied from this server lives, or nil for a device.
        func folder(for entry: ContinuityLibraryEntry) -> URL? {
            if let server { return try? server.folder(for: entry) }
            if let romm { return try? romm.folder(for: entry) }
            return nil
        }
    }

    enum Status: Equatable {
        case notPaired
        case notConnected
        case loading
        case games(Int)
        /// Paired, but the catalog didn't come back (stopped sharing, revoked,
        /// unreachable). Opening the device says which and offers to pair again.
        case unavailable
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var statuses: [String: Status] = [:]

    @Published private(set) var servers: [EmulationServer] = {
        guard let data = UserDefaults.standard.data(forKey: "icube.emulationServers") else { return [] }
        return (try? JSONDecoder().decode([EmulationServer].self, from: data)) ?? []
    }()

    func addServer(_ server: EmulationServer, token: String?) throws {
        if let token {
            guard KeychainService.setPassword(token, for: server.id) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            KeychainService.deletePassword(for: server.id)
        }
        if !servers.contains(server) { servers.append(server) }
        saveServers()
        refresh(peerID: server.id)
    }

  func removeServer(_ server: EmulationServer) {
    EmulationServerBackups.shared.remove(server)
    KeychainService.deletePassword(for: server.id)
    servers.removeAll { $0.id == server.id }
    saveServers()
  }

  private func saveServers() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "icube.emulationServers")
        rebuild(discovered: manager.discoveredPeers, trusted: manager.trustedPeers)
    }

    private static let rommServersKey = "icube.rommServers"
    /// The single server the old RomM screen remembered.
    private static let legacyRomMServerKey = "RomM.lastServer"

    @Published private(set) var rommServers: [RomMServer] = {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: NearbyLibrariesModel.rommServersKey),
           let saved = try? JSONDecoder().decode([RomMServer].self, from: data) {
            return saved
        }
        guard let address = defaults.string(forKey: NearbyLibrariesModel.legacyRomMServerKey).flatMap({ try? RomMAddress($0) }),
              RomMLoginStore.read(address) != nil else { return [] }
        let migrated = [RomMServer(address: address)]
        defaults.set(try? JSONEncoder().encode(migrated), forKey: NearbyLibrariesModel.rommServersKey)
        return migrated
    }()

    /// Saves a RomM server and the login that just worked.
    func addRomMServer(_ server: RomMServer, login: RomMSavedLogin) throws {
        try RomMLoginStore.write(login.storedValue(), server: server.address())
        if !rommServers.contains(server) { rommServers.append(server) }
        saveRomMServers()
        refresh(peerID: server.id)
    }

    func removeRomMServer(_ server: RomMServer) {
        KeychainService.deletePassword(for: server.id)
        rommServers.removeAll { $0.id == server.id }
        saveRomMServers()
    }

    private func saveRomMServers() {
        UserDefaults.standard.set(try? JSONEncoder().encode(rommServers), forKey: Self.rommServersKey)
        rebuild(discovered: manager.discoveredPeers, trusted: manager.trustedPeers)
    }

    private let serverDiscovery = EmulationServerDiscovery()
    private var serverAdvertisements: [EmulationServerAdvertisement] = []
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
        serverDiscovery.onChange = { [weak self] advertisements in
            guard let self else { return }
            self.serverAdvertisements = advertisements
            self.rebuild(discovered: self.manager.discoveredPeers, trusted: self.manager.trustedPeers)
        }
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
        if peer.needsServerConnection { return .notConnected }
        guard peer.canLoadCatalog else { return .notPaired }
        return statuses[peer.id] ?? .loading
    }

    func subtitle(for peer: Peer) -> String {
        switch status(for: peer) {
        case .notPaired: return L("Pair to browse")
        case .notConnected: return L("Connect to browse")
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
        case "server": return "server.rack"
        case "romm": return "externaldrive.connected.to.line.below"
        default: return "iphone"
        }
    }

    // MARK: - Private

    private func reconcileBrowsing() {
        let required = libraryVisible && !emulating
        manager.setLibraryBrowsingRequired(required)
        serverDiscovery.setBrowsing(required)
    }

    private func rebuild(discovered: [ContinuityPeer], trusted: [TrustedPeer]) {
        let trustedIDs = Set(trusted.map(\.id))
        var seen = Set<String>()
        var next: [Peer] = []
        for peer in discovered {
            guard let ad = peer.advertisement, ad.sharesLibrary, !ad.urlCandidates.isEmpty,
                  let id = ad.peerId, !id.isEmpty, !id.hasPrefix("ecs:"), id != manager.identity.id,
                  seen.insert(id).inserted else { continue }
            next.append(Peer(
                id: id,
                name: peer.serviceName,
                deviceType: ad.deviceType,
                advertisement: ad,
                isPaired: trustedIDs.contains(id)
            ))
        }
        let connectedOrigins = Set(servers.map(\.id))
        var seenServerIDs = Set<UUID>()
        // Prefer a configured origin when a server advertises multiple interfaces.
        let advertisements = serverAdvertisements.sorted { lhs, rhs in
            let left = connectedOrigins.contains(lhs.server.id)
            let right = connectedOrigins.contains(rhs.server.id)
            if left != right { return left }
            let leftTLS = lhs.server.origin.scheme == "https"
            let rightTLS = rhs.server.origin.scheme == "https"
            if leftTLS != rightTLS { return leftTLS }
            return lhs.server.id < rhs.server.id
        }
        for advertisement in advertisements where seenServerIDs.insert(advertisement.id).inserted {
            let server = advertisement.server
            guard seen.insert(server.id).inserted else { continue }
            next.append(Peer(id: server.id, name: advertisement.name, deviceType: "server", advertisement: nil,
                             server: server, isPaired: false, serverConnected: connectedOrigins.contains(server.id)))
        }
        for server in servers where seen.insert(server.id).inserted {
            next.append(Peer(id: server.id, name: server.name, deviceType: "server", advertisement: nil,
                             server: server, isPaired: false, serverConnected: true))
        }
        for server in rommServers where seen.insert(server.id).inserted {
            next.append(Peer(id: server.id, name: server.name, deviceType: "romm", advertisement: nil,
                             romm: server, isPaired: false, serverConnected: true))
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // A device that re-advertised (relaunched, turned sharing back on) may answer now: retry a failed count.
        let previous = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
        for peer in next where statuses[peer.id] == .unavailable && previous[peer.id] != peer {
            statuses[peer.id] = nil
        }
        if next != peers { peers = next }
        // A device that left, or was unpaired, loses its count.
        let pairedIDs = Set(next.filter(\.canLoadCatalog).map(\.id))
        for id in statuses.keys where !pairedIDs.contains(id) {
            statuses[id] = nil
            fetches[id]?.cancel()
            fetches[id] = nil
        }
        fetchMissingCounts()
    }

    private func fetchMissingCounts() {
        guard libraryVisible, !emulating else { return }
        for peer in peers where peer.canLoadCatalog && statuses[peer.id] == nil && fetches[peer.id] == nil {
            statuses[peer.id] = .loading
            let id = peer.id
            fetches[id] = Task { [weak self, manager] in
                let status: Status
                if let catalog = peer.remoteCatalog() {
                    // A server counts its own games; reading pages for that would probe every file on them.
                    status = (try? await catalog.gameCount()).map(Status.games) ?? .unavailable
                } else {
                    let browser = ContinuityLibraryBrowseController(identity: manager.identity)
                    await browser.load(peer: peer, allowsPairing: false)
                    if case .browsing(let entries) = browser.phase {
                        status = .games(entries.count)
                    } else {
                        status = .unavailable
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.fetches[id] = nil
                self.statuses[id] = status
            }
        }
    }
}
