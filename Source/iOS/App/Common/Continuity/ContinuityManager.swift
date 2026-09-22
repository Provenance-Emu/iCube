// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import PVContinuity
import PVWebServer
import UIKit

/// The app-side owner of everything continuity: this device's pairing identity,
/// the trust and grant stores, the session server and its routes, the Bonjour
/// advertiser, and the browser other devices are discovered through.
///
/// ## Transport security — surfaced, not buried
///
/// Continuity moves save states, memory cards, Wii saves and disc images over
/// **plain HTTP on the local network**. There is no TLS. Pairing proves *who*
/// a peer is; it does not encrypt anything, so everything transferred is
/// readable by any other device on the same Wi-Fi.
///
/// `transportSecurityNotice` is the user-facing sentence for that, and both the
/// pairing prompt and the settings surface are required to show it. It is a
/// deliberate tradeoff, carried over from iFly; it is not acceptable for a user
/// to find out by accident.
@MainActor
final class ContinuityManager: ObservableObject {

    static let shared = ContinuityManager()

    /// The sentence every continuity surface must show. One definition, so it
    /// cannot be softened in one place and not another.
    static let transportSecurityNotice = L(
        "Transfers are not encrypted. Save data and games are sent over your local network in the clear, "
        + "so use this only on a network you trust."
    )

    // MARK: - Published state

    /// A pairing request waiting for this user's answer, with the code to read
    /// out. nil when nothing is pending.
    @Published private(set) var pendingPairing: PendingPairingPrompt?
    /// Peers currently visible on the network.
    @Published private(set) var discoveredPeers: [ContinuityPeer] = []
    /// The live outbound session, when this device is offering a game.
    @Published private(set) var activeSession: ContinuitySessionInfo?
    /// Paired devices, refreshed whenever trust changes.
    @Published private(set) var trustedPeers: [TrustedPeer] = []
    /// The last thing that went wrong on the serving side, for the handoff
    /// sheet to show. Nil clears it.
    @Published private(set) var lastError: String?

    struct PendingPairingPrompt: Identifiable {
        let id = UUID()
        let peerName: String
        let code: String
        let respond: (Bool) -> Void
    }

    // MARK: - Owned components

    private(set) var identity: ContinuityPeerIdentity
    let trustStore: FileTrustStore
    let grantStore: FileLibraryGrantStore

    private var sessionServer: ContinuitySessionServer?
    private var pairingServer: ContinuityPairingServer?
    private var advertiser: ContinuityBonjourAdvertiser?
    private let browser = ContinuityBrowser()
    private var browseTask: Task<Void, Never>?

    /// Absolute path of the disc image currently being offered.
    ///
    /// Held in a lock-guarded box rather than as a main-actor property because
    /// the file provider reads it from the session server's actor while
    /// building a manifest, which is off the main actor.
    private let servedGameFilePath = ServedGamePathBox()

    private init() {
        let storeDirectory = ContinuityPaths.userRoot.appendingPathComponent("Continuity", isDirectory: true)
        self.trustStore = FileTrustStore(fileURL: storeDirectory.appendingPathComponent("trusted-peers.json"))
        self.grantStore = FileLibraryGrantStore(fileURL: storeDirectory.appendingPathComponent("library-grants.json"))
        self.identity = ContinuityIdentityStore.loadOrCreate(displayName: Self.deviceName())
    }

    // MARK: - Setup

    /// Registers the continuity routes on the app's web server.
    ///
    /// Called once at launch, NOT per session: the routes answer 404 while no
    /// session is open, which is the correct answer to a stale peer that kept a
    /// URL around, and registering per session would mean the route table grew
    /// every time a user handed a game off.
    func registerRoutes(on registrar: any WebRouteRegistering) {
        let servedPath = servedGameFilePath
        let sessionServer = ContinuitySessionServer(
            fileProvider: ICubeContinuityFileProvider(currentGameFilePath: { servedPath.value }),
            minter: ICubeSaveStateMinter(),
            sourceDevice: Self.sourceDevice()
        )
        self.sessionServer = sessionServer

        let pairingServer = ContinuityPairingServer(
            identity: identity,
            trustStore: trustStore,
            approver: PairingApprovalBridge(manager: self),
            sessionTokenProvider: { [weak sessionServer] in await sessionServer?.activeToken }
        )
        self.pairingServer = pairingServer

        Task {
            await sessionServer.activate(on: registrar)
            await pairingServer.activate(on: registrar)
            await self.refreshTrustedPeers()
        }
    }

