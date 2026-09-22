// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  Test doubles for PVContinuity. A separate target (rather than test-only
//  files) so the app target can use them in previews and debug builds without
//  a test bundle.

import Foundation
import PVContinuity
import PVWebServer

// MARK: - Route registrar

/// Collects registrations instead of binding a socket, so route wiring can be
/// asserted without a live server.
public final class MockRouteRegistrar: WebRouteRegistering, @unchecked Sendable {
    public struct Registration: Sendable {
        public let method: String
        public let path: String
        public let handler: WebRouteHandler
    }

    private let lock = NSLock()
    private var storage: [Registration] = []

    public init() {}

    public var registrations: [Registration] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func addAsyncHandler(forMethod method: String, path: String, handler: @escaping WebRouteHandler) {
        lock.lock(); defer { lock.unlock() }
        storage.append(Registration(method: method.uppercased(), path: path, handler: handler))
    }

    public func handler(forMethod method: String, path: String) -> WebRouteHandler? {
        registrations.first { $0.method == method.uppercased() && $0.path == path }?.handler
    }

    /// Dispatches a request through a registered handler, or returns nil when
    /// nothing matches — the same "no route" answer the real server gives.
    public func send(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> WebRouteResponse? {
        guard let handler = handler(forMethod: method, path: path) else { return nil }
        return await handler(WebRouteRequest(
            method: method, path: path, query: query, headers: headers, body: body
        ))
    }
}

// MARK: - File provider

/// In-memory file provider backed by a scratch directory.
public actor MockFileProvider: ContinuityFileProviding {
    private let root: URL
    private var enumerations: [ContinuityFileKind: [FileDescriptor]] = [:]
    private var statuses: [String: LocalFileStatus] = [:]

    public init(root: URL) {
        self.root = root
    }

    public func setEnumeration(_ descriptors: [FileDescriptor], for kind: ContinuityFileKind) {
        enumerations[kind] = descriptors
    }

    public func setStatus(_ status: LocalFileStatus, forRelativePath path: String) {
        statuses[path] = status
    }

    public func enumerate(kind: ContinuityFileKind, identity: GameIdentity) async throws -> [FileDescriptor] {
        enumerations[kind] ?? []
    }

    public func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }

    public func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus {
        statuses[descriptor.relativePath] ?? .missing
    }

    public func destinationURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }
}

// MARK: - Save-state minter

public actor MockSaveStateMinter: SaveStateMinting {
    public enum Behavior: Sendable {
        case succeed(SaveStateDescriptor)
        case fail(ContinuityError)
    }

    private var behavior: Behavior
    public private(set) var mintCount = 0

    public init(behavior: Behavior) {
        self.behavior = behavior
    }

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public func mintHandoffState(identity: GameIdentity) async throws -> SaveStateDescriptor {
        mintCount += 1
        switch behavior {
        case .succeed(let descriptor): return descriptor
        case .fail(let error): throw error
        }
    }
}

// MARK: - Pairing approver

public actor MockPairingApprover: ContinuityPairingApproving {
    private var answer: Bool
    /// Never resolves — models a host UI that cannot present the prompt, which
    /// is the case the server's timeout race exists for.
    private var hangs: Bool
    public private(set) var lastCode: String?
    public private(set) var lastPeerName: String?

    public init(answer: Bool, hangs: Bool = false) {
        self.answer = answer
        self.hangs = hangs
    }

    public func approvePairing(peerName: String, code: String) async -> Bool {
        lastPeerName = peerName
        lastCode = code
        if hangs {
            // Sleep far past any test's patience; the server's race resolves it.
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        return answer
    }
}

// MARK: - Transport

/// Scriptable transport with mid-download failure injection.
public actor MockTransport: ContinuityTransport {
    public struct Scripted: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]

        public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    /// Keyed by URL path.
    private var responses: [String: [Scripted]] = [:]
    /// Bytes served per file path; nil = 404.
    private var files: [String: Data] = [:]
    /// Paths that fail partway, with how many bytes land before the failure.
    private var truncations: [String: Int] = [:]
    public private(set) var requestedPaths: [String] = []

    public init() {}

    public func stub(path: String, responses scripted: [Scripted]) {
        responses[path] = scripted
    }

    public func stubFile(relativePath: String, contents: Data) {
        files[relativePath] = contents
    }

    /// Serve only `bytes` of this file, then fail — the mid-transfer death the
    /// fallback ladder has to cope with.
    public func truncateFile(relativePath: String, afterBytes bytes: Int) {
        truncations[relativePath] = bytes
    }

    /// Heal a previously truncated file, so a retry can succeed. Needed to test
    /// resume: without it a "healthy again" server would still throw.
    public func healFile(relativePath: String) {
        truncations[relativePath] = nil
    }

    public func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        let path = request.url.path
        requestedPaths.append(path)
        guard var queue = responses[path], !queue.isEmpty else {
            throw ContinuityError.serverUnreachable(detail: "no stub for \(path)")
        }
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        responses[path] = queue
        return ContinuityResponse(status: next.status, headers: next.headers, body: next.body)
    }

    public func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let relativePath = components?.queryItems?
            .first { $0.name == ContinuityRoutes.filePathQueryKey }?.value ?? ""
        requestedPaths.append(relativePath)

        guard let contents = files[relativePath] else {
            throw ContinuityError.noActiveSession
        }

        let limit = truncations[relativePath].map { min($0, contents.count) } ?? contents.count
        let slice = contents.subdata(in: Int(resumeOffset)..<limit)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(resumeOffset))
        try handle.seekToEnd()
        try handle.write(contentsOf: slice)

        let written = resumeOffset + Int64(slice.count)
        progress?(written, Int64(contents.count))

        if truncations[relativePath] != nil {
            throw ContinuityError.serverUnreachable(detail: "connection lost")
        }
        return written
    }
}

// MARK: - Library querying

public struct MockLibrary: LibraryQuerying {
    private let match: LocalGameMatch?

    public init(match: LocalGameMatch?) {
        self.match = match
    }

    public func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch? {
        match
    }
}
