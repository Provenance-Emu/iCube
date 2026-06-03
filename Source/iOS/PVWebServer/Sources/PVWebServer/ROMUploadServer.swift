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

    // MARK: - Configuration

    let httpPort: UInt16
    let webDAVPort: UInt16
    let romsDirectory: URL

    /// Title shown in the upload page header (set by the facade).
    var pageTitle: String = "iCube"

    // MARK: - State

    private var httpListener: NWListener?
    private var webdavListener: NWListener?
    private var activeConnections = [ObjectIdentifier: NWConnection]()
    private let queue = DispatchQueue(label: "org.dolphin.iCube.uploadserver", qos: .userInitiated)
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

    // MARK: - Start / Stop

    /// Start both HTTP and WebDAV listeners. Waits until both reach `.ready`
    /// (or throws if either fails to bind). Also publishes a `_webdav._tcp`
    /// Bonjour record so other instances / NAS browsers can discover it.
    func start() async throws {
        guard !isHTTPRunning else { return }

        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        let httpListener = try NWListener(using: httpParams, on: NWEndpoint.Port(rawValue: httpPort)!)
        httpListener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn, isWebDAV: false)
        }

        let davParams = NWParameters.tcp
        davParams.allowLocalEndpointReuse = true
        let davListener = try NWListener(using: davParams, on: NWEndpoint.Port(rawValue: webDAVPort)!)
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
            var resumed = false
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
            httpListener.start(queue: self.queue)
        }
        self.httpListener = httpListener

        // Start WebDAV listener and wait for .ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
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
            davListener.start(queue: self.queue)
        }
        self.webdavListener = davListener

        NSLog("[ROMUploadServer] started — HTTP :\(httpPort), WebDAV :\(webDAVPort)")
    }

    func stop() {
        lock.lock()
        let conns = activeConnections
        activeConnections.removeAll()
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
        lock.lock()
        activeConnections[ObjectIdentifier(connection)] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.lock.lock()
                self?.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
                self?.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, isWebDAV: isWebDAV, accumulated: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection,
                                    isWebDAV: Bool,
                                    accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("[ROMUploadServer] receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            let headerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
            if let headerEnd {
                let headersData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                let bodyStart = buffer[headerEnd.upperBound...]

                guard let headersStr = String(data: headersData, encoding: .utf8),
                      let request = HTTPRequest.parse(headersStr) else {
                    self.sendResponse(on: connection, status: 400,
                                      statusText: "Bad Request", body: "Bad Request")
                    return
                }

                let contentLength = request.contentLength

                if contentLength > 0 && bodyStart.count < contentLength {
                    self.handleRequestWithBody(
                        on: connection, request: request, isWebDAV: isWebDAV,
                        initialBody: Data(bodyStart),
                        remaining: contentLength - bodyStart.count
                    )
                } else {
                    let body = contentLength > 0 ? Data(bodyStart.prefix(contentLength)) : Data()
                    self.routeRequest(on: connection, request: request,
                                      body: body, isWebDAV: isWebDAV)
                }
            } else if buffer.count > 64 * 1024 {
                self.sendResponse(on: connection, status: 413,
                                  statusText: "Request Entity Too Large",
                                  body: "Headers too large")
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(on: connection, isWebDAV: isWebDAV, accumulated: buffer)
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
            streamWebDAVPut(on: connection, request: request,
                            initialBody: initialBody, remaining: remaining)
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
                               maximumLength: min(bytesLeft, 65536)) { data, _, isComplete, error in
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
                                         contentType: ct, body: rawData)
                    } else if let jsonData = try? JSONSerialization.data(
                        withJSONObject: result, options: [.sortedKeys]) {
                        sendDataResponse(on: connection, status: 200, statusText: "OK",
                                         contentType: "application/json", body: jsonData)
                    } else {
                        sendResponse(on: connection, status: 500,
                                     statusText: "Internal Server Error",
                                     body: "Handler returned invalid JSON")
                    }
                } else {
                    sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
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
            serveHTML(on: connection, subpath: request.queryParameters["path"] ?? "")
        case ("GET", _) where path.hasPrefix("/files/"):
            serveFile(on: connection, path: String(path.dropFirst("/files/".count)))
        case ("DELETE", _) where path.hasPrefix("/files/"):
            deleteFile(on: connection, path: String(path.dropFirst("/files/".count)))
        case ("POST", "/upload"):
            handleBufferedUpload(on: connection, request: request, body: body)
        default:
            sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
        }
    }

    // MARK: - HTML Serving

    private func serveHTML(on connection: NWConnection, subpath: String = "") {
        let ip = getLocalIPAddress() ?? "unknown"
        let portSuffix = httpPort == 80 ? "" : ":\(httpPort)"
        let davPortStr = "\(webDAVPort)"

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

        let files = listFiles(in: listDir)
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
            </tr>
            """)
        }

        rows += files.map { entry -> String in
            let childSub = currentSub.isEmpty ? entry.name : "\(currentSub)/\(entry.name)"
            let escapedName = entry.name.htmlEscaped
            if entry.isDirectory {
                return """
                <tr>
                  <td><a href="/?path=\(childSub.urlPathEscaped)">&#x1F4C1; \(escapedName)</a></td>
                  <td>&mdash;</td>
                  <td></td>
                </tr>
                """
            } else {
                let sizeStr = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                return """
                <tr>
                  <td><a href="/files/\(childSub.urlPathEscaped)" download>\(escapedName)</a></td>
                  <td>\(sizeStr)</td>
                  <td>
                    <a href="/files/\(childSub.urlPathEscaped)" download class="btn btn-sm">Download</a>
                    <button onclick="deleteFile('\(childSub.jsEscaped)')" class="btn btn-sm btn-danger">Delete</button>
                  </td>
                </tr>
                """
            }
        }

        let emptyMessage = (rows.isEmpty)
            ? "<tr><td colspan=\"3\" class=\"empty\">No files yet. Drag and drop above to upload!</td></tr>"
            : ""

        let html = Self.uploadPageHTML(
            title: pageTitle,
            ipAddress: ip, httpPort: portSuffix, davPort: davPortStr,
            fileRows: rows.isEmpty ? emptyMessage : rows.joined(separator: "\n"),
            currentPath: currentSub
        )

        let data = Data(html.utf8)
        sendDataResponse(on: connection, status: 200, statusText: "OK",
                         contentType: "text/html; charset=utf-8", body: data)
    }

    // MARK: - File Serving

    private func serveFile(on connection: NWConnection, path: String) {
        let decoded = path.removingPercentEncoding ?? path
        guard let resolved = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied")
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            sendResponse(on: connection, status: 404, statusText: "Not Found", body: "File not found")
            return
        }

        if isDir.boolValue {
            let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let location = relative.isEmpty ? "/" : "/?path=\(relative.urlPathEscaped)"
            sendResponse(on: connection, status: 302, statusText: "Found",
                         body: "", extraHeaders: ["Location": location])
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: resolved) else {
            sendResponse(on: connection, status: 500, statusText: "Internal Server Error", body: "Cannot open file")
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

        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil { handle.closeFile(); connection.cancel(); return }
            self.streamFileData(handle: handle, on: connection, remaining: Int(fileSize))
        })
    }

    private func streamFileData(handle: FileHandle, on connection: NWConnection, remaining: Int) {
        let chunkSize = 256 * 1024
        guard remaining > 0 else { handle.closeFile(); connection.cancel(); return }

        let toRead = min(chunkSize, remaining)
        let data = handle.readData(ofLength: toRead)
        guard !data.isEmpty else { handle.closeFile(); connection.cancel(); return }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { handle.closeFile(); connection.cancel(); return }
            self?.streamFileData(handle: handle, on: connection, remaining: remaining - data.count)
        })
    }

    // MARK: - File Delete

    private func deleteFile(on connection: NWConnection, path: String) {
        let decoded = path.removingPercentEncoding ?? path
        guard let resolved = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied")
            return
        }
        do {
            try FileManager.default.removeItem(at: resolved)
            sendJSON(on: connection, status: 200, json: ["ok": true])
        } catch {
            sendJSON(on: connection, status: 404, json: ["ok": false, "error": error.localizedDescription])
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
        let parser = StreamingMultipartParser(boundary: boundary,
                                              outputDirectory: uploadDirectory(for: request))
        parser.feed(initialBody)

        if remaining <= 0 {
            parser.finalize()
            finishMultipartUpload(on: connection, parser: parser)
            return
        }
        streamMultipartChunks(on: connection, parser: parser, remaining: remaining)
    }

    private func streamMultipartChunks(on connection: NWConnection,
                                       parser: StreamingMultipartParser,
                                       remaining: Int) {
        if remaining <= 0 {
            parser.finalize()
            finishMultipartUpload(on: connection, parser: parser)
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, 262144)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { parser.feed(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                parser.finalize()
                self.finishMultipartUpload(on: connection, parser: parser)
            } else {
                self.streamMultipartChunks(on: connection, parser: parser, remaining: newRemaining)
            }
        }
    }

    private func finishMultipartUpload(on connection: NWConnection, parser: StreamingMultipartParser) {
        let files = parser.completedFiles
        if files.isEmpty {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "No files uploaded"])
            return
        }
        for filePath in files {
            postUploadCompleted(filePath: filePath)
        }
        sendJSON(on: connection, status: 200, json: ["ok": true, "uploaded": files.count])
    }

    private func handleBufferedUpload(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let boundary = request.multipartBoundary else {
            sendResponse(on: connection, status: 400, statusText: "Bad Request",
                         body: "Missing multipart boundary")
            return
        }
        let parser = StreamingMultipartParser(boundary: boundary,
                                              outputDirectory: uploadDirectory(for: request))
        parser.feed(body)
        parser.finalize()
        finishMultipartUpload(on: connection, parser: parser)
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
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied")
            return
        }

        let parent = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: target.path) else {
            sendResponse(on: connection, status: 500, statusText: "Internal Server Error", body: "Cannot create file")
            return
        }

        postUploadStarted(path: target.path)

        if !initialBody.isEmpty { handle.write(initialBody) }

        if remaining <= 0 {
            handle.closeFile()
            postUploadCompleted(filePath: target.path)
            sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
            return
        }
        streamPutChunks(on: connection, handle: handle, target: target, remaining: remaining)
    }

    private func streamPutChunks(on connection: NWConnection, handle: FileHandle,
                                 target: URL, remaining: Int) {
        if remaining <= 0 {
            handle.closeFile()
            postUploadCompleted(filePath: target.path)
            sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, 262144)) { [weak self] data, _, isComplete, error in
            guard let self else { handle.closeFile(); return }
            if let data, !data.isEmpty { handle.write(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                handle.closeFile()
                self.postUploadCompleted(filePath: target.path)
                self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
            } else {
                self.streamPutChunks(on: connection, handle: handle, target: target, remaining: newRemaining)
            }
        }
    }

    // MARK: - WebDAV Routes

    private func routeWebDAV(on connection: NWConnection, request: HTTPRequest, body: Data) {
        let path = request.path
        let decoded = (path == "/" ? "" : String(path.dropFirst()))
            .removingPercentEncoding ?? String(path.dropFirst())

        switch request.method {
        case "OPTIONS": handleWebDAVOptions(on: connection)
        case "PROPFIND": handlePROPFIND(on: connection, path: decoded, depth: request.headers["depth"] ?? "1")
        case "GET": serveWebDAVFile(on: connection, path: decoded)
        case "DELETE": handleWebDAVDelete(on: connection, path: decoded)
        case "MKCOL": handleMKCOL(on: connection, path: decoded)
        case "MOVE": handleMOVE(on: connection, path: decoded, destination: request.headers["destination"] ?? "")
        case "PUT": handleWebDAVPutBuffered(on: connection, path: decoded, body: body)
        default:
            sendWebDAVResponse(on: connection, status: 405, statusText: "Method Not Allowed",
                               body: "Method not supported")
        }
    }

    private func handleWebDAVOptions(on connection: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r\n\
        DAV: 1\r\n\
        Allow: OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL, MOVE\r\n\
        Content-Length: 0\r\n\
        Connection: close\r\n\
        \r\n
        """
        connection.send(content: Data(header.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func handlePROPFIND(on connection: NWConnection, path: String, depth: String) {
        let target: URL
        if path.isEmpty {
            target = romsDirectory
        } else {
            guard let resolved = resolvedPath(path, within: romsDirectory) else {
                sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
                return
            }
            target = resolved
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found")
            return
        }

        var responses: [String] = [propfindEntry(for: target)]
        if isDir.boolValue && depth != "0" {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            )) ?? []
            for url in contents where !url.lastPathComponent.hasPrefix(".") {
                responses.append(propfindEntry(for: url))
            }
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """

        let data = Data(xml.utf8)
        let header = """
        HTTP/1.1 207 Multi-Status\r\n\
        Content-Type: application/xml; charset=utf-8\r\n\
        Content-Length: \(data.count)\r\n\
        Connection: close\r\n\
        \r\n
        """
        var fullResponse = Data(header.utf8)
        fullResponse.append(data)
        connection.send(content: fullResponse,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func propfindEntry(for url: URL) -> String {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let isDir = attrs?.isDirectory ?? false
        let size = attrs?.fileSize ?? 0
        let mtime = (attrs?.contentModificationDate).map { date -> String in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            fmt.timeZone = TimeZone(abbreviation: "GMT")
            return fmt.string(from: date)
        } ?? ""

        let relativePath = url.path.hasPrefix(romsDirectory.path)
            ? String(url.path.dropFirst(romsDirectory.path.count))
            : "/" + url.lastPathComponent
        let href = relativePath.isEmpty ? "/" : relativePath
        let resourceType = isDir ? "<D:collection/>" : ""

        return """
            <D:response>
                <D:href>\(href.xmlEscaped)</D:href>
                <D:propstat>
                    <D:prop>
                        <D:resourcetype>\(resourceType)</D:resourcetype>
                        <D:getcontentlength>\(size)</D:getcontentlength>
                        <D:getlastmodified>\(mtime)</D:getlastmodified>
                    </D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
        """
    }

    private func serveWebDAVFile(on connection: NWConnection, path: String) {
        guard !path.isEmpty,
              let resolved = resolvedPath(path, within: romsDirectory),
              FileManager.default.fileExists(atPath: resolved.path) else {
            sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found")
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: resolved) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error")
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        let header = """
        HTTP/1.1 200 OK\r\n\
        Content-Type: application/octet-stream\r\n\
        Content-Length: \(fileSize)\r\n\
        Connection: close\r\n\
        \r\n
        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil { handle.closeFile(); connection.cancel(); return }
            self.streamFileData(handle: handle, on: connection, remaining: Int(fileSize))
        })
    }

    private func handleWebDAVDelete(on connection: NWConnection, path: String) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
            return
        }
        do {
            try FileManager.default.removeItem(at: resolved)
            sendWebDAVResponse(on: connection, status: 204, statusText: "No Content")
        } catch {
            sendWebDAVResponse(on: connection, status: 404, statusText: "Not Found")
        }
    }

    private func handleMKCOL(on connection: NWConnection, path: String) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
            return
        }
        do {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
        } catch {
            sendWebDAVResponse(on: connection, status: 405, statusText: "Method Not Allowed")
        }
    }

    private func handleMOVE(on connection: NWConnection, path: String, destination: String) {
        guard !path.isEmpty, let source = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
            return
        }

        let destPath: String
        if let url = URL(string: destination) {
            destPath = url.path.removingPercentEncoding ?? url.path
        } else {
            destPath = destination
        }
        let cleanDest = destPath.hasPrefix("/") ? String(destPath.dropFirst()) : destPath
        guard !cleanDest.isEmpty, let target = resolvedPath(cleanDest, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
            return
        }

        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: source, to: target)
            sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
        } catch {
            sendWebDAVResponse(on: connection, status: 409, statusText: "Conflict")
        }
    }

    private func handleWebDAVPutBuffered(on connection: NWConnection, path: String, body: Data) {
        guard !path.isEmpty, let resolved = resolvedPath(path, within: romsDirectory) else {
            sendWebDAVResponse(on: connection, status: 403, statusText: "Forbidden")
            return
        }
        let parent = resolved.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        postUploadStarted(path: resolved.path)
        do {
            try body.write(to: resolved)
            postUploadCompleted(filePath: resolved.path)
            sendWebDAVResponse(on: connection, status: 201, statusText: "Created")
        } catch {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error")
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

    private func sendResponse(on connection: NWConnection, status: Int, statusText: String,
                              body: String, contentType: String = "text/plain; charset=utf-8",
                              extraHeaders: [String: String] = [:]) {
        sendDataResponse(on: connection, status: status, statusText: statusText,
                         contentType: contentType, body: Data(body.utf8), extraHeaders: extraHeaders)
    }

    private func sendDataResponse(on connection: NWConnection, status: Int, statusText: String,
                                  contentType: String, body: Data,
                                  extraHeaders: [String: String] = [:]) {
        var header = """
        HTTP/1.1 \(status) \(statusText)\r\n\
        Content-Type: \(contentType)\r\n\
        Content-Length: \(body.count)\r\n\
        Connection: close\r\n
        """
        for (key, value) in extraHeaders { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendWebDAVResponse(on connection: NWConnection, status: Int,
                                    statusText: String, body: String? = nil) {
        let bodyData = body.map { Data($0.utf8) } ?? Data()
        let ct = body != nil ? "text/plain; charset=utf-8" : "text/plain"
        let header = """
        HTTP/1.1 \(status) \(statusText)\r\n\
        Content-Type: \(ct)\r\n\
        Content-Length: \(bodyData.count)\r\n\
        Connection: close\r\n\
        \r\n
        """
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendJSON(on connection: NWConnection, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        sendDataResponse(on: connection, status: status,
                         statusText: status == 200 ? "OK" : "Error",
                         contentType: "application/json", body: data)
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
    }

    private func listFiles(in directory: URL) -> [FileEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return [] }

        return contents
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> FileEntry in
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                return FileEntry(name: url.lastPathComponent,
                                 size: Int64(attrs?.fileSize ?? 0),
                                 isDirectory: attrs?.isDirectory ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
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
    private var buffer = Data()
    private var state: ParserState = .seekingBoundary
    private var currentFilename: String?
    private var currentHandle: FileHandle?
    private var currentFilePath: URL?
    private(set) var completedFiles: [String] = []

    private let headerEndMarker = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private enum ParserState { case seekingBoundary, readingHeaders, readingBody, done }

    init(boundary: String, outputDirectory: URL) {
        self.boundary = Data("--\(boundary)".utf8)
        self.endBoundary = Data("--\(boundary)--".utf8)
        self.outputDirectory = outputDirectory
    }

    func feed(_ data: Data) { buffer.append(data); process() }

    func finalize() {
        if state == .readingBody { flushBodyBuffer(isFinal: true) }
        closeCurrentFile()
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
                    FileManager.default.createFile(atPath: filePath.path, contents: nil)
                    currentHandle = FileHandle(forWritingAtPath: filePath.path)
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
            currentHandle?.write(bodyChunk)
            closeCurrentFile()

            buffer = Data(buffer[range.upperBound...])
            if buffer.starts(with: Data("--".utf8)) {
                state = .done
            } else {
                if buffer.starts(with: Data([0x0D, 0x0A])) { buffer = Data(buffer.dropFirst(2)) }
                state = .readingHeaders
            }
        } else if isFinal {
            if !buffer.isEmpty { currentHandle?.write(buffer); buffer = Data() }
            closeCurrentFile()
        } else {
            let safeSize = boundary.count + 4
            if buffer.count > safeSize {
                let writeCount = buffer.count - safeSize
                let chunk = buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: writeCount)]
                currentHandle?.write(chunk)
                buffer = Data(buffer[buffer.index(buffer.startIndex, offsetBy: writeCount)...])
            }
        }
    }

    private func closeCurrentFile() {
        currentHandle?.closeFile()
        currentHandle = nil
        if let path = currentFilePath?.path, currentFilename != nil {
            completedFiles.append(path)
        }
        currentFilename = nil
        currentFilePath = nil
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
                               currentPath: String = "") -> String {
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
            table { width: 100%; border-collapse: collapse; margin-top: 10px; }
            thead th { text-align: left; padding: 8px 10px; font-size: 11px; font-weight: 600;
              color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px;
              border-bottom: 1px solid var(--border); }
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
            </div>
          </div>

          <div class="card">
            <h2>Files &mdash; \(locationLabel)</h2>
            <table>
              <thead><tr><th>Name</th><th>Size</th><th></th></tr></thead>
              <tbody id="file-list">
                \(fileRows)
              </tbody>
            </table>
          </div>

          <script>
            const zone = document.getElementById('drop-zone');
            zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('hover'); });
            zone.addEventListener('dragleave', () => zone.classList.remove('hover'));
            zone.addEventListener('drop', e => {
              e.preventDefault(); zone.classList.remove('hover');
              uploadFiles(e.dataTransfer.files);
            });
            document.getElementById('upload-btn').addEventListener('click', () => {
              document.getElementById('file-input').click();
            });
            document.getElementById('file-input').addEventListener('change', e => {
              uploadFiles(e.target.files);
            });

            const uploadQueue = [];
            let uploading = false;
            let totalQueued = 0;
            let completed = 0;
            let reloadTimer = null;

            function uploadFiles(files) {
              if (!files || !files.length) return;
              if (reloadTimer) { clearTimeout(reloadTimer); reloadTimer = null; }
              for (let k = 0; k < files.length; k++) uploadQueue.push(files[k]);
              totalQueued += files.length;
              if (!uploading) processQueue();
            }

            async function processQueue() {
              uploading = true;
              const container = document.getElementById('progress-container');
              const fill = document.getElementById('progress-fill');
              const status = document.getElementById('status');
              container.style.display = 'block';

              while (uploadQueue.length) {
                const f = uploadQueue.shift();
                status.textContent = 'Uploading ' + f.name + ' (' + (completed + 1) + '/' + totalQueued + ')...';
                const fd = new FormData();
                fd.append('files[]', f, f.name);
                await new Promise((resolve) => {
                  const xhr = new XMLHttpRequest();
                  xhr.upload.onprogress = (e) => {
                    if (e.lengthComputable) {
                      fill.style.width = ((completed + e.loaded / e.total) / totalQueued * 100) + '%';
                    }
                  };
                  xhr.onload = resolve;
                  xhr.onerror = resolve;
                  xhr.open('POST', '\(uploadTarget)');
                  xhr.send(fd);
                });
                completed++;
                fill.style.width = (completed / totalQueued * 100) + '%';
              }

              uploading = false;
              fill.style.width = '100%';
              status.textContent = 'Done! ' + completed + ' file(s) uploaded.';
              reloadTimer = setTimeout(() => {
                container.style.display = 'none';
                fill.style.width = '0%';
                status.textContent = '';
                location.reload();
              }, 2000);
            }

            function deleteFile(name) {
              if (!confirm('Delete "' + name + '"?')) return;
              fetch('/files/' + encodeURIComponent(name), { method: 'DELETE' })
                .then(r => { if (r.ok) location.reload(); else alert('Delete failed'); })
                .catch(() => alert('Delete failed'));
            }
          </script>
        </body>
        </html>
        """
    }
}
