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
        var clientMode: WebServerClientMode = .unknown
        var firstRequestSeen = false
        var didArmInitialReceive = false
        var watchdog: DispatchSourceTimer?
        /// Serializes receive/send callbacks for this socket (Finder pipelines on keep-alive).
        let ioQueue: DispatchQueue
        var activeRequest: HTTPRequest?
        /// Prevents concurrent `NWConnection.receive` on one socket (POSIX 96 if doubled).
        var isReceiving: Bool = false
        var readClosed: Bool = false
        var pendingPipelined: Data = Data()
    }

    // MARK: - Configuration

    /// Ports tried in order until one binds. Port 80 keeps the URL short on device.
    #if targetEnvironment(simulator)
    static let preferredPorts: [UInt16] = [8080, 8000, 8888, 9000]
    #else
    static let preferredPorts: [UInt16] = [80, 8080, 8000, 8888, 9000]
    #endif
    /// The port the listener bound, 0 while stopped.
    private(set) var port: UInt16 = 0
    /// A socket that connects but never delivers a request within this window is cancelled
    /// so `mount_webdav` retries on a fresh connection instead of hanging.
    private static let firstRequestGraceSeconds: TimeInterval = 12
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

    private var listener: NWListener?
    private var bonjourWebDAV: NetService?
    private let bonjourDelegate = WebDAVBonjourDelegate()
    /// Guards `start()` against a second concurrent call while the port-fallback loop is running.
    private var isStarting = false
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
        guard isRunningUnlocked, let ip = getLocalIPAddress() else { return nil }
        return URL(string: "http://\(ip)\(Self.portSuffix(for: port))/")
    }

    private var isRunningUnlocked: Bool { listener?.state == .ready }

    // MARK: - Public API

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunningUnlocked
    }

    /// Synchronous helpers so `start()` (an `async` function) never calls `NSLock.lock()`/
    /// `unlock()` directly from its own body — those are `noasync` and warn (error in Swift 6
    /// mode) when called straight from an async context, even in a `defer`.
    private func beginStartingIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isRunningUnlocked, !isStarting else { return false }
        isStarting = true
        return true
    }

    private func endStarting() {
        lock.lock(); defer { lock.unlock() }
        isStarting = false
    }

    var serverURL: URL? {
        guard isRunning, let ip = getLocalIPAddress() else { return nil }
        return URL(string: "http://\(ip)\(Self.portSuffix(for: port))/")
    }

    static func portSuffix(for port: UInt16) -> String { port == 80 ? "" : ":\(port)" }

    var ipAddress: String? { getLocalIPAddress() }

    // MARK: - Init

    init(romsDirectory: URL) {
        self.romsDirectory = romsDirectory

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

    /// Bind one listener on the first free port in `preferredPorts` and wait for `.ready`.
    /// Advertises `_http._tcp` through the listener and `_webdav._tcp` through NetService on
    /// the same name and port; mDNSResponder coalesces them.
    func start() async throws {
        guard beginStartingIfNeeded() else { return }
        defer { endStarting() }

        var lastError: Error?
        for candidate in Self.preferredPorts {
            do {
                try await startListener(on: candidate)
                advertiseWebDAV(on: candidate)
                let root = romsDirectory
                Self.diskIOQueue.async {
                    _ = try? FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])
                }
                NSLog("[ROMUploadServer] started on :\(candidate)")
                return
            } catch {
                lastError = error
                NSLog("[ROMUploadServer] port \(candidate) unavailable (\(error)), trying next")
            }
        }
        throw lastError ?? ROMUploadServerError.initializationFailed
    }

    /// Binds and waits for `.ready` on `candidate`. On failure the listener that failed is
    /// cancelled here and the error is thrown; nothing global (`stop()`) is touched so a later
    /// candidate's listener, or an already-running server, is left alone.
    private func startListener(on candidate: UInt16) async throws {
        let listener = try NWListener(using: Self.makeTCPParameters(), on: NWEndpoint.Port(rawValue: candidate)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handleNewConnection(conn) }
        listener.service = NWListener.Service(name: pageTitle, type: "_http._tcp")
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self, case let .add(endpoint) = change, case let .hostPort(host, port) = endpoint else { return }
            let hostStr: String
            switch host {
            case .name(let n, _): hostStr = n
            case .ipv4(let a): hostStr = "\(a)"
            case .ipv6(let a): hostStr = "\(a)"
            @unknown default: return
            }
            self.lock.lock()
            self._bonjourServerURL = URL(string: "http://\(hostStr)\(Self.portSuffix(for: port.rawValue))/")
            self.lock.unlock()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    NSLog("[ROMUploadServer] listener failed on :\(candidate): \(error)")
                    listener?.cancel()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: ROMUploadServerError.initializationFailed) }
                default:
                    break
                }
            }
            listener.start(queue: self.listenerQueue)
        }
        port = candidate
        self.listener = listener
    }

    private func advertiseWebDAV(on candidate: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `stop()` may have run (and torn the listener down) before this hop lands on the
            // main queue; publishing here would orphan a Bonjour record for a dead port.
            guard self.isRunning, self.port == candidate else { return }
            let service = NetService(domain: "", type: "_webdav._tcp.", name: self.pageTitle, port: Int32(candidate))
            service.delegate = self.bonjourDelegate
            service.schedule(in: .main, forMode: .common)
            service.publish()
            self.lock.lock(); self.bonjourWebDAV = service; self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let conns = activeConnections
        let contexts = connectionContexts
        let webDAVService = bonjourWebDAV
        activeConnections.removeAll()
        connectionContexts.removeAll()
        _bonjourServerURL = nil
        bonjourWebDAV = nil
        lock.unlock()

        for ctx in contexts.values { ctx.watchdog?.cancel() }
        for conn in conns.values { conn.cancel() }
        listener?.cancel()
        listener = nil
        if let webDAVService {
            DispatchQueue.main.async { webDAVService.stop() }
        }
        port = 0
        cachedIPAddress = nil
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

    private func handleNewConnection(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        let ioQueue = DispatchQueue(label: "org.dolphin.iCube.uploadserver.conn.\(connID)")

        let watchdog = DispatchSource.makeTimerSource(queue: ioQueue)
        watchdog.schedule(deadline: .now() + Self.firstRequestGraceSeconds)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let seen = self.connectionContexts[connID]?.firstRequestSeen ?? true
            self.lock.unlock()
            guard !seen else { return }
            NSLog("[ROMUploadServer] connection stalled at establishment; cancelling so the client retries")
            connection.cancel()
        }

        lock.lock()
        activeConnections[connID] = connection
        var ctx = ConnectionContext(ioQueue: ioQueue, activeRequest: nil)
        ctx.watchdog = watchdog
        connectionContexts[connID] = ctx
        lock.unlock()
        watchdog.resume()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.armInitialReceiveIfNeeded(on: connection)
            case .waiting(let error):
                NSLog("[ROMUploadServer] inbound connection waiting: \(error)")
            case .cancelled, .failed:
                self.lock.lock()
                self.activeConnections.removeValue(forKey: connID)
                let dead = self.connectionContexts.removeValue(forKey: connID)
                self.lock.unlock()
                dead?.watchdog?.cancel()
            default:
                break
            }
        }
        connection.start(queue: ioQueue)
    }

    private func armInitialReceiveIfNeeded(on connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        guard var ctx = connectionContexts[connID], !ctx.didArmInitialReceive else { lock.unlock(); return }
        ctx.didArmInitialReceive = true
        let ioQueue = ctx.ioQueue
        connectionContexts[connID] = ctx
        lock.unlock()
        ioQueue.async { [weak self] in self?.scheduleReceive(on: connection, accumulated: Data()) }
    }

    private func noteFirstRequest(on connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        guard var ctx = connectionContexts[connID], !ctx.firstRequestSeen else { lock.unlock(); return }
        ctx.firstRequestSeen = true
        let watchdog = ctx.watchdog
        ctx.watchdog = nil
        connectionContexts[connID] = ctx
        lock.unlock()
        watchdog?.cancel()
    }

    /// Classify and remember this connection's mode.
    private func isWebDAVRequest(_ request: HTTPRequest, connection: NWConnection) -> Bool {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        let stored = connectionContexts[connID]?.clientMode ?? .unknown
        let mode = WebServerClientMode.resolve(request, stored: stored)
        if var ctx = connectionContexts[connID] {
            ctx.clientMode = mode
            connectionContexts[connID] = ctx
        }
        lock.unlock()
        return mode == .webDAV
    }

    /// Arm a single `receive` or process bytes already buffered (pipelined keep-alive).
    private func scheduleReceive(on connection: NWConnection,
                                   accumulated: Data) {
        if !accumulated.isEmpty {
            processIncomingBuffer(on: connection, buffer: accumulated)
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
                self?.scheduleReceive(on: connection, accumulated: accumulated)
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
            self.processIncomingBuffer(on: connection, buffer: buffer)
        }
    }

    /// Parse buffered bytes into HTTP requests; may leave pipelined tail for keep-alive.
    private func processIncomingBuffer(on connection: NWConnection,
                                       buffer: Data) {
        let headerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        if let headerEnd {
            let headersData = buffer[buffer.startIndex..<headerEnd.lowerBound]
            let bodyStart = buffer[headerEnd.upperBound...]

            guard let headersStr = String(data: headersData, encoding: .utf8),
                  let request = HTTPRequest.parse(headersStr) else {
                sendResponse(on: connection, status: 400, statusText: "Bad Request", body: "Bad Request",
                             isWebDAV: false, forceClose: true)
                return
            }

            noteFirstRequest(on: connection)
            let isWebDAV = isWebDAVRequest(request, connection: connection)

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
                         body: "Headers too large", isWebDAV: false, forceClose: true)
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
                    self.processIncomingBuffer(on: connection, buffer: grown)
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

        if !isWebDAV && request.method == "PUT" && request.path.hasPrefix("/files/") {
            let beginPut: () -> Void = { [weak self] in
                self?.streamBrowserFilePut(on: connection, request: request,
                                           initialBody: initialBody, remaining: remaining)
            }
            if request.expectsContinue {
                sendContinue(on: connection, isWebDAV: false, request: request, then: beginPut)
            } else {
                beginPut()
            }
            return
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
    final class ChunkedBodyReader: @unchecked Sendable {
        enum Event {
            case payload(Data)
            case complete(trailing: Data)
            case invalid
        }

        private var buffer = Data()
        private var chunkRemaining = 0
        private var finished = false
        /// The `0` chunk has been read but its terminating CRLF (and any trailer fields) have
        /// not arrived yet. The body is NOT complete until they are consumed — a terminator
        /// split across TCP segments used to emit a premature `.complete` on the first feed.
        private var awaitingTerminator = false

        func feed(_ incoming: Data) -> [Event] {
            guard !finished else { return [] }
            if !incoming.isEmpty { buffer.append(incoming) }
            var events: [Event] = []

            parsing: while !finished {
                if awaitingTerminator {
                    guard let trailing = consumeTerminator() else { break parsing }
                    finished = true
                    events.append(.complete(trailing: trailing))
                    break
                }

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
                    awaitingTerminator = true
                    continue
                }
                chunkRemaining = size
            }
            return events
        }

        /// RFC 9112 §7.1.2: the last-chunk line is followed by optional trailer fields and a
        /// final CRLF. Consumes them and returns whatever bytes follow (a pipelined request),
        /// or `nil` when the terminator has not fully arrived yet.
        private func consumeTerminator() -> Data? {
            if buffer.starts(with: Data([0x0D, 0x0A])) {
                buffer.removeFirst(2)
            } else if let trailerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                buffer.removeSubrange(buffer.startIndex..<trailerEnd.upperBound)
            } else {
                return nil
            }
            let trailing = buffer
            buffer = Data()
            return trailing
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

        guard let writer = openPutTarget(target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        let reader = ChunkedBodyReader()

        let finishSuccess: (Data) -> Void = { [weak self] trailing in
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
            self.completeStreamingPut(writer: writer, target: target, truncated: false,
                                      finish: self.webDAVPutFinish(on: connection, request: request))
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
                    writer.finalize { [weak self] in
                        guard let self else { return }
                        NSLog("%@", "[ROMUploadServer] upload FAILED for \(target.lastPathComponent): invalid chunked body after \(writer.bytesWritten) bytes — deleting partial file")
                        try? FileManager.default.removeItem(at: target)
                        self.sendWebDAVResponse(on: connection, status: 400, statusText: "Bad Request",
                                                body: "Invalid chunked body", request: request, forceClose: true)
                    }
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
                    self.completeStreamingPut(writer: writer, target: target, truncated: true,
                                              finish: self.webDAVPutFinish(on: connection, request: request))
                    return
                }
                let events = reader.feed(data ?? Data())
                if handleEvents(events) { return }
                if isComplete {
                    self.completeStreamingPut(writer: writer, target: target, truncated: true,
                                              finish: self.webDAVPutFinish(on: connection, request: request))
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
        case ("GET", "/api/health"):
            serveHealth(on: connection, request: request)
        case ("PUT", _) where path.hasPrefix("/files/"):
            // Small bodies that arrived fully buffered; large ones streamed in handleRequestWithBody.
            streamBrowserFilePut(on: connection, request: request, initialBody: body, remaining: 0)
        case ("POST", "/move"):
            handleHTTPMove(on: connection, request: request, body: body)
        case ("POST", "/mkdir"):
            handleHTTPMkdir(on: connection, request: request, body: body)
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
        let portSuffix = Self.portSuffix(for: port)
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
                <tr class="dir-row uprow" data-dir="1" data-path="\(parent.htmlAttrEscaped)">
                  <td><a href="\(parentQuery)">&#x2B05;&#xFE0F; ..</a></td>
                  <td></td>
                  <td></td>
                </tr>
                """)
            }

            rows += files.map { self.fileRowHTML(entry: $0, currentSub: currentSub) }

            let emptyMessage = (rows.isEmpty)
                ? "<tr><td colspan=\"3\" class=\"empty\">No files yet. Drag and drop above to upload!</td></tr>"
                : ""

            let html = WebServerPageRenderer.uploadPage(
                appName: self.pageTitle, ipAddress: ip, portSuffix: portSuffix,
                fileRows: rows.isEmpty ? emptyMessage : rows.joined(separator: "\n"),
                currentPath: currentSub
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

    private func fileRowHTML(entry: FileEntry, currentSub: String) -> String {
        let childSub = currentSub.isEmpty ? entry.name : "\(currentSub)/\(entry.name)"
        let escapedName = entry.name.htmlEscaped
        let pathAttr = childSub.htmlAttrEscaped
        let nameAttr = entry.name.htmlAttrEscaped
        if entry.isDirectory {
            return """
            <tr class="dir-row" draggable="true" data-dir="1" data-path="\(pathAttr)" data-name="\(nameAttr)">
              <td><a href="/?path=\(childSub.urlPathEscaped)">&#x1F4C1; \(escapedName)</a></td>
              <td>&mdash;</td>
              <td class="actions">
                <button onclick="renameItem(this)" class="btn btn-sm">Rename</button>
                <button onclick="moveItem(this)" class="btn btn-sm">Move</button>
                <button onclick="deleteItem(this)" class="btn btn-sm btn-danger">Delete</button>
              </td>
            </tr>
            """
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        return """
        <tr class="file-row" draggable="true" data-dir="0" data-path="\(pathAttr)" data-name="\(nameAttr)">
          <td><a href="/files/\(childSub.urlPathEscaped)" download>\(escapedName)</a></td>
          <td>\(sizeStr)</td>
          <td class="actions">
            <a href="/files/\(childSub.urlPathEscaped)" download class="btn btn-sm">Download</a>
            <button onclick="renameItem(this)" class="btn btn-sm">Rename</button>
            <button onclick="moveItem(this)" class="btn btn-sm">Move</button>
            <button onclick="deleteItem(this)" class="btn btn-sm btn-danger">Delete</button>
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
                                remaining: Int, ioQueue: DispatchQueue? = nil,
                                forceClose: Bool = true) {
        let chunkSize = 256 * 1024
        guard remaining > 0 else {
            handle.closeFile()
            finishResponse(on: connection, request: nil, isWebDAV: true, forceClose: forceClose)
            return
        }

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
                                         remaining: remaining - data.count, ioQueue: ioQueue,
                                         forceClose: forceClose)
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
                // EOF or error with bytes still owed: the body is truncated, so the parts on
                // disk are partial. Mark the parser before finalizing so it deletes them and
                // `finishMultipartUpload` answers 500 instead of 200.
                if newRemaining > 0 { parser.abort() }
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
        if parser.hadWriteError {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": "Upload failed"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
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

    // MARK: - Browser PUT /files/<path>

    private func streamBrowserFilePut(on connection: NWConnection, request: HTTPRequest,
                                      initialBody: Data, remaining: Int) {
        let rel = String(request.path.dropFirst("/files/".count))
        let decoded = (rel.removingPercentEncoding ?? rel)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !decoded.isEmpty, let target = resolvedPath(decoded, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            sendJSON(on: connection, status: 405, json: ["ok": false, "error": "Target is a folder"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        guard let writer = openPutTarget(target) else {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": "Cannot create file"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        writer.write(initialBody)
        let finish: PutFinish = { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.sendJSON(on: connection, status: failure.httpStatus,
                              json: ["ok": false, "error": failure.logReason],
                              request: request, isWebDAV: false, forceClose: true)
            } else {
                self.sendResponse(on: connection, status: 204, statusText: "No Content", body: "",
                                  request: request, isWebDAV: false)
            }
        }
        streamPutChunks(on: connection, writer: writer, target: target, remaining: remaining, finish: finish)
    }

    // MARK: - Browser move / mkdir / health

    private func handleHTTPMove(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let src = obj["src"] as? String, let dst = obj["dst"] as? String,
              !src.isEmpty, !dst.isEmpty else {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "Missing src/dst"],
                     request: request, isWebDAV: false)
            return
        }
        let cleanSrc = src.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanDst = dst.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let source = resolvedPath(cleanSrc, within: romsDirectory),
              let target = resolvedPath(cleanDst, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false)
            return
        }
        if target.path == source.path || target.path.hasPrefix(source.path + "/") {
            sendJSON(on: connection, status: 409, json: ["ok": false, "error": "Cannot move into itself"],
                     request: request, isWebDAV: false)
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                sendJSON(on: connection, status: 409, json: ["ok": false, "error": "Destination already exists"],
                         request: request, isWebDAV: false)
                return
            }
            try fm.moveItem(at: source, to: target)
            sendJSON(on: connection, status: 200, json: ["ok": true], request: request, isWebDAV: false)
        } catch {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": error.localizedDescription],
                     request: request, isWebDAV: false)
        }
    }

    private func handleHTTPMkdir(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty else {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "Missing path"],
                     request: request, isWebDAV: false)
            return
        }
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let resolved = resolvedPath(clean, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false)
            return
        }
        do {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            sendJSON(on: connection, status: 200, json: ["ok": true], request: request, isWebDAV: false)
        } catch {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": error.localizedDescription],
                     request: request, isWebDAV: false)
        }
    }

    private func serveHealth(on connection: NWConnection, request: HTTPRequest) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        sendJSON(on: connection, status: 200, json: [
            "ok": true,
            "app": pageTitle,
            "version": version,
            "features": ["move": true, "mkdir": true, "stats": false]
        ], request: request, isWebDAV: false)
    }

    private typealias PutFinish = (_ failure: UploadFailure?) -> Void

    /// Finish a streaming PUT. On writer failure or truncation, delete the partial file, log,
    /// and hand the failure to `finish` WITHOUT posting the completion notification.
    private func completeStreamingPut(writer: SerialFileWriter, target: URL,
                                      truncated: Bool, finish: @escaping PutFinish) {
        writer.finalize { [weak self] in
            guard let self else { return }
            if let failure = UploadFailure.classify(writer: writer, truncated: truncated) {
                NSLog("%@", "[ROMUploadServer] upload FAILED for \(target.lastPathComponent): \(failure.logReason) after \(writer.bytesWritten) bytes — deleting partial file")
                try? FileManager.default.removeItem(at: target)
                finish(failure)
                return
            }
            self.postUploadCompleted(filePath: target.path)
            finish(nil)
        }
    }

    private func webDAVPutFinish(on connection: NWConnection, request: HTTPRequest) -> PutFinish {
        return { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.sendWebDAVResponse(on: connection, status: failure.httpStatus,
                                        statusText: failure.statusText, body: "Upload failed",
                                        request: request, forceClose: true)
            } else {
                self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
            }
        }
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
        guard let writer = openPutTarget(target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        writer.write(initialBody)
        streamPutChunks(on: connection, writer: writer, target: target, remaining: remaining,
                        finish: webDAVPutFinish(on: connection, request: request))
    }

    /// Creates the parent directory, replaces any existing file (createFile does not truncate,
    /// and preallocating over an existing file is slow on APFS), and opens the writer.
    private func openPutTarget(_ target: URL) -> SerialFileWriter? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("%@", "[ROMUploadServer] PUT: cannot create parent for \(target.lastPathComponent): \(error)")
            return nil
        }
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        guard let writer = SerialFileWriter(at: target) else {
            NSLog("%@", "[ROMUploadServer] PUT: cannot open \(target.path) for writing")
            return nil
        }
        return writer
    }

    private func streamPutChunks(on connection: NWConnection, writer: SerialFileWriter,
                                 target: URL, remaining: Int, finish: @escaping PutFinish) {
        if remaining <= 0 {
            completeStreamingPut(writer: writer, target: target, truncated: false, finish: finish)
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, Self.readChunkSize)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { writer.write(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                self.completeStreamingPut(writer: writer, target: target,
                                          truncated: newRemaining > 0, finish: finish)
            } else {
                self.streamPutChunks(on: connection, writer: writer, target: target,
                                     remaining: newRemaining, finish: finish)
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
            self.lock.lock()
            let keepAlive = self.connectionContexts[ObjectIdentifier(connection)]?.activeRequest?.wantsKeepAlive == true
            self.lock.unlock()

            if !includeBody {
                let respond = {
                    self.sendRawHeaders(on: connection, status: 200, statusText: "OK", headers: [
                        "Content-Type": self.mimeType(for: resolved),
                        "Content-Length": "\(fileSize)"
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

            var header = """
            HTTP/1.1 200 OK\r\n\
            Content-Type: \(self.mimeType(for: resolved))\r\n\
            Content-Length: \(fileSize)\r\n
            """
            header += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
            header += "\r\n"

            let beginStream = {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    if error != nil { handle.closeFile(); connection.cancel(); return }
                    self.streamFileData(handle: handle, on: connection, remaining: Int(fileSize),
                                        ioQueue: ioQueue, forceClose: !keepAlive)
                })
            }
            if let ioQueue { ioQueue.async(execute: beginStream) } else { beginStream() }
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
        guard !path.isEmpty, let target = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden",
                               request: request, forceClose: true)
            return
        }
        guard let writer = openPutTarget(target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        writer.write(body)
        completeStreamingPut(writer: writer, target: target, truncated: false,
                            finish: webDAVPutFinish(on: connection, request: request))
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
                self?.processIncomingBuffer(on: connection, buffer: pipelined)
            }
            return
        }

        let keepAlive = activeRequest?.wantsKeepAlive ?? false
        if !keepAlive || ctx.readClosed {
            connection.cancel()
            return
        }
        scheduleReceive(on: connection, accumulated: Data())
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
        switch WebServerPathSafety.resolve(rawPath, within: baseDir) {
        case .ok(let url):
            return url
        case .lexicalEscape:
            NSLog("%@", "[ROMUploadServer] rejected path (lexical escape): \(rawPath)")
            return nil
        case .symlinkEscape:
            NSLog("%@", "[ROMUploadServer] rejected path (symlink escape): \(rawPath)")
            return nil
        }
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

// MARK: - Bonjour Delegate

/// `NetService.publish()` fails silently without a delegate. This just logs.
private final class WebDAVBonjourDelegate: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[ROMUploadServer] _webdav._tcp published on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("%@", "[ROMUploadServer] _webdav._tcp publish failed: \(errorDict)")
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

struct HTTPRequest {
    let method: String
    let path: String
    let queryString: String?
    let httpVersion: String
    let headers: [String: String]

    /// Clamped at zero: a negative `Content-Length` from a hostile client used to reach
    /// `Data.dropFirst(_:)`, which traps on a negative count and kills the app remotely.
    var contentLength: Int { max(0, Int(headers["content-length"] ?? "") ?? 0) }

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

final class StreamingMultipartParser {
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
    /// True once any part failed to open or write. The caller must answer 5xx.
    private(set) var hadWriteError = false
    private var pendingCloses = 0
    private var finalizeCompletion: (() -> Void)?
    private var truncated = false

    private let headerEndMarker = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private enum ParserState { case seekingBoundary, readingHeaders, readingBody, done }

    init(boundary: String, outputDirectory: URL, onFileCompleted: ((String) -> Void)? = nil) {
        self.boundary = Data("--\(boundary)".utf8)
        self.endBoundary = Data("--\(boundary)--".utf8)
        self.outputDirectory = outputDirectory
        self.onFileCompleted = onFileCompleted
    }

    func feed(_ data: Data) { buffer.append(data); process() }

    /// The transport ended before the closing boundary. Anything still open is a partial file:
    /// `finalize` must delete it and report failure rather than announce a completed upload.
    /// Sets `hadWriteError` directly so a truncation with no part open is still a 500 and not a
    /// 400 "no files uploaded".
    func abort() {
        truncated = true
        hadWriteError = true
    }

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
                    if currentWriter == nil {
                        NSLog("%@", "[ROMUploadServer] multipart: cannot open \(filePath.path) for writing")
                        hadWriteError = true
                        currentFilename = nil
                        currentFilePath = nil
                    }
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
            if writer.failed || self.truncated {
                self.hadWriteError = true
                if let path { try? FileManager.default.removeItem(atPath: path) }
            } else if let path, filename != nil {
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

extension String {
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
    var htmlAttrEscaped: String { htmlEscaped }
}
