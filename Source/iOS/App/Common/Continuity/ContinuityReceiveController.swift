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
    private let transport: any ContinuityTransport
    private let fileProvider: any ContinuityFileProviding
    private let library: any LibraryQuerying

    /// A pairing begun by `receive(from:)` and waiting for a code. Held so the
    /// UI can hand the typed code back.
    private var pendingHandle: ContinuityPairingClient.PairingHandle?
    private var pairingClient: ContinuityPairingClient?

    init(
        identity: ContinuityPeerIdentity,
        transport: any ContinuityTransport = URLSessionContinuityTransport(),
        fileProvider: any ContinuityFileProviding = ICubeContinuityFileProvider(currentGameFilePath: { nil }),
        library: any LibraryQuerying = ICubeLibraryQuery()
    ) {
        self.identity = identity
        self.transport = transport
        self.fileProvider = fileProvider
        self.library = library
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
                await beginPairing(with: client, baseURL: baseURL)
                return
            } catch {
                phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
                return
            }
        }

        await pullAndBoot(baseURL: baseURL, token: token)
    }

    // MARK: - Pairing

    private func beginPairing(with client: ContinuityPairingClient, baseURL: URL) async {
        do {
            pendingHandle = try await client.beginPairing(baseURL: baseURL)
            phase = .awaitingPairing
        } catch {
            phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
        }
    }

    /// Submits the 6-digit code the user read off the other device and, on
    /// success, continues straight into the pull.
    func submitPairingCode(_ code: String) async {
        guard let handle = pendingHandle, let client = pairingClient else { return }
        phase = .authenticating
        do {
            let token = try await client.completePairing(handle, code: code)
            pendingHandle = nil
            await pullAndBoot(baseURL: handle.baseURL, token: token)
        } catch ContinuityError.tokenRejected {
            // Wrong code, and the pairing is still alive: stay in the prompt so
            // the user can try again rather than restarting discovery.
            phase = .awaitingPairing
        } catch {
            pendingHandle = nil
            phase = .finished(.failed(error as? ContinuityError ?? .serverUnreachable(detail: nil)))
        }
    }

    func cancel() {
        pendingHandle = nil
        pairingClient = nil
        phase = .finished(.failed(.cancelled))
    }

    // MARK: - Pull

    private func pullAndBoot(baseURL: URL, token: String) async {
        let puller = ContinuityPuller(transport: transport, fileProvider: fileProvider)

        phase = .fetchingManifest
        let manifest: ContinuityManifest
        do {
            manifest = try await puller.mintAndFetchManifest(baseURL: baseURL, token: token)
        } catch {
            await finish(
                stage: .fetchingManifest,
                error: error as? ContinuityError ?? .serverUnreachable(detail: nil),
                identity: nil,
                pulled: .nothing
            )
            return
        }

        let plan = await puller.makePlan(for: manifest)
        do {
            try await puller.execute(plan: plan, baseURL: baseURL, token: token) { [weak self] progress in
                Task { @MainActor in self?.phase = .pulling(progress) }
            }
        } catch let failure as PullFailure {
            await finish(
                stage: .pulling,
                error: failure.underlying,
                identity: manifest.game,
                pulled: failure.pulledArtifacts
            )
            return
        } catch {
            await finish(
                stage: .pulling,
                error: .serverUnreachable(detail: String(describing: error)),
                identity: manifest.game,
                pulled: .nothing
            )
            return
        }

        // Everything arrived. The ladder still runs — it is the one place that
        // decides what to boot, and a clean pull is simply its top rung.
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

    // MARK: - Outcome

    private func finish(
        stage: ContinuityFallbackMachine.Stage,
        error: ContinuityError,
        identity: GameIdentity?,
        pulled: ContinuityFallbackMachine.PulledArtifacts,
        manifest: ContinuityManifest? = nil
    ) async {
        let local: ContinuityFallbackMachine.LocalCapability
        if let identity, let match = await library.resolveLocalGame(identity) {
            local = .gameAvailable(hasLocalSaveState: match.hasLocalSaveState)
        } else {
            local = .gameMissing
        }

        let outcome = ContinuityFallbackMachine.outcome(
            failedAt: stage, error: error, local: local, pulled: pulled
        )
        phase = .finished(outcome)

        await apply(outcome, identity: identity, manifest: manifest)
    }

    /// Turns the ladder's answer into an actual boot.
    ///
    /// `.failed` deliberately does nothing here: the UI shows the reason. There
    /// is no "boot something anyway" branch, because booting the wrong thing
    /// after telling the user a handoff failed is worse than not booting.
    private func apply(
        _ outcome: ContinuityOutcome,
        identity: GameIdentity?,
        manifest: ContinuityManifest?
    ) async {
        guard let identity, let match = await library.resolveLocalGame(identity) else { return }
        let absolutePath = ContinuityPaths.absoluteURL(forRelativePath: match.gameRelativePath).path

        switch outcome {
        case .proceedWithPulledState, .proceedWithPulledStatePartial:
            if let statePath = manifest?.saveState?.relativePath {
                SaveStateService.pendingBootStatePath =
                    ContinuityPaths.absoluteURL(forRelativePath: statePath).path
            }
            TVEmulationBridge.launchGame(atPath: absolutePath)
        case .bootWithLatestLocalState:
            // Leave `pendingBootStatePath` unset: the ordinary resume path picks
            // the newest local state, which is exactly this rung's meaning.
            SaveStateService.pendingBootStatePath = nil
            TVEmulationBridge.launchGame(atPath: absolutePath)
        case .bootFresh:
            SaveStateService.pendingBootStatePath = nil
            SaveStateService.skipResumeOnce = true
            TVEmulationBridge.launchGame(atPath: absolutePath)
        case .failed:
            break
        }
    }
}
