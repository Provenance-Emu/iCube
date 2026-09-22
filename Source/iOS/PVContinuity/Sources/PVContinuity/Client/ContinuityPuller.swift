// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a pull will actually transfer, computed by diffing a manifest against
/// what is already on disk.
public struct PullPlan: Sendable, Equatable {
    /// Files to download, already sorted smallest-and-most-essential first
    /// (see `ContinuityFileKind.pullPriority`), so a server that dies partway
    /// leaves the most usable partial payload.
    public var needed: [FileDescriptor]
    /// Manifest entries already present with matching checksums.
    public var alreadyPresent: [FileDescriptor]

    public init(needed: [FileDescriptor], alreadyPresent: [FileDescriptor]) {
        self.needed = needed
        self.alreadyPresent = alreadyPresent
    }

    public var totalBytesNeeded: Int64 {
        needed.reduce(0) { $0 + $1.size }
    }

    /// Nothing to transfer — the game and its state are already local.
    public var isNoOp: Bool { needed.isEmpty }
}

/// Progress snapshot delivered during `ContinuityPuller.execute`.
public struct PullProgress: Sendable, Equatable {
    public var currentFile: FileDescriptor
    public var completedFiles: Int
    public var totalFiles: Int
    public var bytesTransferred: Int64
    public var totalBytes: Int64

