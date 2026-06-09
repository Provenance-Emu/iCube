// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  ROMUploadServer.swift
//  PVWebServer
//
//  Pure-Swift HTTP + WebDAV upload server built on NWListener
//  (Network.framework), with zero external dependencies. Ported from iFly's
//  NativeWebServer to replace the vendored 2015 ObjC GCDWebServer /
//  GCDWebUploader / GCDWebDAVServer stack.
//
//    HTTP   — drag/drop file-upload UI + file browser (default port 80,
//             8080 on simulator)
//    WebDAV — Finder/NAS-compatible (default port 81, 8081 on simulator)
//
//  Streams large uploads directly to disk so multi-GB disc images never sit
//  fully in memory. On every completed upload it posts
//  `PVWebServerFileUploadCompletedNotification` (the exact same string the old
//  GCDWebServer stack posted) so the existing import/rescan plumbing keeps
//  working unchanged.
//
//  NOTE: the app target already has its own loopback-only `NativeWebServer`
//  (Debug/NativeWebServer.swift) for the debug JSON API. This class is named
//  `ROMUploadServer` to avoid colliding with it — they are unrelated servers.

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SerialFileWriter

/// Offloads `FileHandle` writes to a per-file serial queue so `NWConnection.receive`
/// can schedule the next socket read without waiting on flash I/O.
private final class SerialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue

    init?(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        self.handle = handle
        self.queue = DispatchQueue(
            label: "org.dolphin.iCube.uploadserver.disk.\(UUID().uuidString)",
            qos: .utility
        )
    }

    init(handle: FileHandle) {
        self.handle = handle
        self.queue = DispatchQueue(
            label: "org.dolphin.iCube.uploadserver.disk.\(UUID().uuidString)",
            qos: .utility
        )
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { self.handle.write(data) }
    }

    func finalize(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.handle.closeFile()
            DispatchQueue.global(qos: .userInitiated).async(execute: completion)
        }
    }
}

// MARK: - ROMUploadServer

/// A lightweight HTTP + WebDAV server built on `NWListener` for receiving ROM /
/// disc-image / BIOS / save uploads over the LAN. Bound to all interfaces so a
/// browser or Finder on the same Wi-Fi can reach it.
final class ROMUploadServer: @unchecked Sendable {

    // MARK: - Types

    /// Closure type matching the legacy custom-handler API.
    typealias CustomHandlerBlock = (
        _ method: String,
        _ path: String,
        _ query: [String: String]?,
        _ body: Data?
    ) -> [String: Any]?

    private struct CustomRoute {
        let method: String
        let path: String?
        let regex: NSRegularExpression?
        let handler: CustomHandlerBlock
    }

    private struct ConnectionContext {
        let isWebDAV: Bool
        /// Serializes receive/send callbacks for this socket (Finder pipelines on keep-alive).
        let ioQueue: DispatchQueue
        var activeRequest: HTTPRequest?
        /// Prevents concurrent `NWConnection.receive` on one socket (POSIX 96 if doubled).
        var isReceiving: Bool = false
        var readClosed: Bool = false
        var pendingPipelined: Data = Data()
    }

    // MARK: - Configuration

    let httpPort: UInt16
    let webDAVPort: UInt16
    let romsDirectory: URL

    /// Title shown in the upload page header (set by the facade).
    var pageTitle: String = "iCube"

    // MARK: - State

    private static let readChunkSize = 1_048_576
    /// Stream PROPFIND / file bodies above this size instead of one giant `send`.
    private static let streamBodyThreshold = 256 * 1024

    /// Background enumeration + XML assembly for PROPFIND (never blocks socket I/O).
    private static let diskIOQueue = DispatchQueue(
        label: "org.dolphin.iCube.uploadserver.disk",
        qos: .utility
    )

    private static let webDAVISO8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private var httpListener: NWListener?
    private var webdavListener: NWListener?
    private var activeConnections = [ObjectIdentifier: NWConnection]()
    private var connectionContexts = [ObjectIdentifier: ConnectionContext]()
    /// Serial queue for listener accept/state only — each connection gets its own `ioQueue`.
    private let listenerQueue = DispatchQueue(label: "org.dolphin.iCube.uploadserver.listener", qos: .userInitiated)
    private let lock = NSLock()
    private var customRoutes: [CustomRoute] = []
    private var cachedIPAddress: String?

    /// The Bonjour service URL the WebDAV listener advertises (`_webdav._tcp`).
    /// Mirrors the old GCDWebServer `bonjourServerURL`. Derived from the device
    /// IP + WebDAV port once the listener is ready (a reliable value SourcesView
    /// can use to self-filter discovery); the registration handler refines the
    /// host if Bonjour reports a `.hostPort` endpoint.
    private var _bonjourServerURL: URL?
    var bonjourServerURL: URL? {
        lock.lock(); defer { lock.unlock() }
        if let u = _bonjourServerURL { return u }
        guard isWebDAVRunningUnlocked, let ip = getLocalIPAddress() else { return nil }
        return URL(string: "http://\(ip):\(webDAVPort)/")
    }

    private var isWebDAVRunningUnlocked: Bool { webdavListener?.state == .ready }

    // MARK: - Public API

