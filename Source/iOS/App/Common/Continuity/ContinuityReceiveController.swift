// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// Drives the receiving half of a handoff: obtain a token, mint and fetch the
/// manifest, pull what is missing, then decide what to boot.
///
/// The decision at the end is **always** `ContinuityFallbackMachine`'s. This
/// type never invents an outcome, never silently gives up, and never reports
/// success it cannot back: every path out of `receive(from:)` ends in a
/// `ContinuityOutcome` the UI has to render, including `.failed`.
@MainActor
final class ContinuityReceiveController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case authenticating
        /// Waiting for the other user to approve a pairing. `code` is what this
        /// user must type in; nil until they have been given one.
        case awaitingPairing
        case fetchingManifest
        case pulling(PullProgress)
        case finished(ContinuityOutcome)
    }

    @Published private(set) var phase: Phase = .idle

    private let identity: ContinuityPeerIdentity
    private let transport: PeerBoundContinuityTransport
    private let fileProvider: any ContinuityFileProviding
    private let library: any LibraryQuerying
    private let didPair: @MainActor (ContinuityPairingClient.PairingHandle) async -> Void
    private var expectedPeerID: String?

    /// A pairing begun by `receive(from:)` and waiting for a code. Held so the
    /// UI can hand the typed code back.
    private var pendingHandle: ContinuityPairingClient.PairingHandle?
    private var pairingClient: ContinuityPairingClient?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    init(
        identity: ContinuityPeerIdentity,
        transport: any ContinuityTransport = ICubeContinuityTransport(),
        fileProvider: any ContinuityFileProviding = ICubeContinuityFileProvider(currentGameFilePath: { nil }),
        library: any LibraryQuerying = ICubeLibraryQuery(),
        didPair: @escaping @MainActor (ContinuityPairingClient.PairingHandle) async -> Void = {
            await ContinuityManager.shared.rememberPairedHost($0)
        }
    ) {
        self.identity = identity
        self.transport = PeerBoundContinuityTransport(base: transport)
        self.fileProvider = fileProvider
        self.library = library
        self.didPair = didPair
    }

    // MARK: - Entry point

    /// Continues the game a peer is advertising.
    ///
    /// Token acquisition ladder:
    ///   1. The advertisement carries one inline (the same-user Handoff path).
    ///   2. Silent trusted-peer auth, if this device has paired before.
    ///   3. Pairing — which needs the other user, so the flow parks in
    ///      `.awaitingPairing` and `submitPairingCode(_:)` resumes it.
    func receive(from advertisement: ContinuityAdvertisement) async {
        await runOperation { await self.performReceive(from: advertisement) }
    }

    private func performReceive(from advertisement: ContinuityAdvertisement) async {
        pendingHandle = nil
        expectedPeerID = advertisement.peerId
        transport.setExpectedPeerID(advertisement.peerId)
        guard let baseURL = advertisement.urlCandidates.first else {
            phase = .finished(.failed(.serverUnreachable(detail: "the other device advertised no address")))
            return
        }

        phase = .authenticating
        let token: String
        if !advertisement.token.isEmpty {
            token = advertisement.token
        } else {
            let client = ContinuityPairingClient(identity: identity, transport: transport)
            pairingClient = client
            do {
                token = try await client.authenticate(baseURL: baseURL)
            } catch ContinuityError.notPaired {
                guard !Task.isCancelled else { return }
                await beginPairing(with: client, baseURL: baseURL)
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
                return
            }
        }

        guard !Task.isCancelled else { return }
        await pullAndBoot(baseURL: baseURL, token: token)
    }

    // MARK: - Pairing

    private func beginPairing(with client: ContinuityPairingClient, baseURL: URL) async {
        do {
            let handle = try await client.beginPairing(baseURL: baseURL)
            guard !Task.isCancelled else { return }
            try validateServer(handle)
            pendingHandle = handle
            phase = .awaitingPairing
        } catch {
            guard !Task.isCancelled else { return }
            phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
        }
    }

    /// Submits the 6-digit code the user read off the other device and, on
    /// success, continues straight into the pull.
    func submitPairingCode(_ code: String) async {
        await runOperation { await self.completePairing(code) }
    }

    private func completePairing(_ code: String) async {
        guard let handle = pendingHandle, let client = pairingClient else { return }
        phase = .authenticating
        do {
            try validateServer(handle)
            let token: String
            do {
                token = try await client.completePairing(handle, code: code)
            } catch ContinuityError.noActiveSession {
                // Trust was approved even though the host is no longer
                // offering a game. Keep that peer for future library access.
                guard !Task.isCancelled else { return }
                pendingHandle = nil
                await didPair(handle)
                guard !Task.isCancelled else { return }
                phase = .finished(.failed(.noActiveSession))
                return
            }
            guard !Task.isCancelled else { return }
            pendingHandle = nil
            await didPair(handle)
            guard !Task.isCancelled else { return }
            await pullAndBoot(baseURL: handle.baseURL, token: token)
        } catch ContinuityError.tokenRejected {
            guard !Task.isCancelled else { return }
            // Wrong code, and the pairing is still alive: stay in the prompt so
            // the user can try again rather than restarting discovery.
            phase = .awaitingPairing
        } catch {
            guard !Task.isCancelled else { return }
            pendingHandle = nil
            phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
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
        pendingHandle = nil
        pairingClient = nil
        phase = .finished(.failed(.cancelled))
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

    // MARK: - Pull

    private func pullAndBoot(baseURL: URL, token: String) async {
        let id = operationID
        let puller = ContinuityPuller(transport: transport, fileProvider: fileProvider)

        phase = .fetchingManifest
        let manifest: ContinuityManifest
        do {
            manifest = try await puller.mintAndFetchManifest(baseURL: baseURL, token: token)
            guard !Task.isCancelled else { return }
        } catch {
            guard !Task.isCancelled else { return }
            await finish(
                stage: .fetchingManifest,
                error: error as? ContinuityError ?? .serverUnreachable(detail: nil),
                identity: nil,
                pulled: .nothing
            )
            return
        }

        do {
            try await ContinuityTransferGate.shared.withPermit {
                let plan = await puller.makePlan(for: manifest)
                try Task.checkCancellation()
                try await puller.execute(plan: plan, baseURL: baseURL, token: token) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        switch self.phase {
                        case .fetchingManifest, .pulling: break
                        default: return
                        }
                        self.phase = .pulling(progress)
                    }
                }
                try Task.checkCancellation()
                // Resolve and register before another local transfer takes
                // ownership of the same paths.
                await finish(
                    stage: .verifying,
                    error: .cancelled,
                    identity: manifest.game,
                    pulled: ContinuityFallbackMachine.PulledArtifacts(
                        saveStateUsable: manifest.saveState != nil,
                        requiredGameFilesComplete: true
                    ),
                    manifest: manifest
                )
            }
        } catch let failure as PullFailure {
            guard !Task.isCancelled else { return }
            await finish(
                stage: .pulling,
                error: failure.underlying,
                identity: manifest.game,
                pulled: failure.pulledArtifacts
            )
            return
        } catch {
            guard !Task.isCancelled else { return }
            await finish(
                stage: .pulling,
                error: .serverUnreachable(detail: String(describing: error)),
                identity: manifest.game,
                pulled: .nothing
            )
            return
        }
    }

    // MARK: - Outcome

    private func finish(
        stage: ContinuityFallbackMachine.Stage,
        error: ContinuityError,
        identity: GameIdentity?,
        pulled: ContinuityFallbackMachine.PulledArtifacts,
        manifest: ContinuityManifest? = nil
    ) async {
        // Resolved ONCE and passed down. Each resolution walks the whole
        // library on the main actor, and this used to happen twice per handoff.
        var localMatch: LocalGameMatch?
        if let identity {
            localMatch = await library.resolveLocalGame(identity)
        }
        guard !Task.isCancelled else { return }

        let local: ContinuityFallbackMachine.LocalCapability = localMatch.map {
            .gameAvailable(hasLocalSaveState: $0.hasLocalSaveState)
        } ?? .gameMissing

        var outcome = ContinuityFallbackMachine.outcome(
            failedAt: stage, error: error, local: local, pulled: pulled
        )

        // The boot path is resolved BEFORE the outcome is published, because a
        // non-failed outcome with nothing to boot is exactly the silent stub
        // this feature must never produce: the UI would say "starting where the
        // other device left off" and then nothing would happen.
        let bootPath = resolveBootPath(outcome: outcome, manifest: manifest, localMatch: localMatch)
        if bootPath == nil, !Self.isFailure(outcome) {
            // Do NOT overwrite an existing failure: the ladder's reason is more
            // specific than "game not found" and is what the user needs to see.
            outcome = .failed(.gameNotFoundLocally)
        }

        phase = .finished(outcome)
        if let bootPath {
            apply(outcome, bootPath: bootPath, manifest: manifest)
        }
    }

    /// Where the game to boot actually is.
    ///
    /// The manifest's own `gameFile` descriptor comes FIRST, because the case
    /// this feature exists for is a receiver that did not have the game: it has
    /// just pulled the disc image to the manifest's path, and asking the library
    /// cache about it would come back nil — the cache has not been rescanned
    /// since the file appeared. Falling back to the library match covers the
    /// receiver that already owned the game (its disc image may sit anywhere,
    /// including outside the User directory).
    private static func isFailure(_ outcome: ContinuityOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private func resolveBootPath(
        outcome: ContinuityOutcome,
        manifest: ContinuityManifest?,
        localMatch: LocalGameMatch?
    ) -> String? {
        guard !Self.isFailure(outcome) else { return nil }

        if let relative = manifest?.allDescriptors.first(where: { $0.kind == .gameFile })?.relativePath {
            guard let url = try? ContinuityPaths.validatedURL(forRelativePath: relative) else { return nil }
            let absolute = url.path
            if FileManager.default.fileExists(atPath: absolute) { return absolute }
        }
        return localMatch?.gameAbsolutePath
    }

    /// Turns the ladder's answer into an actual boot.
    ///
    /// `.failed` never reaches here: the UI shows the reason instead. There is
    /// no "boot something anyway" branch, because booting the wrong thing after
    /// telling the user a handoff failed is worse than not booting.
    private func apply(
        _ outcome: ContinuityOutcome,
        bootPath: String,
        manifest: ContinuityManifest?
    ) {
        // A freshly pulled disc image is not in the library cache yet, so the
        // library would not show it and — more importantly — the boot path has
        // to be known to the cache for the entry to behave like any other.
        TVLibraryBridge.updateLibrary(withRemotePaths: [bootPath], fetchMetadata: true)

        switch outcome {
        case .proceedWithPulledState, .proceedWithPulledStatePartial:
            if let statePath = manifest?.saveState?.relativePath,
               let url = try? ContinuityPaths.validatedURL(forRelativePath: statePath) {
                SaveStateService.pendingBootStatePath = url.path
            }
        case .bootWithLatestLocalState:
            // Leave `pendingBootStatePath` unset: the ordinary resume path picks
            // the newest local state, which is exactly this rung's meaning.
            SaveStateService.pendingBootStatePath = nil
        case .bootFresh:
            SaveStateService.pendingBootStatePath = nil
            SaveStateService.skipResumeOnce = true
        case .failed:
            return
        }
        TVEmulationBridge.launchGame(atPath: bootPath)
    }
}