    // MARK: - Serving a handoff

    /// Opens a session for `game` and starts advertising it.
    ///
    /// Posts `continuitySessionDidBegin` so `WebServerLifecycleService` can lift
    /// its pause-during-emulation rule — without which the server is stopped by
    /// the time a user reaches the in-game pause menu and no peer can reach
    /// this device at all.
    func beginHandoff(game: TVGameItem) async {
        guard let sessionServer else { return }

        let identity = GameIdentity(gameItem: game)
        guard identity.hasAnyIdentifier else {
            // Without an identifier the receiving device cannot tell what it is
            // being offered, so there is nothing honest to advertise.
            NSLog("[Continuity] refusing to advertise a game with no identifier: %@", game.title)
            return
        }

        servedGameFilePath.value = game.filePath
        let session = await sessionServer.beginSession(game: identity)
        activeSession = session
        lastError = nil

        NotificationCenter.default.post(name: .continuitySessionDidBegin, object: nil)

        // The notification above is what makes the lifecycle policy start the
        // server — and `PVWebServer.startServers()` binds its `NWListener`
        // ASYNCHRONOUSLY. Publishing immediately would ship a TXT record with
        // no `u0`, and the receiving device would fail at its very first step
        // with "the other device advertised no address". So wait for a real
        // URL, and if one never appears, say so instead of advertising a
        // session nothing can reach.
        guard let candidates = await Self.awaitServerURLCandidates(), !candidates.isEmpty else {
            lastError = L("Couldn't start the local server, so this device can't be reached. Check that Wi-Fi is on.")
            await endHandoff()
            return
        }

        let advertiser = ContinuityBonjourAdvertiser(port: Self.serverPort())
        self.advertiser = advertiser
        await advertiser.publish(ContinuityAdvertisement(
            sessionId: session.sessionId,
            token: session.token,
            game: identity,
            urlCandidates: candidates,
            sharesLibrary: false,
            peerId: self.identity.id,
            deviceType: Self.deviceTypeCode()
        ))
    }

    /// Closes the session, withdraws the advertisement and lets the web server
    /// go back to its normal lifecycle.
    func endHandoff() async {
        await advertiser?.withdraw()
        advertiser = nil
        await sessionServer?.endSession()
        servedGameFilePath.value = nil
        guard activeSession != nil else { return }
        activeSession = nil
        NotificationCenter.default.post(name: .continuitySessionDidEnd, object: nil)
    }

    // MARK: - Browsing

    func startBrowsing() {
        guard browseTask == nil else { return }
        browseTask = Task { [browser] in
            for await peers in await browser.peers() {
                await MainActor.run { self.discoveredPeers = peers }
            }
        }
    }

    func stopBrowsing() {
        browseTask?.cancel()
        browseTask = nil
        Task { [browser] in await browser.stop() }
        discoveredPeers = []
    }

    // MARK: - Trust

    func refreshTrustedPeers() async {
        trustedPeers = await trustStore.allPeers()
    }

    /// Revokes a peer. Takes effect on that peer's very next request — the
    /// pairing server reads the store live rather than caching it.
    func revokeTrust(peerId: String) async {
        await trustStore.removePeer(withId: peerId)
        await grantStore.removeGrant(forPeerId: peerId)
        await refreshTrustedPeers()
    }

    func revokeAllTrust() async {
        await trustStore.removeAll()
        await grantStore.removeAll()
        await refreshTrustedPeers()
    }

    // MARK: - Pairing prompt plumbing