    var isHTTPRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return httpListener?.state == .ready
    }

    var isWebDAVRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return webdavListener?.state == .ready
    }

    var serverURL: URL? {
        guard isHTTPRunning, let ip = getLocalIPAddress() else { return nil }
        let portSuffix = httpPort == 80 ? "" : ":\(httpPort)"
        return URL(string: "http://\(ip)\(portSuffix)/")
    }

    var webDAVURL: URL? {
        guard isWebDAVRunning, let ip = getLocalIPAddress() else { return nil }
        return URL(string: "http://\(ip):\(webDAVPort)/")
    }

    var ipAddress: String? { getLocalIPAddress() }

    // MARK: - Init

    init(romsDirectory: URL) {
        self.romsDirectory = romsDirectory

        #if targetEnvironment(simulator)
        self.httpPort = 8080
        self.webDAVPort = 8081
        #else
        self.httpPort = 80
        self.webDAVPort = 81
        #endif

        try? FileManager.default.createDirectory(at: romsDirectory,
                                                  withIntermediateDirectories: true)
    }

    private static func makeTCPParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        params.defaultProtocolStack.transportProtocol = tcpOptions
        return params
    }

    // MARK: - Start / Stop

    /// Start both HTTP and WebDAV listeners. Waits until both reach `.ready`
    /// (or throws if either fails to bind). Also publishes a `_webdav._tcp`
    /// Bonjour record so other instances / NAS browsers can discover it.
    func start() async throws {
        guard !isHTTPRunning else { return }

        let httpListener = try NWListener(using: Self.makeTCPParameters(), on: NWEndpoint.Port(rawValue: httpPort)!)
        httpListener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn, isWebDAV: false)
        }

        let davListener = try NWListener(using: Self.makeTCPParameters(), on: NWEndpoint.Port(rawValue: webDAVPort)!)
        davListener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn, isWebDAV: true)
        }
        // Advertise WebDAV over Bonjour (parity with the old GCDWebServer
        // registration that SourcesView's self-filter relies on).
        davListener.service = NWListener.Service(name: pageTitle, type: "_webdav._tcp")
        davListener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self else { return }
            // Best-effort host refinement: an advertised service usually reports
            // an `.service(...)` endpoint (no host:port), in which case we keep
            // the IP-derived fallback in `bonjourServerURL`. If it happens to
            // report a concrete `.hostPort`, prefer that.
            if case let .add(endpoint) = change,
               case let .hostPort(host, port) = endpoint {
                let hostStr: String
                switch host {
                case .name(let n, _): hostStr = n
                case .ipv4(let a): hostStr = "\(a)"
                case .ipv6(let a): hostStr = "\(a)"
                @unknown default: return
                }
                self.lock.lock()
                self._bonjourServerURL = URL(string: "http://\(hostStr):\(port.rawValue)/")
                self.lock.unlock()
            }
        }

        // Start HTTP listener and wait for .ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            httpListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    NSLog("[ROMUploadServer] HTTP listener failed: \(error)")
                    self?.stop()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true
                        continuation.resume(throwing: ROMUploadServerError.initializationFailed)
                    }
                default:
                    break
                }
            }
            httpListener.start(queue: self.listenerQueue)
        }
        self.httpListener = httpListener

        // Start WebDAV listener and wait for .ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            davListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    NSLog("[ROMUploadServer] WebDAV listener failed: \(error)")
                    self?.stop()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true
                        continuation.resume(throwing: ROMUploadServerError.initializationFailed)
                    }
                default:
                    break
                }
            }
            davListener.start(queue: self.listenerQueue)
        }
        self.webdavListener = davListener

        let root = romsDirectory
        Self.diskIOQueue.async {
            _ = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        }

        NSLog("[ROMUploadServer] started — HTTP :\(httpPort), WebDAV :\(webDAVPort)")
    }

    func stop() {
        lock.lock()
        let conns = activeConnections
        activeConnections.removeAll()
        connectionContexts.removeAll()
        lock.unlock()

        for conn in conns.values { conn.cancel() }
        httpListener?.cancel()
        webdavListener?.cancel()
        httpListener = nil
        webdavListener = nil
        cachedIPAddress = nil
        lock.lock()
        _bonjourServerURL = nil
        lock.unlock()

        NSLog("[ROMUploadServer] stopped")
    }

    // MARK: - Custom Handler Registration

    func addCustomHandler(forMethod method: String, path: String,
                          handler: @escaping CustomHandlerBlock) {
        lock.lock(); defer { lock.unlock() }
        customRoutes.append(CustomRoute(method: method.uppercased(),
                                        path: path, regex: nil, handler: handler))
    }

    func addCustomHandler(forMethod method: String, pathRegex pattern: String,
                          handler: @escaping CustomHandlerBlock) {
        lock.lock(); defer { lock.unlock() }
        guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: []) else { return }
        customRoutes.append(CustomRoute(method: method.uppercased(),
                                        path: nil, regex: regex, handler: handler))
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection, isWebDAV: Bool) {
        let connID = ObjectIdentifier(connection)
        let ioQueue = DispatchQueue(label: "org.dolphin.iCube.uploadserver.conn.\(connID)")
        lock.lock()
        activeConnections[connID] = connection
        connectionContexts[connID] = ConnectionContext(isWebDAV: isWebDAV, ioQueue: ioQueue, activeRequest: nil)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.lock.lock()
                self?.activeConnections.removeValue(forKey: connID)
                self?.connectionContexts.removeValue(forKey: connID)
                self?.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: ioQueue)
        ioQueue.async { [weak self] in
            self?.scheduleReceive(on: connection, isWebDAV: isWebDAV, accumulated: Data())
        }
    }

    /// Arm a single `receive` or process bytes already buffered (pipelined keep-alive).
    private func scheduleReceive(on connection: NWConnection,
                                   isWebDAV: Bool,
                                   accumulated: Data) {
        if !accumulated.isEmpty {
            processIncomingBuffer(on: connection, isWebDAV: isWebDAV, buffer: accumulated)
            return
        }

        let connID = ObjectIdentifier(connection)
        lock.lock()
        guard var ctx = connectionContexts[connID], !ctx.readClosed else {
            lock.unlock()
            connection.cancel()
            return
        }
        if ctx.isReceiving {
            lock.unlock()
            ctx.ioQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.scheduleReceive(on: connection, isWebDAV: isWebDAV, accumulated: accumulated)
            }
            return
        }
        ctx.isReceiving = true
        connectionContexts[connID] = ctx
        lock.unlock()

        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            let connID = ObjectIdentifier(connection)
            self.lock.lock()
            if var ctx = self.connectionContexts[connID] {
                ctx.isReceiving = false
                if isComplete { ctx.readClosed = true }
                self.connectionContexts[connID] = ctx
            }
            self.lock.unlock()

            if let error {
                let ns = error as NSError
                let posixCode = ns.domain == NSPOSIXErrorDomain ? ns.code
                    : (ns.userInfo["POSIXErrorCode"] as? Int)
                if posixCode != 54 && posixCode != 96 {
                    NSLog("[ROMUploadServer] receive error: \(error)")
                }
                connection.cancel()
                return
            }

            var buffer = Data()
            if let data { buffer.append(data) }
            self.processIncomingBuffer(on: connection, isWebDAV: isWebDAV, buffer: buffer)
        }
    }

    /// Parse buffered bytes into HTTP requests; may leave pipelined tail for keep-alive.
    private func processIncomingBuffer(on connection: NWConnection,
                                       isWebDAV: Bool,
                                       buffer: Data) {
        let headerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        if let headerEnd {
            let headersData = buffer[buffer.startIndex..<headerEnd.lowerBound]
            let bodyStart = buffer[headerEnd.upperBound...]

            guard let headersStr = String(data: headersData, encoding: .utf8),
                  let request = HTTPRequest.parse(headersStr) else {
                sendResponse(on: connection, status: 400, statusText: "Bad Request", body: "Bad Request",
                             isWebDAV: isWebDAV, forceClose: true)
                return
            }

            let connID = ObjectIdentifier(connection)
            let contentLength = request.contentLength

            lock.lock()
            if var ctx = connectionContexts[connID] {
                ctx.activeRequest = request
                connectionContexts[connID] = ctx
            }
            lock.unlock()

            if request.isChunked {
                beginChunkedBody(on: connection, request: request, isWebDAV: isWebDAV,
                                 initial: Data(bodyStart))
                return
            }

            let headerByteCount = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound)
            let totalConsumed = headerByteCount + contentLength
            let leftover: Data = buffer.count > totalConsumed
                ? Data(buffer.dropFirst(totalConsumed))
                : Data()

            lock.lock()
            if var ctx = connectionContexts[connID] {
                if !leftover.isEmpty { ctx.pendingPipelined = leftover }
                connectionContexts[connID] = ctx
            }
            lock.unlock()

            if contentLength > 0 && bodyStart.count < contentLength {
                handleRequestWithBody(
                    on: connection, request: request, isWebDAV: isWebDAV,
                    initialBody: Data(bodyStart),
                    remaining: contentLength - bodyStart.count
                )
            } else {
                let body = contentLength > 0 ? Data(bodyStart.prefix(contentLength)) : Data()
                routeRequest(on: connection, request: request, body: body, isWebDAV: isWebDAV)
            }
        } else if buffer.count > 64 * 1024 {
            sendResponse(on: connection, status: 413, statusText: "Request Entity Too Large",
                         body: "Headers too large", isWebDAV: isWebDAV, forceClose: true)
        } else if buffer.isEmpty {
            connection.cancel()
        } else {
            let connID = ObjectIdentifier(connection)
            lock.lock()
            let canRead = connectionContexts[connID]?.isReceiving != true
                && connectionContexts[connID]?.readClosed != true
            lock.unlock()
            if canRead {
                lock.lock()
                if var ctx = connectionContexts[connID] {
                    ctx.isReceiving = true
                    connectionContexts[connID] = ctx
                }
                lock.unlock()
                connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) {
                    [weak self] data, _, isComplete, error in
                    guard let self else { return }
                    let connID = ObjectIdentifier(connection)
                    self.lock.lock()
                    if var ctx = self.connectionContexts[connID] {
                        ctx.isReceiving = false
                        if isComplete { ctx.readClosed = true }
                        self.connectionContexts[connID] = ctx
                    }
                    self.lock.unlock()
                    if error != nil || isComplete {
                        connection.cancel()
                        return
                    }
                    var grown = buffer
                    if let data { grown.append(data) }
                    self.processIncomingBuffer(on: connection, isWebDAV: isWebDAV, buffer: grown)
                }
            }
        }
    }

    private func handleRequestWithBody(
        on connection: NWConnection,
        request: HTTPRequest,
        isWebDAV: Bool,
        initialBody: Data,
        remaining: Int
    ) {
        if !isWebDAV && request.method == "POST" && request.path.hasPrefix("/upload") {
            if let boundary = request.multipartBoundary {
                streamMultipartUpload(on: connection, request: request, boundary: boundary,
                                      initialBody: initialBody, remaining: remaining)
                return
            }
        }

        if isWebDAV && request.method == "PUT" {
            let beginPut: () -> Void = { [weak self] in
                self?.streamWebDAVPut(on: connection, request: request,
                                      initialBody: initialBody, remaining: remaining)
            }
            if request.expectsContinue {
                sendContinue(on: connection, isWebDAV: isWebDAV, request: request, then: beginPut)
            } else {
                beginPut()
            }
            return
        }

        bufferRemainingBody(on: connection, initial: initialBody,
                            remaining: remaining) { [weak self] fullBody in
            self?.routeRequest(on: connection, request: request, body: fullBody, isWebDAV: isWebDAV)
        }
    }

    private func bufferRemainingBody(on connection: NWConnection,
                                     initial: Data,
                                     remaining: Int,
                                     completion: @escaping (Data) -> Void) {
        var buffer = initial
        func readRemaining(_ bytesLeft: Int) {
            if bytesLeft <= 0 { completion(buffer); return }
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: min(bytesLeft, Self.readChunkSize)) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                let newLeft = bytesLeft - (data?.count ?? 0)
                if newLeft <= 0 || isComplete || error != nil {
                    completion(buffer)
                } else {
                    readRemaining(newLeft)
                }
            }
        }
        readRemaining(remaining)
    }

    // MARK: - Chunked request bodies

    /// Finder WebDAV PUT omits Content-Length and sends `Transfer-Encoding: chunked`.
    private func beginChunkedBody(on connection: NWConnection,
                                  request: HTTPRequest,
                                  isWebDAV: Bool,
                                  initial: Data) {
        if isWebDAV && request.method == "PUT" {
            let beginPut: () -> Void = { [weak self] in
                self?.streamChunkedWebDAVPut(on: connection, request: request, initial: initial)
            }
            if request.expectsContinue {
                sendContinue(on: connection, isWebDAV: isWebDAV, request: request, then: beginPut)
            } else {
                beginPut()
            }
            return
        }

        accumulateChunkedBody(on: connection, initial: initial) { [weak self] body, trailing in
            guard let self else { return }
            if !trailing.isEmpty {
                let connID = ObjectIdentifier(connection)
                self.lock.lock()
                if var ctx = self.connectionContexts[connID] {
                    ctx.pendingPipelined = trailing
                    self.connectionContexts[connID] = ctx
                }
                self.lock.unlock()
            }
            self.routeRequest(on: connection, request: request, body: body, isWebDAV: isWebDAV)
        }
    }

    /// Incremental `Transfer-Encoding: chunked` decoder (RFC 9112 §7.1).
    private final class ChunkedBodyReader: @unchecked Sendable {
        enum Event {
            case payload(Data)
            case complete(trailing: Data)
            case invalid
        }

        private var buffer = Data()
        private var chunkRemaining = 0
        private var finished = false

        func feed(_ incoming: Data) -> [Event] {
            guard !finished else { return [] }
            if !incoming.isEmpty { buffer.append(incoming) }
            var events: [Event] = []

            parsing: while !finished {
                if chunkRemaining > 0 {
                    guard buffer.count >= chunkRemaining + 2 else { break parsing }
                    let payload = Data(buffer.prefix(chunkRemaining))
                    buffer.removeFirst(chunkRemaining + 2)
                    chunkRemaining = 0
                    events.append(.payload(payload))
                    continue
                }

                guard let lineEnd = buffer.findRange(of: Data([0x0D, 0x0A])) else { break parsing }
                let lineData = buffer[buffer.startIndex..<lineEnd.lowerBound]
                guard let line = String(data: lineData, encoding: .utf8) else {
                    finished = true
                    events.append(.invalid)
                    break
                }
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)

                let sizeToken = line.split(separator: ";", maxSplits: 1).first
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(sizeToken, radix: 16), size >= 0 else {
                    finished = true
                    events.append(.invalid)
                    break
                }

                if size == 0 {
                    finished = true
                    if buffer.starts(with: Data([0x0D, 0x0A])) {
                        buffer.removeFirst(2)
                    } else if let trailerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                        buffer.removeSubrange(buffer.startIndex..<trailerEnd.upperBound)
                    } else if !buffer.isEmpty {
                        break parsing
                    }
                    events.append(.complete(trailing: buffer))
                    buffer = Data()
                    break
                }
                chunkRemaining = size
            }
            return events
        }
    }

    private func accumulateChunkedBody(on connection: NWConnection,
                                       initial: Data,
                                       completion: @escaping (Data, Data) -> Void) {
        let reader = ChunkedBodyReader()
        var body = Data()

        func process(_ events: [ChunkedBodyReader.Event]) -> Bool {
            for event in events {
                switch event {
                case .payload(let chunk):
                    body.append(chunk)
                case .complete(let trailing):
                    completion(body, trailing)
                    return true
                case .invalid:
                    completion(body, Data())
                    return true
                }
            }
            return false
        }

        if process(reader.feed(initial)) { return }

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) {
                data, _, isComplete, error in
                if error != nil {
                    completion(body, Data())
                    return
                }
                let events = reader.feed(data ?? Data())
                if process(events) { return }
                if isComplete {
                    completion(body, Data())
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    private func streamChunkedWebDAVPut(on connection: NWConnection,
                                       request: HTTPRequest,
                                       initial: Data) {
        let rawPath = String(request.path.dropFirst())
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard let target = resolvedPath(decoded, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden",
                               request: request, forceClose: true)
            return
        }

        let parent = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: target.path) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }

        postUploadStarted(path: target.path)
        let writer = SerialFileWriter(handle: handle)
        let reader = ChunkedBodyReader()

        let finishSuccess: (Data) -> Void = { [weak self] trailing in
            guard let self else { return }
            writer.finalize {
                self.postUploadCompleted(filePath: target.path)
                if !trailing.isEmpty {
                    let connID = ObjectIdentifier(connection)
                    self.lock.lock()
                    if var ctx = self.connectionContexts[connID] {
                        ctx.pendingPipelined = trailing
                        self.connectionContexts[connID] = ctx
                    }
                    self.lock.unlock()
                }
                self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
            }
        }

        func handleEvents(_ events: [ChunkedBodyReader.Event]) -> Bool {
            for event in events {
                switch event {
                case .payload(let chunk):
                    if !chunk.isEmpty { writer.write(chunk) }
                case .complete(let trailing):
                    finishSuccess(trailing)
                    return true
                case .invalid:
                    sendWebDAVResponse(on: connection, status: 400, statusText: "Bad Request",
                                       body: "Invalid chunked body", request: request, forceClose: true)
                    return true
                }
            }
            return false
        }

        if handleEvents(reader.feed(initial)) { return }

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if error != nil {
                    sendWebDAVResponse(on: connection, status: 400, statusText: "Bad Request",
                                       request: request, forceClose: true)
                    return
                }
                let events = reader.feed(data ?? Data())
                if handleEvents(events) { return }
                if isComplete {
                    sendWebDAVResponse(on: connection, status: 400, statusText: "Bad Request",
                                       body: "Truncated chunked body", request: request, forceClose: true)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    // MARK: - Request Routing

    private func routeRequest(on connection: NWConnection,
                              request: HTTPRequest,
                              body: Data,
                              isWebDAV: Bool) {
        if !isWebDAV {
            lock.lock()
            let routes = customRoutes
            lock.unlock()

            for route in routes {
                guard route.method == request.method else { continue }
                if let exactPath = route.path {
                    guard request.path == exactPath else { continue }
                } else if let regex = route.regex {
                    let range = NSRange(request.path.startIndex..., in: request.path)
                    guard regex.firstMatch(in: request.path, range: range) != nil else { continue }
                }

                let queryDict = request.queryParameters
                let result = route.handler(request.method, request.path,
                                           queryDict.isEmpty ? nil : queryDict,
                                           body.isEmpty ? nil : body)

                if let result {
                    if let rawData = result["__rawData"] as? Data {
                        let ct = result["__contentType"] as? String ?? "application/octet-stream"
                        sendDataResponse(on: connection, status: 200, statusText: "OK",
                                         contentType: ct, body: rawData,
                                         request: request, isWebDAV: isWebDAV)
                    } else if let jsonData = try? JSONSerialization.data(
                        withJSONObject: result, options: [.sortedKeys]) {
                        sendDataResponse(on: connection, status: 200, statusText: "OK",
                                         contentType: "application/json", body: jsonData,
                                         request: request, isWebDAV: isWebDAV)
                    } else {
                        sendResponse(on: connection, status: 500,
                                     statusText: "Internal Server Error",
                                     body: "Handler returned invalid JSON",
                                     request: request, isWebDAV: isWebDAV, forceClose: true)
                    }
                } else {
                    sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found",
                                   request: request, isWebDAV: isWebDAV)
                }
                return
            }
        }

        if isWebDAV {
            routeWebDAV(on: connection, request: request, body: body)
        } else {
            routeHTTP(on: connection, request: request, body: body)
        }
    }

    // MARK: - HTTP Routes

    private func routeHTTP(on connection: NWConnection, request: HTTPRequest, body: Data) {
        let path = request.path
        switch (request.method, path) {
        case ("GET", "/"):
            serveHTML(on: connection, request: request, subpath: request.queryParameters["path"] ?? "")
        case ("GET", "/api/list"):
            serveFileListJSON(on: connection, request: request,
                              subpath: request.queryParameters["path"] ?? "")
        case ("GET", _) where path.hasPrefix("/files/"):
            serveFile(on: connection, path: String(path.dropFirst("/files/".count)))
        case ("DELETE", _) where path.hasPrefix("/files/"):
            deleteFile(on: connection, request: request,
                       path: String(path.dropFirst("/files/".count)))
        case ("POST", "/upload"):
            handleBufferedUpload(on: connection, request: request, body: body)
        default:
            sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found",
                           request: request, isWebDAV: false)
        }
    }

    // MARK: - HTML Serving

    private func connectionIOQueue(for connection: NWConnection) -> DispatchQueue? {
        lock.lock()
        defer { lock.unlock() }
        return connectionContexts[ObjectIdentifier(connection)]?.ioQueue
    }

    private func serveHTML(on connection: NWConnection, request: HTTPRequest, subpath: String = "") {
        let ip = getLocalIPAddress() ?? "unknown"
        let portSuffix = httpPort == 80 ? "" : ":\(httpPort)"
        let davPortStr = "\(webDAVPort)"
        let ctx = listDirectoryContext(subpath: subpath)
        let listDir = ctx.listDir
        let currentSub = ctx.currentSub
        let ioQueue = connectionIOQueue(for: connection)

        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            let files = self.listFiles(in: listDir)
            var rows: [String] = []

            if !currentSub.isEmpty {
                let parent = currentSub.contains("/")
                    ? String(currentSub[..<currentSub.lastIndex(of: "/")!])
                    : ""
                let parentQuery = parent.isEmpty ? "/" : "/?path=\(parent.urlPathEscaped)"
                rows.append("""
                <tr>
                  <td><a href="\(parentQuery)">&#x2B05;&#xFE0F; ..</a></td>
                  <td></td>
                  <td></td>
                  <td></td>
                </tr>
                """)
            }

            rows += files.map { self.fileRowHTML(entry: $0, currentSub: currentSub) }

            let emptyMessage = (rows.isEmpty)
                ? "<tr><td colspan=\"4\" class=\"empty\">No files yet. Drag and drop above to upload!</td></tr>"
                : ""

            let entriesPayload: [[String: Any]] = files.map { entry in
                var dict: [String: Any] = [
                    "name": entry.name,
                    "size": entry.size,
                    "isDirectory": entry.isDirectory,
                    "modified": entry.modified.timeIntervalSince1970
                ]
                if let created = entry.created {
                    dict["created"] = created.timeIntervalSince1970
                }
                return dict
            }
            let initialEntriesJSON = (try? JSONSerialization.data(withJSONObject: entriesPayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            let html = Self.uploadPageHTML(
                title: self.pageTitle,
                ipAddress: ip, httpPort: portSuffix, davPort: davPortStr,
                fileRows: rows.isEmpty ? emptyMessage : rows.joined(separator: "\n"),
                currentPath: currentSub,
                initialEntriesJSON: initialEntriesJSON
            )
            let data = Data(html.utf8)

            let deliver = { [weak self] in
                self?.sendDataResponse(on: connection, status: 200, statusText: "OK",
                                       contentType: "text/html; charset=utf-8", body: data,
                                       request: request, isWebDAV: false)
            }
            if let ioQueue {
                ioQueue.async { deliver() }
            } else {
                deliver()
            }
        }
    }

    private func listDirectoryContext(subpath: String) -> (listDir: URL, currentSub: String) {
        let decodedSub = (subpath.removingPercentEncoding ?? subpath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let listDir: URL
        if decodedSub.isEmpty {
            listDir = romsDirectory
        } else if let resolved = resolvedPath(decodedSub, within: romsDirectory),
                  (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            listDir = resolved
        } else {
            listDir = romsDirectory
        }
        let currentSub = listDir.path == romsDirectory.path ? "" : decodedSub
        return (listDir, currentSub)
    }

    private func serveFileListJSON(on connection: NWConnection, request: HTTPRequest, subpath: String) {
        let ctx = listDirectoryContext(subpath: subpath)
        let ioQueue = connectionIOQueue(for: connection)

        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            let files = self.listFiles(in: ctx.listDir)
            let entries: [[String: Any]] = files.map { entry in
                var dict: [String: Any] = [
                    "name": entry.name,
                    "size": entry.size,
                    "isDirectory": entry.isDirectory,
                    "modified": entry.modified.timeIntervalSince1970
                ]
                if let created = entry.created {
                    dict["created"] = created.timeIntervalSince1970
                }
                return dict
            }
            let payload: [String: Any] = [
                "path": ctx.currentSub,
                "entries": entries
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

            let deliver = { [weak self] in
                self?.sendDataResponse(on: connection, status: 200, statusText: "OK",
                                       contentType: "application/json", body: data,
                                       request: request, isWebDAV: false)
            }
            if let ioQueue {
                ioQueue.async { deliver() }
            } else {
                deliver()
            }
        }
    }

    private func formatFileDate(_ date: Date?) -> String {
        guard let date else { return "&mdash;" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date).htmlEscaped
    }

    private func fileRowHTML(entry: FileEntry, currentSub: String) -> String {
        let childSub = currentSub.isEmpty ? entry.name : "\(currentSub)/\(entry.name)"
        let escapedName = entry.name.htmlEscaped
        let dateStr = entry.isDirectory ? "&mdash;" : formatFileDate(entry.modified)
        if entry.isDirectory {
            return """
            <tr>
              <td><a href="/?path=\(childSub.urlPathEscaped)">&#x1F4C1; \(escapedName)</a></td>
              <td>\(dateStr)</td>
              <td>&mdash;</td>
              <td></td>
            </tr>
            """
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        return """
        <tr>
          <td><a href="/files/\(childSub.urlPathEscaped)" download>\(escapedName)</a></td>
          <td>\(dateStr)</td>
          <td>\(sizeStr)</td>
          <td>
            <a href="/files/\(childSub.urlPathEscaped)" download class="btn btn-sm">Download</a>
            <button onclick="deleteFile('\(childSub.jsEscaped)')" class="btn btn-sm btn-danger">Delete</button>
          </td>
        </tr>
        """
    }

    // MARK: - File Serving

    private func serveFile(on connection: NWConnection, path: String) {
        let decoded = path.removingPercentEncoding ?? path
        guard let resolved = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied")
            return
        }

        let ioQueue = connectionIOQueue(for: connection)
        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
                let respond = { self.sendResponse(on: connection, status: 404, statusText: "Not Found", body: "File not found") }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            if isDir.boolValue {
                let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let location = relative.isEmpty ? "/" : "/?path=\(relative.urlPathEscaped)"
                let respond = {
                    self.sendResponse(on: connection, status: 302, statusText: "Found",
                                      body: "", extraHeaders: ["Location": location])
                }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            guard let handle = try? FileHandle(forReadingFrom: resolved) else {
                let respond = { self.sendResponse(on: connection, status: 500, statusText: "Internal Server Error", body: "Cannot open file") }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            let filename = resolved.lastPathComponent
            let escapedName = filename.replacingOccurrences(of: "\"", with: "")

            let header = """
            HTTP/1.1 200 OK\r\n\
            Content-Type: application/octet-stream\r\n\
            Content-Length: \(fileSize)\r\n\
            Content-Disposition: attachment; filename="\(escapedName)"\r\n\
            Connection: close\r\n\
            \r\n
            """

            let beginStream = {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    if error != nil { handle.closeFile(); connection.cancel(); return }
                    self.streamFileData(handle: handle, on: connection, remaining: Int(fileSize), ioQueue: ioQueue)
                })
            }
            if let ioQueue { ioQueue.async(execute: beginStream) } else { beginStream() }
        }
    }

    private func streamFileData(handle: FileHandle, on connection: NWConnection,
                                remaining: Int, ioQueue: DispatchQueue? = nil) {
        let chunkSize = 256 * 1024
        guard remaining > 0 else { handle.closeFile(); connection.cancel(); return }

        let toRead = min(chunkSize, remaining)
        Self.diskIOQueue.async {
            let data = handle.readData(ofLength: toRead)
            guard !data.isEmpty else {
                handle.closeFile()
                if let ioQueue {
                    ioQueue.async { connection.cancel() }
                } else {
                    connection.cancel()
                }
                return
            }

            let sendChunk = {
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { handle.closeFile(); connection.cancel(); return }
                    self?.streamFileData(handle: handle, on: connection,
                                         remaining: remaining - data.count, ioQueue: ioQueue)
                })
            }
            if let ioQueue { ioQueue.async(execute: sendChunk) } else { sendChunk() }
        }
    }

    // MARK: - File Delete

    private func deleteFile(on connection: NWConnection, request: HTTPRequest, path: String) {
        let decoded = path.removingPercentEncoding ?? path
        guard let resolved = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied",
                         request: request, isWebDAV: false, forceClose: true)
            return
        }
        let ioQueue = connectionIOQueue(for: connection)
        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.removeItem(at: resolved)
                let respond = { self.sendJSON(on: connection, status: 200, json: ["ok": true], request: request, isWebDAV: false) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            } catch {
                let respond = {
                    self.sendJSON(on: connection, status: 404,
                                  json: ["ok": false, "error": error.localizedDescription],
                                  request: request, isWebDAV: false, forceClose: true)
                }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            }
        }
    }

    // MARK: - Streaming Multipart Upload

    private func streamMultipartUpload(
        on connection: NWConnection,
        request: HTTPRequest,
        boundary: String,
        initialBody: Data,
        remaining: Int
    ) {
        let parser = StreamingMultipartParser(
            boundary: boundary,
            outputDirectory: uploadDirectory(for: request),
            onFileCompleted: { [weak self] path in self?.postUploadCompleted(filePath: path) }
        )
        parser.feed(initialBody)

        if remaining <= 0 {
            parser.finalize { [weak self] in
                self?.finishMultipartUpload(on: connection, request: request, parser: parser)
            }
            return
        }
        streamMultipartChunks(on: connection, request: request, parser: parser, remaining: remaining)
    }

    private func streamMultipartChunks(on connection: NWConnection,
                                       request: HTTPRequest,
                                       parser: StreamingMultipartParser,
                                       remaining: Int) {
        if remaining <= 0 {
            parser.finalize { [weak self] in
                self?.finishMultipartUpload(on: connection, request: request, parser: parser)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, Self.readChunkSize)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { parser.feed(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                parser.finalize {
                    self.finishMultipartUpload(on: connection, request: request, parser: parser)
                }
            } else {
                self.streamMultipartChunks(on: connection, request: request, parser: parser, remaining: newRemaining)
            }
        }
    }

    private func finishMultipartUpload(on connection: NWConnection, request: HTTPRequest,
                                       parser: StreamingMultipartParser) {
        let files = parser.completedFiles
        if files.isEmpty {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "No files uploaded"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        sendJSON(on: connection, status: 200, json: ["ok": true, "uploaded": files.count],
                 request: request, isWebDAV: false)
    }

    private func handleBufferedUpload(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let boundary = request.multipartBoundary else {
            sendResponse(on: connection, status: 400, statusText: "Bad Request",
                         body: "Missing multipart boundary",
                         request: request, isWebDAV: false, forceClose: true)
            return
        }
        let parser = StreamingMultipartParser(
            boundary: boundary,
            outputDirectory: uploadDirectory(for: request),
            onFileCompleted: { [weak self] path in self?.postUploadCompleted(filePath: path) }
        )
        parser.feed(body)
        parser.finalize { [weak self] in
            self?.finishMultipartUpload(on: connection, request: request, parser: parser)
        }
    }

    private func uploadDirectory(for request: HTTPRequest) -> URL {
        guard let raw = request.queryParameters["path"], !raw.isEmpty else { return romsDirectory }
        let decoded = (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !decoded.isEmpty, let resolved = resolvedPath(decoded, within: romsDirectory) else {
            return romsDirectory
        }
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        return resolved
    }

    // MARK: - Streaming WebDAV PUT

    private func streamWebDAVPut(on connection: NWConnection, request: HTTPRequest,
                                 initialBody: Data, remaining: Int) {
        let rawPath = String(request.path.dropFirst())
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard let target = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied",
                           request: request, isWebDAV: true, forceClose: true)
            return
        }

        let parent = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        guard let writer = SerialFileWriter(at: target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }

        postUploadStarted(path: target.path)

        if !initialBody.isEmpty { writer.write(initialBody) }

        let finishPut = { [weak self] in
            guard let self else { return }
            writer.finalize {
                self.postUploadCompleted(filePath: target.path)
                self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
            }
        }

        if remaining <= 0 {
            finishPut()
            return
        }
        streamPutChunks(on: connection, request: request, writer: writer, target: target, remaining: remaining)
    }

    private func streamPutChunks(on connection: NWConnection, request: HTTPRequest,
                                 writer: SerialFileWriter, target: URL, remaining: Int) {
        if remaining <= 0 {
            writer.finalize { [weak self] in
                self?.postUploadCompleted(filePath: target.path)
                self?.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, Self.readChunkSize)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { writer.write(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                writer.finalize {
                    self.postUploadCompleted(filePath: target.path)
                    self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
                }
            } else {
                self.streamPutChunks(on: connection, request: request, writer: writer,
                                     target: target, remaining: newRemaining)
            }
        }
    }

    // MARK: - WebDAV Routes

    /// Open LAN upload server: anonymous access and any basic-auth credentials are allowed.
    private func webDAVAllows(_ request: HTTPRequest) -> Bool {
        _ = request
        return true
    }

    private func routeWebDAV(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard webDAVAllows(request) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden",
                               body: "Access denied", request: request, forceClose: true)
            return
        }

        let path = request.path
        let decoded = (path == "/" ? "" : String(path.dropFirst()))
            .removingPercentEncoding ?? String(path.dropFirst())

        switch request.method {
        case "OPTIONS": handleWebDAVOptions(on: connection, request: request)
        case "PROPFIND": handlePROPFIND(on: connection, request: request, path: decoded,
                                        depth: request.headers["depth"] ?? "1")
        case "GET": serveWebDAVFile(on: connection, request: request, path: decoded, includeBody: true)
        case "HEAD": serveWebDAVFile(on: connection, request: request, path: decoded, includeBody: false)
        case "DELETE": handleWebDAVDelete(on: connection, request: request, path: decoded)
        case "MKCOL": handleMKCOL(on: connection, request: request, path: decoded)
        case "MOVE": handleMOVE(on: connection, request: request, path: decoded)
        case "COPY": handleCOPY(on: connection, request: request, path: decoded)
        case "PUT": handleWebDAVPutBuffered(on: connection, request: request, path: decoded, body: body)
        case "LOCK": handleWebDAVLock(on: connection, request: request, path: decoded)
        case "UNLOCK": handleWebDAVUnlock(on: connection, request: request)
        case "PROPPATCH": handlePROPPATCH(on: connection, request: request, path: decoded, body: body)
        default:
            sendWebDAVResponse(on: connection, status: 405, statusText: "Method Not Allowed",
                               body: "Method not supported", request: request)
        }
    }

    private func handleWebDAVOptions(on connection: NWConnection, request: HTTPRequest) {
        sendRawHeaders(on: connection, status: 200, statusText: "OK", headers: [
            "DAV": "1, 2",
            "MS-Author-Via": "DAV",
            "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK",
            "Content-Length": "0"
        ], body: Data(), request: request, isWebDAV: true)
    }

    private func handleWebDAVLock(on connection: NWConnection, request: HTTPRequest, path: String) {
        let token = "opaquelocktoken:icube-\(UUID().uuidString)"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
          <D:lockdiscovery>
            <D:activelock>
              <D:locktype><D:write/></D:locktype>
              <D:lockscope><D:exclusive/></D:lockscope>
              <D:timeout>Second-3600</D:timeout>
              <D:locktoken><D:href>\(token.xmlEscaped)</D:href></D:locktoken>
            </D:activelock>
          </D:lockdiscovery>
        </D:prop>
        """
        let data = Data(xml.utf8)
        sendRawHeaders(on: connection, status: 200, statusText: "OK", headers: [
            "Content-Type": "application/xml; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Lock-Token": "<\(token)>"
        ], body: data, request: request, isWebDAV: true)
        _ = path
    }

    private func handleWebDAVUnlock(on connection: NWConnection, request: HTTPRequest) {
        sendWebDAVResponse(on: connection, status: 204, statusText: "No Content", request: request)
    }

    private func handlePROPFIND(on connection: NWConnection, request: HTTPRequest, path: String, depth: String) {
        let target: URL
        if path.isEmpty {
            target = romsDirectory
        } else {
            guard let resolved = resolvedPath(path, within: romsDirectory) else {
                let status = isFinderProbePath(path) ? 404 : 403
                let text = status == 404 ? "Not Found" : "Forbidden"
                sendWebDAVResponse(on: connection, status: status, statusText: text, request: request)
                return
            }
            target = resolved
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request)
            return
        }

        let listingDepth = depth.lowercased()
        let targetPath = target.path
        let connID = ObjectIdentifier(connection)
        lock.lock()
        let ioQueue = connectionContexts[connID]?.ioQueue
        lock.unlock()

        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            var responses: [String] = []
            self.appendPROPFINDEntries(at: URL(fileURLWithPath: targetPath),
                                       depth: listingDepth, into: &responses)
            let data = self.webDAVMultistatusData(blocks: responses)

            let deliver = { self.sendWebDAVMultistatus(on: connection, body: data, request: request) }
            if let ioQueue {
                ioQueue.async { deliver() }
            } else {
                deliver()
            }
        }
    }

    private func webDAVMultistatusData(blocks: [String]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">\n"
        xml += blocks.joined(separator: "\n")
        xml += "\n</D:multistatus>\n"
        return Data(xml.utf8)
    }

    private func sendWebDAVMultistatus(on connection: NWConnection, body: Data, request: HTTPRequest?) {
        let headers: [String: String] = [
            "Content-Type": "application/xml; charset=utf-8",
            "Content-Length": "\(body.count)"
        ]
        if body.count <= Self.streamBodyThreshold {
            sendRawHeaders(on: connection, status: 207, statusText: "Multi-Status",
                           headers: headers, body: body, request: request, isWebDAV: true)
        } else {
            sendRawThenStreamBody(on: connection, status: 207, statusText: "Multi-Status",
                                  headers: headers, body: body, request: request, isWebDAV: true)
        }
    }

    /// Recursively collects PROPFIND responses for `depth` 0, 1, or infinity.
    private func appendPROPFINDEntries(at url: URL, depth: String, into responses: inout [String]) {
        responses.append(propfindEntry(for: url))
        guard depth != "0" else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in contents where !child.lastPathComponent.hasPrefix(".") {
            if depth == "1" {
                responses.append(propfindEntry(for: child))
            } else {
                appendPROPFINDEntries(at: child, depth: depth, into: &responses)
            }
        }
    }

    private func propfindEntry(for url: URL) -> String {
        let attrs = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey
        ])
        let isDir = attrs?.isDirectory ?? false
        let size = attrs?.fileSize ?? 0
        let mtime = webDAVFormattedDate(attrs?.contentModificationDate)
        let ctime = webDAVFormattedDate(attrs?.creationDate)
        let displayName = url.lastPathComponent
        let href = webDAVHref(for: url)
        let resourceType = isDir ? "<D:collection/>" : ""
        let contentType = isDir ? "" : "<D:getcontenttype>\(mimeType(for: url).xmlEscaped)</D:getcontenttype>"
        let creationProp = ctime.isEmpty ? "" : "<D:creationdate>\(ctime)</D:creationdate>"

        return """
            <D:response>
                <D:href>\(href.xmlEscaped)</D:href>
                <D:propstat>
                    <D:prop>
                        <D:resourcetype>\(resourceType)</D:resourcetype>
                        <D:displayname>\(displayName.xmlEscaped)</D:displayname>
                        <D:getcontentlength>\(size)</D:getcontentlength>
                        <D:getlastmodified>\(mtime)</D:getlastmodified>
                        \(creationProp)
                        \(contentType)
                        <D:supportedlock>
                            <D:lockentry>
                                <D:lockscope><D:exclusive/></D:lockscope>
                                <D:locktype><D:write/></D:locktype>
                            </D:lockentry>
                        </D:supportedlock>
                    </D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
        """
    }

    private func serveWebDAVFile(on connection: NWConnection, request: HTTPRequest, path: String,
                                 includeBody: Bool) {
        guard !path.isEmpty,
              let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request)
            return
        }

        let ioQueue = connectionIOQueue(for: connection)
        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                let respond = { self.sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            let keepAlive = request.wantsKeepAlive
            let connHeader = keepAlive ? "keep-alive" : "close"

            if !includeBody {
                let respond = {
                    self.sendRawHeaders(on: connection, status: 200, statusText: "OK", headers: [
                        "Content-Type": self.mimeType(for: resolved),
                        "Content-Length": "\(fileSize)",
                        "Connection": connHeader
                    ], body: Data(), request: request, isWebDAV: true)
                }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            guard let handle = try? FileHandle(forReadingFrom: resolved) else {
                let respond = { self.sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            let header = """
            HTTP/1.1 200 OK\r\n\
            Content-Type: \(self.mimeType(for: resolved))\r\n\
            Content-Length: \(fileSize)\r\n\
            Connection: \(connHeader)\r\n\
            \r\n
            """

            let beginStream = {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    if error != nil { handle.closeFile(); connection.cancel(); return }
                    self.streamWebDAVFileData(handle: handle, on: connection, request: request,
                                              remaining: Int(fileSize), ioQueue: ioQueue)
                })
            }
            if let ioQueue { ioQueue.async(execute: beginStream) } else { beginStream() }
        }
    }

    private func streamWebDAVFileData(handle: FileHandle, on connection: NWConnection,
                                      request: HTTPRequest, remaining: Int,
                                      ioQueue: DispatchQueue?) {
        let chunkSize = 256 * 1024
        guard remaining > 0 else {
            handle.closeFile()
            finishResponse(on: connection, request: request, isWebDAV: true, forceClose: !request.wantsKeepAlive)
            return
        }

        let toRead = min(chunkSize, remaining)
        Self.diskIOQueue.async { [weak self] in
            let data = handle.readData(ofLength: toRead)
            guard !data.isEmpty else {
                handle.closeFile()
                if let ioQueue {
                    ioQueue.async { connection.cancel() }
                } else {
                    connection.cancel()
                }
                return
            }

            let sendChunk = {
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { handle.closeFile(); connection.cancel(); return }
                    self?.streamWebDAVFileData(handle: handle, on: connection, request: request,
                                               remaining: remaining - data.count, ioQueue: ioQueue)
                })
            }
            if let ioQueue { ioQueue.async(execute: sendChunk) } else { sendChunk() }
        }
    }

    private func handleWebDAVDelete(on connection: NWConnection, request: HTTPRequest, path: String) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request)
            return
        }
        let ioQueue = connectionIOQueue(for: connection)
        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.removeItem(at: resolved)
                let respond = { self.sendWebDAVResponse(on: connection, status: 204, statusText: "No Content", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            } catch {
                let respond = { self.sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            }
        }
    }

    private func handleMKCOL(on connection: NWConnection, request: HTTPRequest, path: String) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request)
            return
        }
        let ioQueue = connectionIOQueue(for: connection)
        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
                let respond = { self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            } catch {
                let respond = { self.sendWebDAVResponse(on: connection, status: 405, statusText: "Method Not Allowed", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            }
        }
    }

    private func handleMOVE(on connection: NWConnection, request: HTTPRequest, path: String) {
        performWebDAVTransfer(on: connection, request: request, sourcePath: path, copy: false)
    }

    private func handleCOPY(on connection: NWConnection, request: HTTPRequest, path: String) {
        performWebDAVTransfer(on: connection, request: request, sourcePath: path, copy: true)
    }

    private func handlePROPPATCH(on connection: NWConnection, request: HTTPRequest, path: String, body: Data) {
        _ = body
        guard path.isEmpty || resolvedPath(path, within: romsDirectory) != nil else {
            let status = isFinderProbePath(path) ? 404 : 403
            let text = status == 404 ? "Not Found" : "Forbidden"
            sendWebDAVResponse(on: connection, status: status, statusText: text, request: request)
            return
        }

        let href = path.isEmpty ? "/" : webDAVHref(for: romsDirectory.appendingPathComponent(path))
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
            <D:response>
                <D:href>\(href.xmlEscaped)</D:href>
                <D:propstat>
                    <D:prop/>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        sendRawHeaders(on: connection, status: 207, statusText: "Multi-Status", headers: [
            "Content-Type": "application/xml; charset=utf-8",
            "Content-Length": "\(data.count)"
        ], body: data, request: request, isWebDAV: true)
    }

    private enum WebDAVTransferFailure: Error {
        case forbidden
        case notFound
        case preconditionFailed
        case conflict
    }

    private func performWebDAVTransfer(on connection: NWConnection, request: HTTPRequest,
                                       sourcePath: String, copy: Bool) {
        guard !sourcePath.isEmpty, let source = resolvedPath(sourcePath, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request)
            return
        }

        guard let destination = webDAVResolvedDestination(from: request.headers["destination"] ?? "") else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request)
            return
        }

        let overwrite = webDAVOverwriteAllowed(request)
        let ioQueue = connectionIOQueue(for: connection)

        Self.diskIOQueue.async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: source.path) else {
                let respond = { self.sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
                return
            }

            switch self.performWebDAVFilesystemTransfer(copy: copy, source: source,
                                                        destination: destination, overwrite: overwrite) {
            case .success:
                self.notifyWebDAVResourceChanged(at: destination)
                let respond = { self.sendWebDAVResponse(on: connection, status: 204, statusText: "No Content", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            case .failure(.preconditionFailed):
                let respond = { self.sendWebDAVResponse(on: connection, status: 412, statusText: "Precondition Failed", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            case .failure(.forbidden):
                let respond = { self.sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            case .failure(.notFound):
                let respond = { self.sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            case .failure(.conflict):
                let respond = { self.sendWebDAVResponse(on: connection, status: 409, statusText: "Conflict", request: request) }
                if let ioQueue { ioQueue.async(execute: respond) } else { respond() }
            }
        }
    }

    private func performWebDAVFilesystemTransfer(copy: Bool, source: URL, destination: URL,
                                                 overwrite: Bool) -> Result<Void, WebDAVTransferFailure> {
        let fm = FileManager.default
        guard destination.path.hasPrefix(romsDirectory.standardized.path) else {
            return .failure(.forbidden)
        }

        if fm.fileExists(atPath: destination.path) {
            if !overwrite { return .failure(.preconditionFailed) }
            do {
                try fm.removeItem(at: destination)
            } catch {
                return .failure(.conflict)
            }
        }

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if copy {
                try fm.copyItem(at: source, to: destination)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
            return .success(())
        } catch {
            return .failure(.conflict)
        }
    }

    private func webDAVOverwriteAllowed(_ request: HTTPRequest) -> Bool {
        guard let value = request.headers["overwrite"]?.uppercased() else { return true }
        return value != "F"
    }

    private func webDAVResolvedDestination(from header: String) -> URL? {
        guard !header.isEmpty else { return nil }

        let rawPath: String
        if let url = URL(string: header), !url.path.isEmpty {
            rawPath = url.path.removingPercentEncoding ?? url.path
        } else {
            rawPath = header.removingPercentEncoding ?? header
        }

        var clean = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        if clean.hasSuffix("/") { clean = String(clean.dropLast()) }
        guard !clean.isEmpty else { return nil }
        return resolvedPath(clean, within: romsDirectory)
    }

    private func webDAVHref(for url: URL) -> String {
        let basePath = romsDirectory.standardized.path
        let itemPath = url.standardized.path
        let relative: String
        if itemPath == basePath {
            relative = ""
        } else if itemPath.hasPrefix(basePath + "/") {
            relative = String(itemPath.dropFirst(basePath.count + 1))
        } else {
            relative = url.lastPathComponent
        }

        if relative.isEmpty { return "/" }
        let encoded = relative.split(separator: "/").map { String($0).urlPathEscaped }.joined(separator: "/")
        return "/\(encoded)"
    }

    private func webDAVFormattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.webDAVISO8601Formatter.string(from: date)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "zip": return "application/zip"
        case "7z": return "application/x-7z-compressed"
        case "gz", "gzip": return "application/gzip"
        case "bz2": return "application/x-bzip2"
        case "tar": return "application/x-tar"
        case "xml": return "application/xml"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    private func isFinderProbePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name.hasPrefix("._") { return true }
        if lower.contains(".spotlight-v100") || lower.contains(".metadata_never_index") { return true }
        if lower.contains("backups.backupdb") || name == "mach_kernel" { return true }
        return false
    }

    private func notifyWebDAVResourceChanged(at url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let fileURL as URL in enumerator {
                let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isRegular {
                    postUploadCompleted(filePath: fileURL.path)
                }
            }
        } else {
            postUploadCompleted(filePath: url.path)
        }
    }

    private func handleWebDAVPutBuffered(on connection: NWConnection, request: HTTPRequest,
                                         path: String, body: Data) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden", request: request)
            return
        }
        let parent = resolved.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        postUploadStarted(path: resolved.path)
        guard let writer = SerialFileWriter(at: resolved) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error", request: request)
            return
        }
        writer.write(body)
        writer.finalize { [weak self] in
            self?.postUploadCompleted(filePath: resolved.path)
            self?.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
        }
    }

    // MARK: - Upload Notifications

    /// Post the upload-started notification using the SAME string the old
    /// GCDWebServer stack used, so existing observers keep working.
    private func postUploadStarted(path: String) {
        NotificationCenter.default.post(
            name: Notification.Name(PVWebServerFileUploadStartedNotificationName),
            object: nil, userInfo: ["path": path]
        )
    }

    private func postUploadCompleted(filePath: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs?[.size] as? UInt64) ?? 0
        NotificationCenter.default.post(
            name: Notification.Name(PVWebServerFileUploadCompletedNotificationName),
            object: nil, userInfo: ["filePath": filePath, "fileSize": fileSize]
        )
    }

    // MARK: - Response Helpers

    private func sendContinue(on connection: NWConnection, isWebDAV: Bool, request: HTTPRequest,
                              then work: @escaping () -> Void) {
        let header = "HTTP/1.1 100 Continue\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                return
            }
            work()
        })
    }

    private func finishResponse(on connection: NWConnection, request: HTTPRequest?,
                                isWebDAV: Bool, forceClose: Bool) {
        if forceClose {
            connection.cancel()
            return
        }

        let connID = ObjectIdentifier(connection)
        lock.lock()
        let ctx = connectionContexts[connID]
        let activeRequest = request ?? ctx?.activeRequest
        var pipelined = Data()
        if var live = ctx {
            pipelined = live.pendingPipelined
            live.pendingPipelined = Data()
            connectionContexts[connID] = live
        }
        lock.unlock()

        guard let ctx else {
            connection.cancel()
            return
        }

        if !pipelined.isEmpty {
            ctx.ioQueue.async { [weak self] in
                self?.processIncomingBuffer(on: connection, isWebDAV: ctx.isWebDAV, buffer: pipelined)
            }
            return
        }

        let keepAlive = activeRequest?.wantsKeepAlive ?? false
        if !keepAlive || ctx.readClosed {
            connection.cancel()
            return
        }
        scheduleReceive(on: connection, isWebDAV: isWebDAV, accumulated: Data())
    }

    private func sendRawThenStreamBody(on connection: NWConnection, status: Int, statusText: String,
                                         headers: [String: String], body: Data,
                                         request: HTTPRequest?, isWebDAV: Bool,
                                         forceClose: Bool = false) {
        let keepAlive = !forceClose && (request?.wantsKeepAlive ?? false)
        let connHeader = keepAlive ? "keep-alive" : "close"
        var header = "HTTP/1.1 \(status) \(statusText)\r\nConnection: \(connHeader)\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            self.streamResponseBody(body, on: connection, request: request, isWebDAV: isWebDAV,
                                    forceClose: forceClose || !keepAlive)
        })
    }

    private func streamResponseBody(_ body: Data, on connection: NWConnection,
                                    request: HTTPRequest?, isWebDAV: Bool,
                                    forceClose: Bool, offset: Int = 0) {
        let chunkSize = 256 * 1024
        guard offset < body.count else {
            finishResponse(on: connection, request: request, isWebDAV: isWebDAV, forceClose: forceClose)
            return
        }
        let end = min(offset + chunkSize, body.count)
        let chunk = body[offset..<end]
        connection.send(content: Data(chunk), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            self.streamResponseBody(body, on: connection, request: request, isWebDAV: isWebDAV,
                                    forceClose: forceClose, offset: end)
        })
    }

    private func sendResponse(on connection: NWConnection, status: Int, statusText: String,
                              body: String, contentType: String = "text/plain; charset=utf-8",
                              request: HTTPRequest? = nil, isWebDAV: Bool = false,
                              forceClose: Bool = false,
                              extraHeaders: [String: String] = [:]) {
        sendDataResponse(on: connection, status: status, statusText: statusText,
                         contentType: contentType, body: Data(body.utf8),
                         request: request, isWebDAV: isWebDAV, forceClose: forceClose,
                         extraHeaders: extraHeaders)
    }

    private func sendDataResponse(on connection: NWConnection, status: Int, statusText: String,
                                  contentType: String, body: Data,
                                  request: HTTPRequest? = nil, isWebDAV: Bool = false,
                                  forceClose: Bool = false,
                                  extraHeaders: [String: String] = [:]) {
        let keepAlive = !forceClose && (request?.wantsKeepAlive ?? false)
        let connHeader = keepAlive ? "keep-alive" : "close"
        var header = """
        HTTP/1.1 \(status) \(statusText)\r\n\
        Content-Type: \(contentType)\r\n\
        Content-Length: \(body.count)\r\n\
        Connection: \(connHeader)\r\n
        """
        for (key, value) in extraHeaders { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finishResponse(on: connection, request: request, isWebDAV: isWebDAV,
                                 forceClose: forceClose || !keepAlive)
        })
    }

    private func sendRawHeaders(on connection: NWConnection, status: Int, statusText: String,
                                headers: [String: String], body: Data,
                                request: HTTPRequest?, isWebDAV: Bool,
                                forceClose: Bool = false) {
        let keepAlive = !forceClose && (request?.wantsKeepAlive ?? false)
        let connHeader = keepAlive ? "keep-alive" : "close"
        var header = "HTTP/1.1 \(status) \(statusText)\r\nConnection: \(connHeader)\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finishResponse(on: connection, request: request, isWebDAV: isWebDAV,
                                 forceClose: forceClose || !keepAlive)
        })
    }

    private func sendWebDAVResponse(on connection: NWConnection, status: Int,
                                    statusText: String, body: String? = nil,
                                    request: HTTPRequest? = nil, forceClose: Bool = false) {
        let bodyData = body.map { Data($0.utf8) } ?? Data()
        let ct = body != nil ? "text/plain; charset=utf-8" : "text/plain"
        sendRawHeaders(on: connection, status: status, statusText: statusText, headers: [
            "Content-Type": ct,
            "Content-Length": "\(bodyData.count)"
        ], body: bodyData, request: request, isWebDAV: true, forceClose: forceClose)
    }

    private func sendJSON(on connection: NWConnection, status: Int, json: [String: Any],
                          request: HTTPRequest? = nil, isWebDAV: Bool = false,
                          forceClose: Bool = false) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        sendDataResponse(on: connection, status: status,
                         statusText: status == 200 ? "OK" : "Error",
                         contentType: "application/json", body: data,
                         request: request, isWebDAV: isWebDAV, forceClose: forceClose)
    }

    // MARK: - Path Safety

    private func resolvedPath(_ rawPath: String, within baseDir: URL) -> URL? {
        let resolved = baseDir.appendingPathComponent(rawPath).standardized
        let basePath = baseDir.standardized.path
        guard resolved.path == basePath || resolved.path.hasPrefix(basePath + "/") else { return nil }
        return resolved
    }

    // MARK: - IP Address

    func getLocalIPAddress() -> String? {
        if let cached = cachedIPAddress { return cached }
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let ifa_addr = interface.ifa_addr else { continue }
            let addrFamily = ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifa_addr, socklen_t(ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        cachedIPAddress = address
        return address
    }

    // MARK: - File Listing

    private struct FileEntry {
        let name: String
        let size: Int64
        let isDirectory: Bool
        let modified: Date
        let created: Date?
    }

    private func listFiles(in directory: URL) -> [FileEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey, .isDirectoryKey,
                .contentModificationDateKey, .creationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> FileEntry in
                let attrs = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .isDirectoryKey,
                    .contentModificationDateKey, .creationDateKey
                ])
                return FileEntry(
                    name: url.lastPathComponent,
                    size: Int64(attrs?.fileSize ?? 0),
                    isDirectory: attrs?.isDirectory ?? false,
                    modified: attrs?.contentModificationDate ?? .distantPast,
                    created: attrs?.creationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

// MARK: - Errors

enum ROMUploadServerError: Error, LocalizedError {
    case initializationFailed
    case startFailed(Error)

    var errorDescription: String? {
        switch self {
        case .initializationFailed: return "Failed to initialize upload server"
        case .startFailed(let error): return "Failed to start upload server: \(error.localizedDescription)"
        }
    }
}

// MARK: - HTTP Request Parsing

private struct HTTPRequest {
    let method: String
    let path: String
    let queryString: String?
    let httpVersion: String
    let headers: [String: String]

    var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

    /// Finder WebDAV PUT uses `Transfer-Encoding: chunked` instead of Content-Length.
    var isChunked: Bool {
        headers["transfer-encoding"]?.lowercased().contains("chunked") == true
    }

    var wantsKeepAlive: Bool {
        if let connection = headers["connection"]?.lowercased() {
            if connection.contains("close") { return false }
            if connection.contains("keep-alive") { return true }
        }
        return httpVersion.uppercased() == "HTTP/1.1"
    }

    var expectsContinue: Bool {
        headers["expect"]?.lowercased().contains("100-continue") == true
    }

    var queryParameters: [String: String] {
        guard let qs = queryString else { return [:] }
        var params: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : ""
            params[key] = value
        }
        return params
    }

    var multipartBoundary: String? {
        guard let ct = headers["content-type"],
              ct.lowercased().contains("multipart/form-data") else { return nil }
        for part in ct.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return boundary
            }
        }
        return nil
    }

    static func parse(_ headerString: String) -> HTTPRequest? {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let rawURI = String(parts[1])
        let version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"

        let (path, query): (String, String?)
        if let qIdx = rawURI.firstIndex(of: "?") {
            path = String(rawURI[rawURI.startIndex..<qIdx])
            query = String(rawURI[rawURI.index(after: qIdx)...])
        } else {
            path = rawURI
            query = nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return HTTPRequest(method: method, path: path, queryString: query,
                           httpVersion: version, headers: headers)
    }
}

// MARK: - Streaming Multipart Parser

private final class StreamingMultipartParser {
    private let boundary: Data
    private let endBoundary: Data
    private let outputDirectory: URL
    private let onFileCompleted: ((String) -> Void)?
    private var buffer = Data()
    private var state: ParserState = .seekingBoundary
    private var currentFilename: String?
    private var currentWriter: SerialFileWriter?
    private var currentFilePath: URL?
    private(set) var completedFiles: [String] = []
    private var pendingCloses = 0
    private var finalizeCompletion: (() -> Void)?

    private let headerEndMarker = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private enum ParserState { case seekingBoundary, readingHeaders, readingBody, done }

    init(boundary: String, outputDirectory: URL, onFileCompleted: ((String) -> Void)? = nil) {
        self.boundary = Data("--\(boundary)".utf8)
        self.endBoundary = Data("--\(boundary)--".utf8)
        self.outputDirectory = outputDirectory
        self.onFileCompleted = onFileCompleted
    }

    func feed(_ data: Data) { buffer.append(data); process() }

    func finalize(completion: @escaping () -> Void) {
        if state == .readingBody { flushBodyBuffer(isFinal: true) }
        closeCurrentFile()
        if pendingCloses == 0 {
            completion()
        } else {
            finalizeCompletion = completion
        }
    }

    private func process() {
        while true {
            switch state {
            case .seekingBoundary:
                guard let range = buffer.findRange(of: boundary) else { return }
                let afterBoundary = range.upperBound
                guard afterBoundary + 2 <= buffer.endIndex else { return }
                if buffer[afterBoundary...].starts(with: Data("--".utf8)) { state = .done; return }
                buffer = Data(buffer[afterBoundary...])
                if buffer.starts(with: Data([0x0D, 0x0A])) { buffer = Data(buffer.dropFirst(2)) }
                state = .readingHeaders

            case .readingHeaders:
                guard let headerEnd = buffer.findRange(of: headerEndMarker) else { return }
                let headersData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                buffer = Data(buffer[headerEnd.upperBound...])

                let headersStr = String(data: headersData, encoding: .utf8) ?? ""
                currentFilename = extractFilename(from: headersStr)

                if let filename = currentFilename, !filename.isEmpty {
                    let sanitized = URL(fileURLWithPath: filename).lastPathComponent
                    guard !sanitized.isEmpty, !sanitized.hasPrefix(".") else {
                        currentFilename = nil
                        state = .readingBody
                        continue
                    }
                    currentFilename = sanitized
                    let filePath = outputDirectory.appendingPathComponent(sanitized)
                    currentFilePath = filePath
                    currentWriter = SerialFileWriter(at: filePath)
                    NotificationCenter.default.post(
                        name: Notification.Name(PVWebServerFileUploadStartedNotificationName),
                        object: nil, userInfo: ["path": filePath.path]
                    )
                }
                state = .readingBody

            case .readingBody:
                flushBodyBuffer(isFinal: false)
                if state != .readingBody { continue }
                return

            case .done:
                return
            }
        }
    }

    private func flushBodyBuffer(isFinal: Bool) {
        if let range = buffer.findRange(of: boundary) {
            var endIdx = range.lowerBound
            if endIdx >= 2 {
                let crlfCheck = buffer[endIdx - 2 ..< endIdx]
                if crlfCheck == Data([0x0D, 0x0A]) { endIdx -= 2 }
            }
            let bodyChunk = buffer[buffer.startIndex..<endIdx]
            currentWriter?.write(bodyChunk)
            closeCurrentFile()

            buffer = Data(buffer[range.upperBound...])
            if buffer.starts(with: Data("--".utf8)) {
                state = .done
            } else {
                if buffer.starts(with: Data([0x0D, 0x0A])) { buffer = Data(buffer.dropFirst(2)) }
                state = .readingHeaders
            }
        } else if isFinal {
            if !buffer.isEmpty { currentWriter?.write(buffer); buffer = Data() }
            closeCurrentFile()
        } else {
            let safeSize = boundary.count + 4
            if buffer.count > safeSize {
                let writeCount = buffer.count - safeSize
                let chunk = buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: writeCount)]
                currentWriter?.write(chunk)
                buffer = Data(buffer[buffer.index(buffer.startIndex, offsetBy: writeCount)...])
            }
        }
    }

    private func closeCurrentFile() {
        guard let writer = currentWriter else { return }
        let path = currentFilePath?.path
        let filename = currentFilename
        currentWriter = nil
        currentFilename = nil
        currentFilePath = nil
        pendingCloses += 1
        writer.finalize { [weak self] in
            guard let self else { return }
            if let path, filename != nil {
                self.completedFiles.append(path)
                self.onFileCompleted?(path)
            }
            self.pendingCloses -= 1
            if self.pendingCloses == 0, let completion = self.finalizeCompletion {
                self.finalizeCompletion = nil
                completion()
            }
        }
    }

    private func extractFilename(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            guard line.lowercased().contains("content-disposition") else { continue }
            for component in line.components(separatedBy: ";") {
                let trimmed = component.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("filename=") {
                    var name = String(trimmed.dropFirst("filename=".count))
                    name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return name.isEmpty ? nil : name
                }
            }
        }
        return nil
    }
}

// MARK: - Data Extension

private extension Data {
    func findRange(of pattern: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, pattern.count <= self.count else { return nil }
        let end = self.count - pattern.count
        for i in 0...end {
            let slice = self[self.index(self.startIndex, offsetBy: i) ..<
                             self.index(self.startIndex, offsetBy: i + pattern.count)]
            if slice == pattern {
                let start = self.index(self.startIndex, offsetBy: i)
                let stop = self.index(start, offsetBy: pattern.count)
                return start..<stop
            }
        }
        return nil
    }
}

// MARK: - String Extensions

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - HTML Upload Page

extension ROMUploadServer {
    static func uploadPageHTML(title: String, ipAddress: String, httpPort: String,
                               davPort: String, fileRows: String,
                               currentPath: String = "",
                               initialEntriesJSON: String = "[]") -> String {
        let uploadTarget = currentPath.isEmpty
            ? "/upload"
            : "/upload?path=\(currentPath.urlPathEscaped)"
        let locationLabel = currentPath.isEmpty ? "base folder" : currentPath.htmlEscaped
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title) - File Upload</title>
          <style>
            :root {
              color-scheme: dark;
              --bg: #0f0f1a; --surface: #1a1a2e; --border: #2a2a4a;
              --text: #e0e0e0; --text-muted: #8899aa;
              --accent: #4a90d9; --accent-hover: #5ba3ec;
              --success: #27ae60; --danger: #c0392b;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
              max-width: 900px; margin: 0 auto; padding: 24px;
              background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }
            header { display: flex; align-items: center; gap: 16px;
              padding-bottom: 20px; margin-bottom: 24px; border-bottom: 2px solid var(--accent); }
            header .logo { font-size: 36px; }
            header h1 { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
            header .sub { color: var(--text-muted); font-size: 13px; margin-top: 2px; }
            .card { background: var(--surface); border: 1px solid var(--border);
              border-radius: 12px; padding: 20px; margin-bottom: 20px;
              box-shadow: 0 2px 12px rgba(0,0,0,0.3); }
            .card h2 { font-size: 12px; font-weight: 600; color: var(--text-muted);
              text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 14px; }
            .info-row { display: flex; gap: 20px; flex-wrap: wrap; font-size: 13px; color: var(--text-muted); }
            .info-row code { background: var(--bg); border: 1px solid var(--border);
              padding: 3px 8px; border-radius: 4px; color: var(--accent); }
            .info-row label { font-weight: 500; }
            .drop-zone { border: 2px dashed var(--border); border-radius: 12px;
              padding: 32px 20px; text-align: center; transition: all 0.2s; cursor: pointer;
              background: rgba(74,144,217,0.03); }
            .drop-zone.hover { border-color: var(--accent); background: rgba(74,144,217,0.12);
              box-shadow: 0 0 20px rgba(74,144,217,0.15); }
            .drop-zone .lead { font-weight: 600; font-size: 16px; margin-bottom: 8px; }
            .drop-zone p { color: var(--text-muted); font-size: 13px; }
            .btn { display: inline-block; padding: 8px 16px; border-radius: 6px;
              font-size: 14px; font-weight: 500; cursor: pointer; border: 1px solid transparent;
              transition: all 0.15s; text-decoration: none; color: inherit; }
            .btn-primary { background: var(--accent); color: #fff; }
            .btn-primary:hover { background: var(--accent-hover); }
            .btn-sm { padding: 4px 10px; font-size: 13px; }
            .btn-danger { background: var(--danger); color: #fff; }
            .btn-danger:hover { filter: brightness(1.15); }
            .toolbar { display: flex; gap: 8px; align-items: center; margin-top: 14px; }
            #progress-container { margin-top: 16px; display: none; }
            #progress-bar { width: 100%; height: 8px; background: var(--bg);
              border-radius: 4px; overflow: hidden; }
            #progress-fill { height: 100%;
              background: linear-gradient(90deg, var(--accent), var(--success));
              width: 0%; transition: width 0.15s; }
            #status { margin-top: 6px; font-size: 13px; color: var(--text-muted); }
            #status-detail { margin-top: 4px; font-size: 12px; color: var(--success); min-height: 1.2em; }
            #toast-container { position: fixed; top: 16px; right: 16px; z-index: 9999;
              display: flex; flex-direction: column; gap: 8px; pointer-events: none; }
            .toast { background: var(--surface); border: 1px solid var(--border);
              border-left: 3px solid var(--accent); border-radius: 8px; padding: 10px 14px;
              font-size: 13px; box-shadow: 0 4px 16px rgba(0,0,0,0.35);
              animation: toast-in 0.2s ease; max-width: 320px; word-break: break-word; }
            .toast-success { border-left-color: var(--success); }
            .toast-error { border-left-color: var(--danger); }
            .toast.fade { opacity: 0; transition: opacity 0.3s; }
            @keyframes toast-in { from { opacity: 0; transform: translateY(-8px); }
              to { opacity: 1; transform: translateY(0); } }
            table { width: 100%; border-collapse: collapse; margin-top: 10px; }
            thead th { text-align: left; padding: 8px 10px; font-size: 11px; font-weight: 600;
              color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px;
              border-bottom: 1px solid var(--border); user-select: none; }
            thead th.sortable { cursor: pointer; }
            thead th.sortable:hover { color: var(--text); }
            thead th.sort-active { color: var(--accent); }
            .sort-indicator { margin-left: 4px; opacity: 0.85; }
            tbody tr { border-bottom: 1px solid var(--border); transition: background 0.12s; }
            tbody tr:hover { background: rgba(74,144,217,0.06); }
            td { padding: 10px; font-size: 14px; vertical-align: middle; }
            td a { color: var(--accent); text-decoration: none; }
            td a:hover { text-decoration: underline; }
            .empty { color: var(--text-muted); text-align: center; padding: 28px 16px; font-size: 14px; }
            td:last-child { text-align: right; white-space: nowrap; }
            @media (max-width: 600px) { body { padding: 12px; } .info-row { flex-direction: column; gap: 6px; } }
          </style>
        </head>
        <body>
          <header>
            <div class="logo">&#x1F3AE;</div>
            <div>
              <h1>\(title) &mdash; File Upload</h1>
              <p class="sub">Transfer ROMs, disc images, BIOS files, and saves from any device on your network.</p>
            </div>
          </header>

          <div class="card">
            <h2>Server Info</h2>
            <div class="info-row">
              <div><label>HTTP:</label> <code>http://\(ipAddress)\(httpPort)/</code></div>
              <div><label>WebDAV:</label> <code>http://\(ipAddress):\(davPort)/</code></div>
            </div>
          </div>

          <div class="card">
            <h2>Upload Files &mdash; \(locationLabel)</h2>
            <div class="drop-zone" id="drop-zone">
              <p class="lead">Drop files here to upload</p>
              <p>Uploading to: <code>\(locationLabel)</code></p>
            </div>
            <div class="toolbar">
              <button class="btn btn-primary" id="upload-btn">Upload Files</button>
              <input type="file" id="file-input" multiple style="display:none">
            </div>
            <div id="progress-container">
              <div id="progress-bar"><div id="progress-fill"></div></div>
              <div id="status"></div>
              <div id="status-detail"></div>
            </div>
          </div>

          <div id="toast-container"></div>

          <div class="card">
            <h2>Files &mdash; \(locationLabel)</h2>
            <table>
              <thead><tr>
                <th class="sortable" data-sort="name" id="sort-name">Name<span class="sort-indicator"></span></th>
                <th class="sortable sort-active" data-sort="modified" id="sort-modified">Modified<span class="sort-indicator"></span></th>
                <th class="sortable" data-sort="size" id="sort-size">Size<span class="sort-indicator"></span></th>
                <th></th>
              </tr></thead>
              <tbody id="file-list">
                \(fileRows)
              </tbody>
            </table>
          </div>

          <script>
            const zone = document.getElementById('drop-zone');
            const currentPath = '\(currentPath.jsEscaped)';
            const uploadTarget = '\(uploadTarget)';
            const maxConcurrent = 3;

            zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('hover'); });
            zone.addEventListener('dragleave', () => zone.classList.remove('hover'));
            zone.addEventListener('drop', e => {
              e.preventDefault(); zone.classList.remove('hover');
              enqueueFiles(e.dataTransfer.files);
            });
            document.getElementById('upload-btn').addEventListener('click', () => {
              document.getElementById('file-input').click();
            });
            document.getElementById('file-input').addEventListener('change', e => {
              enqueueFiles(e.target.files);
              e.target.value = '';
            });

            let cachedEntries = \(initialEntriesJSON);
            let sortColumn = 'modified';
            let sortAsc = false;
            const uploadQueue = [];
            let activeWorkers = 0;
            let batchTotal = 0;
            let batchCompleted = 0;
            let nextUploadId = 0;
            const activeUploads = new Map();
            const recentCompleted = [];
            let reloadTimer = null;
            let refreshTimer = null;

            document.querySelectorAll('thead th.sortable').forEach(th => {
              th.addEventListener('click', () => setSort(th.dataset.sort));
            });
            updateSortHeaders();
            renderFileRows(cachedEntries);

            function formatSize(bytes) {
              if (!bytes || bytes === 0) return '0 B';
              const units = ['B', 'KB', 'MB', 'GB', 'TB'];
              const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
              return (bytes / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0) + ' ' + units[i];
            }

            function formatDate(ts) {
              if (!ts) return '—';
              return new Date(ts * 1000).toLocaleString(undefined, {
                year: 'numeric', month: 'short', day: 'numeric',
                hour: 'numeric', minute: '2-digit'
              });
            }

            function setSort(column) {
              if (sortColumn === column) {
                sortAsc = !sortAsc;
              } else {
                sortColumn = column;
                sortAsc = column === 'name';
              }
              updateSortHeaders();
              renderFileRows(cachedEntries);
            }

            function updateSortHeaders() {
              document.querySelectorAll('thead th.sortable').forEach(th => {
                const col = th.dataset.sort;
                const active = col === sortColumn;
                th.classList.toggle('sort-active', active);
                const indicator = th.querySelector('.sort-indicator');
                if (indicator) indicator.textContent = active ? (sortAsc ? '▲' : '▼') : '';
              });
            }

            function sortEntries(entries) {
              const dirs = entries.filter(e => e.isDirectory);
              const files = entries.filter(e => !e.isDirectory);
              const cmp = (a, b) => {
                let n = 0;
                if (sortColumn === 'name') {
                  n = a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
                } else if (sortColumn === 'size') {
                  n = (a.size || 0) - (b.size || 0);
                } else {
                  n = (a.modified || 0) - (b.modified || 0);
                }
                if (n === 0) n = a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
                return sortAsc ? n : -n;
              };
              dirs.sort(cmp);
              files.sort(cmp);
              return [...dirs, ...files];
            }

            function renderFileRows(entries) {
              const tbody = document.getElementById('file-list');
              const sorted = sortEntries(entries || []);
              let html = '';
              if (currentPath) {
                const parts = currentPath.split('/');
                parts.pop();
                const parent = parts.join('/');
                const parentHref = parent ? '/?path=' + encodeURIComponent(parent) : '/';
                html += '<tr><td><a href="' + parentHref + '">&#x2B05;&#xFE0F; ..</a></td><td></td><td></td><td></td></tr>';
              }
              if (!sorted.length) {
                html += '<tr><td colspan="4" class="empty">No files yet. Drag and drop above to upload!</td></tr>';
              } else {
                for (const entry of sorted) {
                  const childSub = currentPath ? currentPath + '/' + entry.name : entry.name;
                  const enc = encodeURIComponent(childSub);
                  const escapedName = entry.name.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                  if (entry.isDirectory) {
                    html += '<tr><td><a href="/?path=' + enc + '">&#x1F4C1; ' + escapedName + '</a></td>';
                    html += '<td>—</td><td>—</td><td></td></tr>';
                  } else {
                    html += '<tr><td><a href="/files/' + enc + '" download>' + escapedName + '</a></td>';
                    html += '<td>' + formatDate(entry.modified) + '</td>';
                    html += '<td>' + formatSize(entry.size) + '</td>';
                    html += '<td><a href="/files/' + enc + '" download class="btn btn-sm">Download</a> ';
                    html += '<button onclick="deleteFile(\\'' + childSub.replace(/'/g, "\\\\'") + '\\')" class="btn btn-sm btn-danger">Delete</button></td></tr>';
                  }
                }
              }
              tbody.innerHTML = html;
            }

            function showToast(message, isSuccess) {
              const container = document.getElementById('toast-container');
              const el = document.createElement('div');
              el.className = 'toast ' + (isSuccess ? 'toast-success' : 'toast-error');
              el.textContent = message;
              container.appendChild(el);
              setTimeout(() => {
                el.classList.add('fade');
                setTimeout(() => el.remove(), 300);
              }, 2800);
            }

            function updateStatusDetail() {
              const detail = document.getElementById('status-detail');
              if (!detail) return;
              if (recentCompleted.length === 0) {
                detail.textContent = '';
                return;
              }
              const shown = recentCompleted.slice(0, 3);
              const suffix = recentCompleted.length > 3 ? ' +' + (recentCompleted.length - 3) + ' more' : '';
              detail.textContent = 'Finished: ' + shown.join(', ') + suffix;
            }

            function refreshFileList() {
              const pathQuery = currentPath ? '?path=' + encodeURIComponent(currentPath) : '';
              fetch('/api/list' + pathQuery)
                .then(r => r.ok ? r.json() : Promise.reject())
                .then(data => {
                  cachedEntries = data.entries || [];
                  renderFileRows(cachedEntries);
                })
                .catch(() => {});
            }

            function scheduleRefresh() {
              if (refreshTimer) return;
              refreshTimer = setTimeout(() => {
                refreshTimer = null;
                refreshFileList();
              }, 2500);
            }

            function enqueueFiles(files) {
              if (!files || !files.length) return;
              if (reloadTimer) { clearTimeout(reloadTimer); reloadTimer = null; }
              const wasIdle = activeWorkers === 0 && uploadQueue.length === 0;
              for (let k = 0; k < files.length; k++) uploadQueue.push(files[k]);
              if (wasIdle) {
                batchCompleted = 0;
                batchTotal = uploadQueue.length;
                activeUploads.clear();
                recentCompleted.length = 0;
                updateStatusDetail();
              } else {
                batchTotal += files.length;
              }
              const container = document.getElementById('progress-container');
              container.style.display = 'block';
              pumpQueue();
            }

            function updateProgress() {
              const fill = document.getElementById('progress-fill');
              const status = document.getElementById('status');
              let inFlightFraction = 0;
              const activeNames = [];
              for (const upload of activeUploads.values()) {
                if (upload.total > 0) inFlightFraction += upload.loaded / upload.total;
                activeNames.push(upload.name);
              }
              const inFlightCount = activeUploads.size;
              const queued = Math.max(0, batchTotal - batchCompleted - inFlightCount);
              const pct = batchTotal > 0
                ? ((batchCompleted + inFlightFraction) / batchTotal * 100)
                : 0;
              const pctRounded = Math.round(Math.min(100, pct));
              fill.style.width = pctRounded + '%';

              if (batchTotal === 0) {
                status.textContent = '';
              } else if (inFlightCount === 0 && batchCompleted === batchTotal) {
                status.textContent = 'All ' + batchTotal + ' files uploaded';
              } else if (inFlightCount === 0) {
                status.textContent = batchCompleted + '/' + batchTotal + ' complete · ' + queued + ' queued';
              } else {
                const parts = [inFlightCount + ' uploading'];
                if (queued > 0) parts.push(queued + ' queued');
                parts.push(batchCompleted + '/' + batchTotal + ' complete');
                parts.push(pctRounded + '%');
                status.textContent = parts.join(' · ');
              }
              updateStatusDetail();
            }

            function pumpQueue() {
              while (activeWorkers < maxConcurrent && uploadQueue.length) {
                const file = uploadQueue.shift();
                activeWorkers++;
                const uploadId = nextUploadId++;
                activeUploads.set(uploadId, { name: file.name, loaded: 0, total: file.size || 0 });
                const fd = new FormData();
                fd.append('files[]', file, file.name);
                const xhr = new XMLHttpRequest();
                xhr.upload.onprogress = (e) => {
                  if (e.lengthComputable) {
                    activeUploads.set(uploadId, { name: file.name, loaded: e.loaded, total: e.total });
                    updateProgress();
                  }
                };
                xhr.onload = xhr.onerror = () => {
                  activeUploads.delete(uploadId);
                  activeWorkers--;
                  const ok = xhr.status >= 200 && xhr.status < 300;
                  if (ok) {
                    batchCompleted++;
                    recentCompleted.unshift(file.name);
                    if (recentCompleted.length > 8) recentCompleted.pop();
                    showToast('Uploaded ' + file.name, true);
                  } else {
                    showToast('Failed: ' + file.name, false);
                  }
                  updateProgress();
                  scheduleRefresh();
                  pumpQueue();
                  if (activeWorkers === 0 && uploadQueue.length === 0) {
                    finishBatch();
                  }
                };
                xhr.open('POST', uploadTarget);
                xhr.send(fd);
                updateProgress();
              }
            }

            function finishBatch() {
              const container = document.getElementById('progress-container');
              const fill = document.getElementById('progress-fill');
              const status = document.getElementById('status');
              fill.style.width = '100%';
              status.textContent = 'Done — ' + batchCompleted + ' of ' + batchTotal + ' uploaded';
              updateStatusDetail();
              reloadTimer = setTimeout(() => {
                container.style.display = 'none';
                fill.style.width = '0%';
                status.textContent = '';
                document.getElementById('status-detail').textContent = '';
                batchTotal = 0;
                batchCompleted = 0;
                activeUploads.clear();
                recentCompleted.length = 0;
                location.reload();
              }, 2000);
            }

            function deleteFile(name) {
              if (!confirm('Delete "' + name + '"?')) return;
              fetch('/files/' + encodeURIComponent(name), { method: 'DELETE' })
                .then(r => { if (r.ok) refreshFileList(); else alert('Delete failed'); })
                .catch(() => alert('Delete failed'));
            }
          </script>
        </body>
        </html>
        """
    }
}
