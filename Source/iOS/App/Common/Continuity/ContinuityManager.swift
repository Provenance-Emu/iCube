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
    /// Whether this device offers its library to paired peers. Off until the
    /// user opts in — a host that has not opted in serves nothing, not even an
    /// auth challenge.
    @Published private(set) var sharesLibrary: Bool = UserDefaults.standard
        .bool(forKey: ContinuityDefaultsKeys.sharesLibrary)
    /// A peer waiting to be told whether it may copy a game, with the answer
    /// the owner gives. nil when nothing is pending.
    @Published private(set) var pendingLibraryPull: PendingLibraryPullPrompt?
    /// Every remembered per-peer library decision, for the review-and-revoke
    /// list. Refreshed whenever grants change.
    @Published private(set) var libraryGrants: [String: ContinuityLibraryGrant] = [:]

    struct PendingPairingPrompt: Identifiable {
        let id = UUID()
        let peerName: String
        let code: String
        let respond: (Bool) -> Void
    }

    /// A peer asking to copy one game off this device.
    ///
    /// This — not the browse — is `.askPerGame`'s control point. Re-asking on
    /// every browse would train the owner to dismiss the prompt reflexively,
    /// which is exactly what would make this one worthless.
    struct PendingLibraryPullPrompt: Identifiable {
        let id = UUID()
        let peerName: String
        let gameName: String
        let respond: (ContinuityLibraryPullDecision) -> Void
    }

    // MARK: - Owned components

    private(set) var identity: ContinuityPeerIdentity
    let trustStore: FileTrustStore
    let grantStore: FileLibraryGrantStore

    private var sessionServer: ContinuitySessionServer?
    private var pairingServer: ContinuityPairingServer?
    private var libraryServer: ContinuityLibraryServer?
    private var advertiser: ContinuityBonjourAdvertiser?
    /// True while this device holds a `sessionDidBegin` on behalf of library
    /// sharing — i.e. it has told `WebServerLifecycleService` to keep the
    /// listener up. Tracked separately from `advertiser` because the two have
    /// different lifetimes: a handoff replaces the Bonjour RECORD without
    /// releasing the lifecycle HOLD, and `WebServerLifecyclePolicy` counts
    /// begin/end notifications, so an unbalanced pair unbinds the socket.
    private var holdsLibraryServerSession = false
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

        // Nearby library sharing. Its own server, not a mode on the session
        // one, for two reasons: there is no session when a library is browsed
        // (the session routes would 404 forever), and grants are per-peer, so
        // the server has to know who is asking — which a single shared session
        // token structurally cannot say. See `ContinuityLibraryServer`.
        let libraryServer = ContinuityLibraryServer(
            identity: identity,
            libraryProvider: ICubeLibraryProvider(),
            trustStore: trustStore,
            grantStore: grantStore,
            approver: LibraryPullApprovalBridge(manager: self),
            sourceDevice: Self.sourceDevice(),
            // Read live, so turning the switch off in Settings takes effect on
            // a peer's very next request rather than at next launch.
            sharesLibraryProvider: { [weak self] in
                await MainActor.run { self?.sharesLibrary ?? false }
            }
        )
        self.libraryServer = libraryServer

        Task {
            await sessionServer.activate(on: registrar)
            await pairingServer.activate(on: registrar)
            await libraryServer.activate(on: registrar)
            await self.refreshTrustedPeers()
            await self.refreshLibraryGrants()
            // A host that opted in should be findable from launch, not only
            // after it hands a game off.
            await self.refreshLibraryAdvertising()
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

        // One Bonjour record at a time. A handoff advert is strictly more
        // informative than a library-presence one (it names the game in
        // progress and still carries `sharesLibrary`), so the handoff replaces
        // it and `endHandoff` puts the library advert back.
        //
        // The record is withdrawn WITHOUT posting `sessionDidEnd`. The policy
        // in `WebServerLifecycleService` counts these notifications, so posting
        // an end here would take the count to zero, stop the listener, and the
        // begin below would have to bind it again — leaving `beginHandoff` to
        // race its own 5-second poll and, on a slow bind, tell the user the
        // server could not start on a device that was reachable a moment ago.
        await withdrawAdvertisement()

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
            sharesLibrary: sharesLibrary,
            peerId: self.identity.id,
            deviceType: Self.deviceTypeCode()
        ))
    }

    /// Closes the session, withdraws the advertisement and lets the web server
    /// go back to its normal lifecycle.
    func endHandoff() async {
        await withdrawAdvertisement()
        await sessionServer?.endSession()
        servedGameFilePath.value = nil
        if activeSession != nil {
            activeSession = nil
            NotificationCenter.default.post(name: .continuitySessionDidEnd, object: nil)
        }
        // Fall back to the library-presence advert, if the user shares. A
        // device that shares its library should not become invisible just
        // because it finished handing a game off.
        await refreshLibraryAdvertising()
    }

    // MARK: - Ecosystem share (Provenance and other sibling apps)

    /// Begins a short-lived session serving one game's files to a sibling
    /// ecosystem app (e.g. Provenance) after a `dolphinios://requestGame` ask
    /// the user approved, or a "Send to Provenance" tap.
    ///
    /// Unlike `beginHandoff`, this never touches Bonjour: the peer is handed a
    /// reachable URL directly in the `fetch` callback, so there is nothing to
    /// discover on the LAN, and a Bonjour record would only advertise a
    /// same-device transfer to every other device on the network for no
    /// reason. It reuses the same one-session-at-a-time slot as a handoff
    /// (`sessionServer`, `activeSession`) — this device only ever serves one
    /// thing at a time, whichever peer asked most recently.
    ///
    /// Returns the session plus the base URLs the peer should try, or nil when
    /// the game can't be resolved/identified or the web server never came up.
    func beginEcosystemShare(gameID: String) async -> (session: ContinuitySessionInfo, urlCandidates: [URL])? {
        guard let sessionServer else { return nil }
        let items = TVLibraryBridge.currentGames()
        guard let item = items.first(where: { $0.gameID == gameID }), !item.isDemoItem else { return nil }

        let identity = GameIdentity(gameItem: item)
        guard identity.hasAnyIdentifier else { return nil }

        await withdrawAdvertisement()
        servedGameFilePath.value = item.filePath
        let session = await sessionServer.beginSession(game: identity)
        activeSession = session
        lastError = nil
        NotificationCenter.default.post(name: .continuitySessionDidBegin, object: nil)

        guard let candidates = await Self.awaitServerURLCandidates(), !candidates.isEmpty else {
            await endHandoff()
            return nil
        }
        return (session, candidates)
    }

    /// Ends an ecosystem share session, but only if it is still the current
    /// one — a newer session (another share, or a real handoff) may already
    /// have replaced it, and ending THAT one out from under it on a stale
    /// timer would be a bug, not a cleanup.
    func endEcosystemShareIfCurrent(sessionId: String) async {
        guard activeSession?.sessionId == sessionId else { return }
        await endHandoff()
    }

    // MARK: - Nearby library sharing

    /// Turns library sharing on or off.
    ///
    /// Persisted immediately and read live by the library server, so switching
    /// it off stops serving on a peer's very next request — there is no cached
    /// copy to go stale.
    func setSharesLibrary(_ shares: Bool) async {
        guard shares != sharesLibrary else { return }
        sharesLibrary = shares
        UserDefaults.standard.set(shares, forKey: ContinuityDefaultsKeys.sharesLibrary)
        if !shares {
            // Nothing is being served any more, so no token should still be
            // able to ask. Dropping them stops an in-flight transfer rather
            // than letting it run to completion after the user said stop.
            await libraryServer?.forgetAllPeers()
        }
        await refreshLibraryAdvertising()
    }

    func refreshLibraryGrants() async {
        libraryGrants = await grantStore.allGrants()
    }

    /// Records (or changes) what one peer may do with this device's library.
    ///
    /// `.denied` additionally drops the peer's live token and any cached pull
    /// approvals, so "Don't Share" is immediate rather than next-launch.
    func setLibraryGrant(_ grant: ContinuityLibraryGrant, forPeerId peerId: String) async {
        await grantStore.setGrant(grant, forPeerId: peerId)
        if grant == .denied { await libraryServer?.forgetPeer(peerId) }
        await refreshLibraryGrants()
    }

    /// Forgets a remembered decision, putting the peer back to the default
    /// (`.askPerGame`). This is the undo for a mis-tapped "Don't Share" — a
    /// persisted no with no way to reverse it would kill the feature for that
    /// peer with no recovery short of reinstalling.
    func clearLibraryGrant(forPeerId peerId: String) async {
        await grantStore.removeGrant(forPeerId: peerId)
        await libraryServer?.forgetPeer(peerId)
        await refreshLibraryGrants()
    }

    /// Display name for a peer id, for the grant review list. Falls back to the
    /// raw id for a grant whose peer has since been forgotten — which is
    /// exactly the row a user needs to see in order to clear it.
    func displayName(forPeerId peerId: String) -> String {
        trustedPeers.first { $0.id == peerId }?.name ?? peerId
    }

    // MARK: - Library advertising

    /// Publishes, or withdraws, the library-presence advert.
    ///
    /// A library-presence advert has `game: nil` — the app is open and sharing,
    /// but nothing is being played, so a browsing device must not offer to
    /// "continue" anything.
    ///
    /// It posts the same session-began/ended notifications a handoff does,
    /// because it needs the same thing from `WebServerLifecycleService`: the
    /// server has to be running and stay running. Without that, a user who
    /// switches sharing on and then boots a game becomes unreachable the moment
    /// emulation starts, which is a green build and a dead feature.
    private func refreshLibraryAdvertising() async {
        guard activeSession == nil else { return }  // a handoff advert wins
        if sharesLibrary {
            await startAdvertisingLibrary()
        } else {
            await stopAdvertisingLibrary()
        }
    }

    private func startAdvertisingLibrary() async {
        guard sharesLibrary, activeSession == nil else { return }
        if !holdsLibraryServerSession {
            holdsLibraryServerSession = true
            NotificationCenter.default.post(name: .continuitySessionDidBegin, object: nil)
        }
        // Already publishing. The hold above is idempotent and the record does
        // not need replacing, so there is nothing else to do.
        guard advertiser == nil else { return }

        guard let candidates = await Self.awaitServerURLCandidates(), !candidates.isEmpty else {
            lastError = L("Couldn't start the local server, so other devices can't see this library. Check that Wi-Fi is on.")
            await stopAdvertisingLibrary()
            return
        }
        let advertiser = ContinuityBonjourAdvertiser(port: Self.serverPort())
        self.advertiser = advertiser
        await advertiser.publish(ContinuityAdvertisement(
            sessionId: UUID().uuidString,
            token: "",
            game: nil,
            urlCandidates: candidates,
            sharesLibrary: true,
            peerId: identity.id,
            deviceType: Self.deviceTypeCode()
        ))
    }

    /// Stops sharing entirely: withdraws the record AND releases the lifecycle
    /// hold, letting the server go back to its normal stop-during-emulation
    /// behaviour.
    private func stopAdvertisingLibrary() async {
        await withdrawAdvertisement()
        guard holdsLibraryServerSession else { return }
        holdsLibraryServerSession = false
        NotificationCenter.default.post(name: .continuitySessionDidEnd, object: nil)
    }

    /// Takes the Bonjour record down without touching the lifecycle hold.
    ///
    /// The split matters: a handoff replaces the record while sharing stays on,
    /// and releasing the hold in between would stop and restart the listener
    /// for no reason. See the call site in `beginHandoff`.
    private func withdrawAdvertisement() async {
        await advertiser?.withdraw()
        advertiser = nil
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
        // Drop the peer's library token and cached pull approvals too, or a
        // transfer already under way would run to completion after the user
        // forgot the device.
        await libraryServer?.forgetPeer(peerId)
        await refreshTrustedPeers()
        await refreshLibraryGrants()
    }

    func revokeAllTrust() async {
        await trustStore.removeAll()
        await grantStore.removeAll()
        await libraryServer?.forgetAllPeers()
        await refreshTrustedPeers()
        await refreshLibraryGrants()
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

    /// Presents the per-pull approval prompt and suspends until the user
    /// answers. The library server races this against its own timeout, so an
    /// unanswered prompt resolves as a decline rather than wedging the seam.
    fileprivate func awaitLibraryPullApproval(
        peerName: String, gameName: String
    ) async -> ContinuityLibraryPullDecision {
        await withCheckedContinuation { continuation in
            // A second request while one prompt is up is declined for now
            // rather than replacing the visible one. `.denyOnce` and not
            // `.denyAlways`: the peer did nothing wrong, it was merely second
            // in the queue, and it must be able to ask again.
            guard pendingLibraryPull == nil else {
                continuation.resume(returning: .denyOnce)
                return
            }
            pendingLibraryPull = PendingLibraryPullPrompt(
                peerName: peerName, gameName: gameName
            ) { [weak self] decision in
                self?.pendingLibraryPull = nil
                if decision == .allowAlways || decision == .denyAlways {
                    Task { await self?.refreshLibraryGrants() }
                }
                continuation.resume(returning: decision)
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

/// The same adaptation for the per-pull prompt.
private struct LibraryPullApprovalBridge: ContinuityLibraryPullApproving {
    let manager: ContinuityManager

    func approveLibraryPull(
        peerName: String, gameName: String
    ) async -> ContinuityLibraryPullDecision {
        await manager.awaitLibraryPullApproval(peerName: peerName, gameName: gameName)
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

/// `UserDefaults` keys continuity owns. One definition each, for the same
/// reason the notification names have one (see CLAUDE.md's no-magic-strings
/// convention): a key mistyped at one of two call sites is a setting that
/// silently never takes effect.
enum ContinuityDefaultsKeys {
    /// Bool. Absent is false — sharing is opt-in, so an upgrading user who has
    /// never seen the switch shares nothing.
    static let sharesLibrary = "continuity_shares_library"
}