    /// Presents the pairing prompt and suspends until the user answers.
    ///
    /// The server races this against the pairing lifetime, so a prompt that is
    /// never answered resolves as a decline rather than wedging the seam.
    fileprivate func awaitPairingApproval(peerName: String, code: String) async -> Bool {
        await withCheckedContinuation { continuation in
            // A second request while one prompt is up declines immediately
            // rather than replacing the visible code — swapping the code out
            // from under a user mid-read is how a legitimate pairing fails.
            guard pendingPairing == nil else {
                continuation.resume(returning: false)
                return
            }
            pendingPairing = PendingPairingPrompt(peerName: peerName, code: code) { [weak self] approved in
                self?.pendingPairing = nil
                continuation.resume(returning: approved)
            }
        }
    }

    // MARK: - Device description

    private static func deviceName() -> String {
        UIDevice.current.name
    }

    private static func sourceDevice() -> SourceDevice {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #if os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "iOS"
        #endif
        return SourceDevice(name: deviceName(), platform: platform, appVersion: version)
    }

    /// Device-type code for the browse list's glyph.
    private static func deviceTypeCode() -> String {
        #if os(tvOS)
        return "tv"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "pd" : "ip"
        #endif
    }

    /// Continuity rides the upload server's listener, so this is that server's
    /// port. Falls back to 80 only for the advertisement — a peer that cannot
    /// reach it gets a clear connection failure rather than silence.
    private static func serverPort() -> Int {
        PVWebServer.shared.url?.port ?? 80
    }

    /// How long to wait for the web server's listener to bind before giving up
    /// on a handoff. Generous enough for a cold start, short enough that a user
    /// staring at the pause menu gets an answer.
    private static let serverBindTimeout: TimeInterval = 5
    private static let serverBindPollInterval: UInt64 = 100_000_000 // 100 ms

    /// Polls until the server reports a URL, or the timeout expires (nil).
    private static func awaitServerURLCandidates() async -> [URL]? {
        let deadline = Date().addingTimeInterval(serverBindTimeout)
        while Date() < deadline {
            let candidates = serverURLCandidates()
            if !candidates.isEmpty { return candidates }
            try? await Task.sleep(nanoseconds: serverBindPollInterval)
        }
        return nil
    }

    private static func serverURLCandidates() -> [URL] {
        var candidates: [URL] = []
        if let url = PVWebServer.shared.url { candidates.append(url) }
        if let bonjour = PVWebServer.shared.bonjourSeverURL, !candidates.contains(bonjour) {
            candidates.append(bonjour)
        }
        return candidates
    }
}

// MARK: - Cross-actor path box

/// A single mutable path shared between the main actor (which sets it when a
/// handoff begins) and the session server's actor (which reads it while
/// building a manifest).
private final class ServedGamePathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - Approval bridge

/// Adapts the actor-isolated approval protocol to the main-actor manager.
///
/// A separate `Sendable` type rather than a conformance on `ContinuityManager`
/// itself: the pairing server calls this from its own actor, and making the
/// manager conform would drag `@MainActor` isolation into a protocol the kit
/// deliberately keeps free of it.
private struct PairingApprovalBridge: ContinuityPairingApproving {
    let manager: ContinuityManager

    func approvePairing(peerName: String, code: String) async -> Bool {
        await manager.awaitPairingApproval(peerName: peerName, code: code)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a continuity session opens. Observed by
    /// `WebServerLifecycleService`, which must keep the server reachable for as
    /// long as one is live even though a game is running.
    static let continuitySessionDidBegin = Notification.Name(ContinuityNotificationNames.sessionDidBegin)
    /// Posted when the last continuity session closes.
    static let continuitySessionDidEnd = Notification.Name(ContinuityNotificationNames.sessionDidEnd)
}

/// The single definition of each notification string, so posters and observers
/// cannot drift (see the "no magic strings" convention in CLAUDE.md).
enum ContinuityNotificationNames {
    static let sessionDidBegin = "DOLContinuitySessionDidBeginNotification"
    static let sessionDidEnd = "DOLContinuitySessionDidEndNotification"
}
