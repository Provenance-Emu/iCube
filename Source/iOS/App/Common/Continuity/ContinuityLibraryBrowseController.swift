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
        case browsing([ContinuityLibraryEntry])
        /// Copying one title. `entry` is what the progress line names.
        case copying(entry: ContinuityLibraryEntry, progress: PullProgress?)
        case copied(ContinuityLibraryEntry)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Cover art, keyed by catalog key. Fetched lazily per visible row.
    @Published private(set) var artwork: [String: Data] = [:]

    private let client: ContinuityLibraryClient
    private let fileProvider: any ContinuityFileProviding
    private var baseURL: URL?

    init(
        identity: ContinuityPeerIdentity,
        transport: any ContinuityTransport = URLSessionContinuityTransport(),
        fileProvider: any ContinuityFileProviding = ICubeContinuityFileProvider(currentGameFilePath: { nil })
    ) {
        self.client = ContinuityLibraryClient(identity: identity, transport: transport)
        self.fileProvider = fileProvider
    }

    // MARK: - Browsing

    func load(from advertisement: ContinuityAdvertisement) async {
        guard let baseURL = advertisement.urlCandidates.first else {
            phase = .failed(L("That device didn't say how to reach it."))
            return
        }
        self.baseURL = baseURL
        phase = .loading
        do {
            let catalog = try await client.catalog(from: baseURL)
            phase = .browsing(catalog.entries)
        } catch ContinuityError.notPaired {
            // The host answers "not paired" for a genuinely unknown device, for
            // one it has marked Don't Share, and for one that simply is not
            // sharing. It deliberately does not distinguish them on the wire,
            // so this message must not claim to know which.
            phase = .failed(L("That device isn't sharing its library with this one."))
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Fetches one cover, once. A missing cover is a placeholder, never an
    /// error the user sees.
    func loadArtwork(for entry: ContinuityLibraryEntry) async {
        guard entry.hasArtwork, artwork[entry.key] == nil, let baseURL else { return }
        if let data = await client.artwork(from: baseURL, key: entry.key) {
            artwork[entry.key] = data
        }
    }

    // MARK: - Copying

    func copy(_ entry: ContinuityLibraryEntry) async {
        guard let baseURL else { return }
        phase = .copying(entry: entry, progress: nil)

        do {
            let token = try await client.token(for: baseURL)
            let manifest = try await client.manifest(from: baseURL, key: entry.key)
            let puller = await client.puller(forKey: entry.key, fileProvider: fileProvider)
            let plan = await puller.makePlan(for: manifest)

            if plan.isNoOp {
                // Already on disk with a matching checksum. Saying "copied" is
                // honest and is what the user wanted to be true.
                phase = .copied(entry)
                return
            }

            try await puller.execute(plan: plan, baseURL: baseURL, token: token) { [weak self] progress in
                Task { @MainActor in self?.phase = .copying(entry: entry, progress: progress) }
            }
            registerInLibrary(manifest)
            phase = .copied(entry)
        } catch let failure as PullFailure {
            // The partial `.part` file stays on disk: `ContinuityPuller` only
            // discards it on a checksum failure, so a retry resumes rather
            // than starting the gigabytes again.
            phase = .failed(Self.describe(failure.underlying))
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// A freshly pulled disc image is not in the library cache yet, so without
    /// this the game would be on disk and invisible.
    private func registerInLibrary(_ manifest: ContinuityManifest) {
        guard let relative = manifest.allDescriptors.first(where: { $0.kind == .gameFile })?.relativePath else {
            return
        }
        let absolute = ContinuityPaths.absoluteURL(forRelativePath: relative).path
        guard FileManager.default.fileExists(atPath: absolute) else { return }
        TVLibraryBridge.updateLibrary(withRemotePaths: [absolute], fetchMetadata: true)
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
