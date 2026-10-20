// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// Drives the browsing half of nearby library sharing: authenticate, list the
/// peer's games, and copy one.
///
/// Deliberately **not** folded into `ContinuityReceiveController`. That type
/// ends every path in `ContinuityFallbackMachine`'s verdict, because a handoff
/// is about resuming at a point and the interesting question is what to do when
/// the save state does not arrive. A library copy has no save state to lose: it
/// either lands a disc image or it does not, and dressing that up in the
/// ladder's vocabulary ("starting from your most recent save instead") would be
/// a lie about what just happened.
@MainActor
final class ContinuityLibraryBrowseController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case awaitingPairing
        case browsing([ContinuityLibraryEntry])
        /// Copying one title. `entry` is what the progress line names.
        case copying(entry: ContinuityLibraryEntry, progress: PullProgress?)
        case copied(ContinuityLibraryEntry)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Verified primary file registered by the last successful copy, including
    /// a matching file already on disk. Cleared before the next operation.
    private(set) var copiedFileURLs: [URL] = []
    private(set) var verifiedDescriptors: [FileDescriptor] = []
    var copiedFileURL: URL? { copiedFileURLs.first }
    /// Cover art, keyed by catalog key. Fetched lazily per visible row.
    @Published private(set) var artwork: [String: Data] = [:]

    private let boundTransport: PeerBoundContinuityTransport
    private let client: ContinuityLibraryClient
    private let pairingClient: ContinuityPairingClient
    private let fileProvider: any ContinuityFileProviding
    private let didPair: @MainActor (ContinuityPairingClient.PairingHandle) async -> Void
    private var baseURL: URL?
    private var expectedPeerID: String?
    private var pendingPairing: ContinuityPairingClient.PairingHandle?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    init(
        identity: ContinuityPeerIdentity,
        transport: any ContinuityTransport = ICubeContinuityTransport(),
        fileProvider: any ContinuityFileProviding = ICubeContinuityFileProvider(currentGameFilePath: { nil }),
        didPair: @escaping @MainActor (ContinuityPairingClient.PairingHandle) async -> Void = {
            await ContinuityManager.shared.rememberPairedHost($0)
        }
    ) {
        let bound = PeerBoundContinuityTransport(base: transport)
        self.boundTransport = bound
        self.client = ContinuityLibraryClient(identity: identity, transport: bound)
        self.pairingClient = ContinuityPairingClient(identity: identity, transport: bound)
        self.fileProvider = fileProvider
        self.didPair = didPair
    }

    // MARK: - Browsing

    func load(from advertisement: ContinuityAdvertisement, allowsPairing: Bool = true) async {
        await runOperation { await self.loadCatalog(from: advertisement, allowsPairing: allowsPairing) }
    }

    private func loadCatalog(from advertisement: ContinuityAdvertisement, allowsPairing: Bool) async {
        copiedFileURLs = []
        verifiedDescriptors = []
        pendingPairing = nil
        expectedPeerID = advertisement.peerId
        boundTransport.setExpectedPeerID(advertisement.peerId)
        guard let baseURL = advertisement.urlCandidates.first else {
            phase = .failed(L("That device didn't say how to reach it."))
            return
        }
        self.baseURL = baseURL
        phase = .loading
        do {
            // A reused endpoint/token must not bypass a newly selected peer ID.
            await client.invalidateToken(for: baseURL)
            try Task.checkCancellation()
            let catalog = try await client.catalog(from: baseURL)
            guard !Task.isCancelled else { return }
            phase = .browsing(catalog.entries)
        } catch ContinuityError.notPaired {
            // The host answers "not paired" for a genuinely unknown device, for
            // one it has marked Don't Share, and for one that simply is not
            // sharing. It deliberately does not distinguish them on the wire,
            // so this message must not claim to know which.
            guard !Task.isCancelled else { return }
            guard allowsPairing else {
                phase = .failed(Self.describe(ContinuityError.notPaired))
                return
            }
            do {
                let handle = try await pairingClient.beginPairing(baseURL: baseURL)
                guard !Task.isCancelled else { return }
                try validateServer(handle)
                pendingPairing = handle
                phase = .awaitingPairing
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.describe(error))
        }
    }

    /// Pairing can succeed while the host has no handoff session. Its legacy
    /// 404 means trust was saved; library auth must then use its own token.
    func submitPairingCode(_ code: String) async {
        guard let handle = pendingPairing else { return }
        await runOperation {
            self.phase = .loading
            do {
                try self.validateServer(handle)
                do {
                    _ = try await self.pairingClient.completePairing(handle, code: code)
                } catch ContinuityError.noActiveSession {
                    // Paired, with no active game. This is normal for a library.
                }
                guard !Task.isCancelled else { return }
                self.pendingPairing = nil
                await self.didPair(handle)
                guard !Task.isCancelled else { return }
                await self.client.invalidateToken(for: handle.baseURL)
                let catalog = try await self.client.catalog(from: handle.baseURL)
                guard !Task.isCancelled else { return }
                self.phase = .browsing(catalog.entries)
            } catch ContinuityError.tokenRejected {
                guard !Task.isCancelled else { return }
                self.phase = .awaitingPairing
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingPairing = nil
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func validateServer(_ handle: ContinuityPairingClient.PairingHandle) throws {
        guard expectedPeerID == nil || expectedPeerID == handle.serverId else {
            throw ContinuityError.tokenRejected
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        operationID = UUID()
        pendingPairing = nil
        copiedFileURLs = []
        verifiedDescriptors = []
        phase = .failed(Self.describe(ContinuityError.cancelled))
    }

    private func runOperation(_ body: @escaping @MainActor () async -> Void) async {
        operation?.cancel()
        let id = UUID()
        operationID = id
        let task = Task {
            guard !Task.isCancelled else { return }
            await body()
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if operationID == id { operation = nil }
    }

    /// Fetches one cover, once. A missing cover is a placeholder, never an
    /// error the user sees.
    func loadArtwork(for entry: ContinuityLibraryEntry) async {
        guard entry.hasArtwork, artwork[entry.key] == nil, let baseURL else { return }
        if let data = await client.artwork(from: baseURL, key: entry.key) {
            artwork[entry.key] = data
        }
    }

    /// A catalog does not contain content hashes. Mirrors must fetch a current,
    /// ROM-only manifest before considering a prior verified receipt reusable.
    func validatedManifest(for entry: ContinuityLibraryEntry) async throws -> ContinuityManifest {
        guard let baseURL else { throw ContinuityError.cancelled }
        let manifest = try await client.manifest(from: baseURL, key: entry.key)
        try Task.checkCancellation()
        guard manifest.saveState == nil, !manifest.files.isEmpty,
              manifest.game.stableKey == entry.game.stableKey,
              manifest.files.allSatisfy({ $0.kind == .gameFile }),
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    // MARK: - Copying

    func copy(_ entry: ContinuityLibraryEntry) async {
        await runOperation { await self.copyEntry(entry) }
    }

    private func copyEntry(_ entry: ContinuityLibraryEntry) async {
        guard let baseURL else { return }
        let id = operationID
        copiedFileURLs = []
        verifiedDescriptors = []
        phase = .copying(entry: entry, progress: nil)

        do {
            let token = try await client.token(for: baseURL)
            let manifest = try await validatedManifest(for: entry)
            let puller = await client.puller(forKey: entry.key, fileProvider: fileProvider)
            try await ContinuityTransferGate.shared.withPermit {
                // Re-plan after acquiring the lease: a manual copy or mirror
                // may have completed this same destination while we waited.
                let plan = await puller.makePlan(for: manifest)
                try Task.checkCancellation()
                try await puller.execute(plan: plan, baseURL: baseURL, token: token) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.operationID == id,
                              case .copying = self.phase else { return }
                        self.phase = .copying(entry: entry, progress: progress)
                    }
                }
                try Task.checkCancellation()
                // No-op plans still register an existing checksum-matching image.
                copiedFileURLs = try await registerInLibrary(manifest)
                verifiedDescriptors = manifest.files
                phase = .copied(entry)
            }
        } catch let failure as PullFailure {
            guard !Task.isCancelled else { return }
            // The partial `.part` file stays on disk: `ContinuityPuller` only
            // discards it on a checksum failure, so a retry resumes rather
            // than starting the gigabytes again.
            phase = .failed(Self.describe(failure.underlying))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.describe(error))
        }
    }

    /// A freshly pulled disc image is not in the library cache yet, so without
    /// this the game would be on disk and invisible.
    private func registerInLibrary(_ manifest: ContinuityManifest) async throws -> [URL] {
        var destinations: [URL] = []
        for descriptor in manifest.files where descriptor.kind == .gameFile {
            let url = try await fileProvider.destinationURL(for: descriptor)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            destinations.append(url)
        }
        guard !destinations.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        try Task.checkCancellation()
        TVLibraryBridge.updateLibrary(withRemotePaths: destinations.map(\.path), fetchMetadata: true)
        return destinations
    }

    // MARK: - Messages

    /// Every failure gets a sentence a user can act on. A shrug is not an
    /// option: the whole point of this feature's error handling is that a
    /// transfer that did not happen says so.
    private static func describe(_ error: Error) -> String {
        guard let continuityError = error as? ContinuityError else {
            return String(describing: error)
        }
        switch continuityError {
        case .notPaired:
            return L("That device isn't sharing its library with this one.")
        case .tokenRejected:
            return L("That device stopped sharing partway through. Nothing was copied.")
        case .cancelled:
            return L("Cancelled.")
        case .invalidResponse(let status) where status == 403:
            return L("The other device declined the copy.")
        case .invalidResponse(let status) where status == 404:
            return L("That game isn't shared any more.")
        case .checksumMismatch:
            return L("The copy arrived damaged and was discarded. Try again.")
        default:
            return continuityError.localizedDescription
        }
    }
}