    public init(
        currentFile: FileDescriptor,
        completedFiles: Int,
        totalFiles: Int,
        bytesTransferred: Int64,
        totalBytes: Int64
    ) {
        self.currentFile = currentFile
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

/// Thrown when a pull dies partway.
///
/// Carries exactly what `ContinuityFallbackMachine` needs and nothing else, so
/// the decision about what is still bootable is made in one place from
/// explicit facts rather than reconstructed from an error string.
public struct PullFailure: Error, Sendable, Equatable {
    public var underlying: ContinuityError
    /// Descriptors fully downloaded **and checksum-verified**.
    public var completed: [FileDescriptor]
    /// Descriptors that never completed, including the one that failed.
    public var missing: [FileDescriptor]

    public init(underlying: ContinuityError, completed: [FileDescriptor], missing: [FileDescriptor]) {
        self.underlying = underlying
        self.completed = completed
        self.missing = missing
    }

    /// Translation into the fallback machine's vocabulary.
    ///
    /// `requiredGameFilesComplete` is true only when no required game file is
    /// missing **and** at least one actually arrived — "nothing was missing"
    /// must not read as success when nothing was attempted either.
    public var pulledArtifacts: ContinuityFallbackMachine.PulledArtifacts {
        let saveStateUsable = completed.contains { $0.kind == .saveState || $0.kind == .resumeState }
        let requiredMissing = missing.filter(\.required)
        let requiredGameComplete = !requiredMissing.contains { $0.kind == .gameFile }
            && completed.contains { $0.kind == .gameFile }
        return ContinuityFallbackMachine.PulledArtifacts(
            saveStateUsable: saveStateUsable,
            requiredGameFilesComplete: requiredGameComplete,
            missing: requiredMissing
        )
    }
}

/// The receiving side of a handoff: fetches the manifest, diffs it against
/// local files, and pulls what is missing — small artifacts first, with
/// `Range`-based resume of interrupted downloads and SHA-256 verification of
/// every file before it is moved into place.
public actor ContinuityPuller {
    private let transport: any ContinuityTransport
    private let fileProvider: any ContinuityFileProviding
    /// How a descriptor's relative path becomes a download URL.
    ///
    /// Injectable because nearby library sharing addresses a file by **entry
    /// key plus path** rather than by path alone — its host re-derives (and
    /// re-checks the exclusion of) that entry's manifest before serving a byte.
    /// Everything else about a pull — ordering, `Range` resume, verify-before-
    /// move — is identical, so the alternative was a second copy of this actor.
    private let fileURLBuilder: @Sendable (URL, String) -> URL

    /// The handoff default: `ContinuityRoutes.fileURL(base:relativePath:)`.
    public init(
        transport: any ContinuityTransport,
        fileProvider: any ContinuityFileProviding,
        fileURLBuilder: @escaping @Sendable (URL, String) -> URL = { base, relativePath in
            ContinuityRoutes.fileURL(base: base, relativePath: relativePath)
        }
    ) {
        self.transport = transport
        self.fileProvider = fileProvider
        self.fileURLBuilder = fileURLBuilder
    }

    // MARK: - Manifest

    /// Asks the serving device to mint a fresh save state and returns the
    /// resulting manifest. The normal first call of a handoff.
    public func mintAndFetchManifest(baseURL: URL, token: String) async throws -> ContinuityManifest {
        try await fetchManifest(url: ContinuityRoutes.mintURL(base: baseURL), method: "POST", token: token)
    }

    /// Fetches the manifest without minting — a re-fetch after a partial pull.
    public func fetchManifest(baseURL: URL, token: String) async throws -> ContinuityManifest {
        try await fetchManifest(url: ContinuityRoutes.manifestURL(base: baseURL), method: "GET", token: token)
    }

    private func fetchManifest(url: URL, method: String, token: String) async throws -> ContinuityManifest {
        let response = try await transport.request(.authorized(url: url, method: method, token: token))
        switch response.status {
        case 200:
            return try ContinuityManifest.decode(from: response.body)
        case 401:
            throw ContinuityError.tokenRejected
        case 404:
            throw ContinuityError.noActiveSession
        default:
            throw ContinuityError.invalidResponse(status: response.status)
        }
    }

    // MARK: - Planning

    /// Diffs the manifest against local files. Entries whose checksums already
    /// match are skipped; differing or missing entries are pulled.
    public func makePlan(for manifest: ContinuityManifest) async -> PullPlan {
        var needed: [FileDescriptor] = []
        var present: [FileDescriptor] = []
        for descriptor in manifest.allDescriptors {
            switch await fileProvider.localStatus(of: descriptor) {
            case .presentMatching:
                present.append(descriptor)
            case .missing, .presentDiffering:
                needed.append(descriptor)
            }
        }
        // Priority, then size, then path: a total order, so two devices
        // planning the same manifest agree on the sequence and a resumed pull
        // picks up where the last one stopped.
        needed.sort {
            ($0.kind.pullPriority, $0.size, $0.relativePath)
                < ($1.kind.pullPriority, $1.size, $1.relativePath)
        }
        return PullPlan(needed: needed, alreadyPresent: present)
    }

    // MARK: - Execution

    /// Pulls every file in the plan, throwing `PullFailure` on the first
    /// unrecoverable error and carrying what completed so the fallback machine
    /// can decide what is still bootable.
    public func execute(
        plan: PullPlan,
        baseURL: URL,
        token: String,
        progress: (@Sendable (PullProgress) -> Void)? = nil
    ) async throws {
        var completed: [FileDescriptor] = []
        var bytesDone: Int64 = 0
        let totalBytes = plan.totalBytesNeeded

        for (index, descriptor) in plan.needed.enumerated() {
            do {
                try Task.checkCancellation()
                let bytesBeforeFile = bytesDone
                try await pull(descriptor: descriptor, baseURL: baseURL, token: token) { fileBytes, _ in
                    progress?(PullProgress(
                        currentFile: descriptor,
                        completedFiles: index,
                        totalFiles: plan.needed.count,
                        bytesTransferred: bytesBeforeFile + fileBytes,
                        totalBytes: totalBytes
                    ))
                }
                completed.append(descriptor)
                bytesDone += descriptor.size
            } catch is CancellationError {
                throw PullFailure(
                    underlying: .cancelled,
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            } catch let error as ContinuityError {
                throw PullFailure(
                    underlying: error,
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            } catch {
                throw PullFailure(
                    underlying: .serverUnreachable(detail: String(describing: error)),
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            }
        }
    }

    // MARK: - Single file

    private func pull(
        descriptor: FileDescriptor,
        baseURL: URL,
        token: String,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let destination = try await fileProvider.destinationURL(for: descriptor)
        let partial = destination.appendingPathExtension("part")
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Resume a previous attempt when a plausible partial is lying around.
        // "Plausible" means strictly shorter than the descriptor: a `.part`
        // that is already the full length is not a resumable transfer, it is a
        // leftover from a different (or corrupt) file, so it is discarded.
        var resumeOffset: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? Int64, size > 0, size < descriptor.size {
            resumeOffset = size
        } else if fileManager.fileExists(atPath: partial.path) {
            try? fileManager.removeItem(at: partial)
        }

        let request = ContinuityRequest.authorized(
            url: fileURLBuilder(baseURL, descriptor.relativePath),
            token: token
        )
        _ = try await transport.download(request, to: partial, resumeOffset: resumeOffset, progress: progress)

        // Verify BEFORE moving into place. A file that fails here never becomes
        // visible to the emulator — a corrupt save state that loads is worse
        // than one that never arrived, because the user has no way to tell.
        let actualHash = try ContinuityHash.sha256Hex(ofFileAt: partial)
        guard actualHash == descriptor.sha256 else {
            try? fileManager.removeItem(at: partial)
            throw ContinuityError.checksumMismatch(relativePath: descriptor.relativePath)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
    }
}
