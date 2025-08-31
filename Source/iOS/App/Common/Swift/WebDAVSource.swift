import Foundation
#if canImport(os)
import os
#endif

/// Minimal WebDAV implementation that pings root and emits base URL as an item container.
final class WebDAVSource: RemoteLibrarySource, Identifiable {
    let id: String
    var name: String
    let baseURL: URL
    private var username: String?
    private var password: String?
    private var recursive: Bool
    private var interval: TimeInterval
    private let startPath: String?
    var enablePreCaching: Bool

    var isRecursive: Bool { recursive }
    var refreshInterval: TimeInterval { interval }
    var userName: String? { username }
    /// Expose configured start path for UI/persistence
    var startPathComponent: String? { startPath }
    /// The effective root URL this source operates on
    var rootURL: URL {
        guard let sp = startPath, !sp.isEmpty, let resolved = resolve(href: sp, relativeTo: baseURL) else { return baseURL }
        return resolved
    }

    private var onlineCont: AsyncStream<Bool>.Continuation?
    private var itemsCont: AsyncStream<[RemoteLibraryItem]>.Continuation?

    private(set) var isOnline: Bool = false { didSet { onlineCont?.yield(isOnline) } }

    // Pre-caching support
    private var activeCacheTasks: [String: Task<Void, Error>] = [:]
    private let cacheDirectory: URL
    private let cacheMetadataFile: URL

    var onlineStream: AsyncStream<Bool>
    var itemsStream: AsyncStream<[RemoteLibraryItem]>

    #if canImport(os)
    private static let logger = Logger(subsystem: "org.dolphin-emu.dolphinios", category: "WebDAV")
    #endif

    // Cancellable loop task; do not finish streams on stop()
    private var loopTask: Task<Void, Never>?

    /// Generate consistent ID based on host (matches C++ logic)
    static func generateConsistentId(for url: URL) -> String {
        guard let host = url.host else {
            return "unknown_host"
        }

        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let hostWithPort = "\(host):\(port)"

        // Replace dots and colons with underscores (same as C++ code)
        return hostWithPort.replacingOccurrences(of: ".", with: "_")
                          .replacingOccurrences(of: ":", with: "_")
    }

    /// RFC1123 HTTP-date formatter used by WebDAV getlastmodified
    private static let httpDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return df
    }()
    private static func parseHTTPDate(_ string: String) -> Date? {
        return httpDateFormatter.date(from: string)
    }

    init(id: String = UUID().uuidString, name: String, url: URL, username: String?, password: String?, recursive: Bool, interval: TimeInterval = 900, startPath: String? = nil, enablePreCaching: Bool = false) {
        // Generate consistent ID based on host (same as C++ code)
        let consistentId = Self.generateConsistentId(for: url)
        self.id = consistentId
        self.name = name
        self.baseURL = url
        self.username = username
        self.password = password
        self.recursive = recursive
        self.interval = interval
        self.startPath = startPath
        self.enablePreCaching = enablePreCaching

        // Create cache directory using consistent ID
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesPath.appendingPathComponent("RemoteCache").appendingPathComponent(consistentId)
        self.cacheMetadataFile = cacheDirectory.appendingPathComponent("cache_metadata.json")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var oc: AsyncStream<Bool>.Continuation!
        self.onlineStream = AsyncStream<Bool> { c in oc = c }
        self.onlineCont = oc
        var ic: AsyncStream<[RemoteLibraryItem]>.Continuation!
        self.itemsStream = AsyncStream<[RemoteLibraryItem]> { c in ic = c }
        self.itemsCont = ic
        #if canImport(os)
        Self.logger.info("Initialized WebDAVSource name=\(self.name, privacy: .public) url=\(self.baseURL.absoluteString, privacy: .public) root=\(self.rootURL.absoluteString, privacy: .public) preCache=\(self.enablePreCaching)")
        #endif
    }

    /// Update configuration of existing source (used by factory)
    func updateConfiguration(
        name: String,
        username: String?,
        password: String?,
        recursive: Bool,
        interval: TimeInterval,
        enablePreCaching: Bool
    ) {
        self.name = name
        self.username = username
        self.password = password
        self.recursive = recursive
        self.interval = interval
        self.enablePreCaching = enablePreCaching

        #if canImport(os)
        Self.logger.info("Updated WebDAVSource configuration: \(self.name)")
        #endif
    }

    func start() {
        #if canImport(os)
        Self.logger.info("Starting WebDAV source: \(self.name)")
        #endif

        // Clean up any stale cache entries from old implementation
        cleanupStaleCache()

        // Create fresh streams and continuations for restart
        var oc: AsyncStream<Bool>.Continuation!
        self.onlineStream = AsyncStream<Bool> { c in oc = c }
        self.onlineCont = oc
        var ic: AsyncStream<[RemoteLibraryItem]>.Continuation!
        self.itemsStream = AsyncStream<[RemoteLibraryItem]> { c in ic = c }
        self.itemsCont = ic

        #if canImport(os)
        Self.logger.info("Created fresh streams for WebDAV source: \(self.name)")
        #endif

        // Cancel any previous loop and start a fresh one
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.loop()
        }
    }

    func stop() {
        #if canImport(os)
        Self.logger.info("Stopping source loop for \(self.rootURL.absoluteString, privacy: .public)")
        #endif

        // Cancel the loop task
        loopTask?.cancel()
        loopTask = nil

        // Finish the current streams to properly end them
        onlineCont?.finish()
        itemsCont?.finish()
        onlineCont = nil
        itemsCont = nil

        #if canImport(os)
        Self.logger.info("WebDAV source stopped, streams finished and will be recreated on restart")
        #endif
    }

    private func loop() async {
        #if canImport(os)
        Self.logger.info("Starting WebDAV loop for \(self.rootURL.absoluteString, privacy: .public)")
        #endif
        while true {
            if Task.isCancelled { break }
            // Defer work while emulation is active to avoid contention
            await waitWhileEmulationActive()
            if Task.isCancelled { break }
            #if canImport(os)
            Self.logger.debug("Loop iteration: pinging \(self.rootURL.absoluteString, privacy: .public)")
            #endif
            await ping()
            if Task.isCancelled { break }
            if isOnline {
                #if canImport(os)
                Self.logger.debug("Source is online, starting enumeration")
                #endif
                await enumerateAndEmit()
            } else {
                #if canImport(os)
                Self.logger.debug("Source is offline, skipping enumeration")
                #endif
            }
            #if canImport(os)
            Self.logger.debug("Sleeping for \(self.interval, privacy: .public) seconds")
            #endif
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func request(_ method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> (Int, Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        headers.forEach { req.addValue($0.value, forHTTPHeaderField: $0.key) }
        if let body { req.httpBody = body }
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        #if canImport(os)
        var redacted = headers
        redacted.removeValue(forKey: "Authorization")
        Self.logger.debug("HTTP \(method, privacy: .public) \(url.absoluteString, privacy: .public) headers=\(String(describing: redacted), privacy: .public) bodyLength=\(body?.count ?? 0, privacy: .public)")
        #endif
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            #if canImport(os)
            Self.logger.info("HTTP resp \(code, privacy: .public) for \(method, privacy: .public) \(url.absoluteString, privacy: .public) length=\(data.count, privacy: .public)")
            #endif
            return (code, data, resp as! HTTPURLResponse)
        } catch {
            #if canImport(os)
            Self.logger.error("HTTP error for \(method, privacy: .public) \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            throw error
        }
    }

    @MainActor private func ping() async {
        do {
            let (code, _, _) = try await request("HEAD", url: rootURL)
            isOnline = (200...399).contains(code)
            #if canImport(os)
            Self.logger.info("Ping \(self.rootURL.absoluteString, privacy: .public) status=\(self.isOnline, privacy: .public) code=\(code, privacy: .public)")
            #endif
        } catch {
            isOnline = false
            #if canImport(os)
            Self.logger.error("Ping failed for \(self.rootURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    @MainActor private func enumerateAndEmit() async {
        #if canImport(os)
        Self.logger.info("Enumerating WebDAV at \(self.rootURL.absoluteString, privacy: .public) recursive=\(self.recursive, privacy: .public)")
        #endif
        do {
            var cumulative: [RemoteLibraryItem] = []
            var queue: [URL] = [rootURL]
            var seen: Set<URL> = []
            var processedDirs = 0
            while let current = queue.first {
                if Task.isCancelled { break }
                queue.removeFirst()
                // Normalize URL by removing trailing slash for comparison
                let normalizedCurrentString = current.absoluteString.hasSuffix("/") ? String(current.absoluteString.dropLast()) : current.absoluteString
                let normalizedCurrent = URL(string: normalizedCurrentString)!
                if seen.contains(normalizedCurrent) { continue }
                seen.insert(normalizedCurrent)
                #if canImport(os)
                Self.logger.debug("Processing directory: \(current.absoluteString, privacy: .public)")
                #endif
                let nodes = try await propfind(url: current, depth: recursive ? "1" : "0")
                #if canImport(os)
                Self.logger.debug("Found \(nodes.count, privacy: .public) nodes in \(current.absoluteString, privacy: .public)")
                #endif
                var addedInThisDir = 0
                for n in nodes {
                    guard let resolved = resolve(href: n.href, relativeTo: current) else { continue }
                    if n.isCollection {
                        if recursive {
                            let normalizedResolvedString = resolved.absoluteString.hasSuffix("/") ? String(resolved.absoluteString.dropLast()) : resolved.absoluteString
                            let normalizedResolved = URL(string: normalizedResolvedString)!
                            queue.append(normalizedResolved)
                        }
                    } else if hasSupportedExtension(resolved) {
                        let item = RemoteLibraryItem(url: resolved, displayName: n.displayName ?? resolved.lastPathComponent, sizeBytes: n.contentLength, etag: n.etag, lastModified: n.lastModified)
                        cumulative.append(item)
                        addedInThisDir += 1
                    }
                }
                processedDirs += 1
                // Yield progressively after each directory or after a reasonable batch
                if addedInThisDir > 0 || processedDirs % 5 == 0 {
                    itemsCont?.yield(cumulative)
                }
            }
            // Final yield to ensure consumers have the complete list
            itemsCont?.yield(cumulative)
        } catch {
            #if canImport(os)
            Self.logger.error("Enumeration error at \(self.rootURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private struct Node {
        let href: String
        let displayName: String?
        let isCollection: Bool
        let contentLength: Int64?
        let etag: String?
        let lastModified: Date?
    }

    private final class Parser: NSObject, XMLParserDelegate {
        private(set) var nodes: [Node] = []
        private var currentHref: String?
        private var currentDisplay: String?
        private var currentTypeIsCollection: Bool = false
        private var currentLength: Int64?
        private var currentEtag: String?
        private var currentLastMod: Date?
        private var currentLastModString: String?
        private var currentElement: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let currentElement else { return }
            switch currentElement.lowercased() {
            case "d:href", "href":
                currentHref = (currentHref ?? "") + string
            case "d:displayname", "displayname":
                currentDisplay = (currentDisplay ?? "") + string
            case "d:getcontentlength", "getcontentlength":
                currentLength = Int64((String((currentLength.map(String.init) ?? "") + string)).trimmingCharacters(in: .whitespacesAndNewlines))
            case "d:getetag", "getetag":
                currentEtag = (currentEtag ?? "") + string
            case "d:getlastmodified", "getlastmodified":
                currentLastModString = (currentLastModString ?? "") + string
            default:
                break
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let lower = elementName.lowercased()
            if lower.hasSuffix("getlastmodified") {
                if let s = currentLastModString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    currentLastMod = WebDAVSource.parseHTTPDate(s) ?? currentLastMod
                }
                currentLastModString = nil
            }
            if lower.hasSuffix("response") {
                if let href = currentHref {
                    nodes.append(Node(href: href, displayName: currentDisplay, isCollection: currentTypeIsCollection, contentLength: currentLength, etag: currentEtag, lastModified: currentLastMod))
                }
                currentHref = nil
                currentDisplay = nil
                currentTypeIsCollection = false
                currentLength = nil
                currentEtag = nil
                currentLastMod = nil
                currentLastModString = nil
            } else if lower.hasSuffix("collection") {
                currentTypeIsCollection = true
            }
            currentElement = nil
        }
    }

    private func parsePropfindXML(data: Data) -> [Node] {
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        let ok = xml.parse()
        #if canImport(os)
        if ok {
            Self.logger.debug("Parsed PROPFIND XML nodes=\(p.nodes.count, privacy: .public)")
        } else {
            Self.logger.error("Failed to parse PROPFIND XML")
        }
        #endif
        return p.nodes
    }

    private func resolve(href: String, relativeTo base: URL) -> URL? {
        if let absolute = URL(string: href), absolute.scheme != nil { return absolute }
        if href.hasPrefix("/") {
            if var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                // href from WebDAV is already percent-encoded, so decode it first
                let decodedPath = href.removingPercentEncoding ?? href
                comps.path = decodedPath
                return comps.url
            }
            return nil
        }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    private func hasSupportedExtension(_ url: URL) -> Bool {
        let exts = ["dol","iso","zip","nkit","cso","img","rvz","wia","gcz","wad","elf","gcm","tgc","wbfs","ciso"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private func enumerateWebDAV() async throws -> [RemoteLibraryItem] {
        #if canImport(os)
        Self.logger.info("Starting WebDAV enumeration at \(self.rootURL.absoluteString, privacy: .public)")
        #endif
        var result: [RemoteLibraryItem] = []
        var queue: [URL] = [rootURL]
        var seen: Set<URL> = []
        while let current = queue.first {
            queue.removeFirst()
            // Normalize URL by removing trailing slash for comparison
            let normalizedCurrentString = current.absoluteString.hasSuffix("/") ? String(current.absoluteString.dropLast()) : current.absoluteString
            let normalizedCurrent = URL(string: normalizedCurrentString)!
            if seen.contains(normalizedCurrent) { continue }
            seen.insert(normalizedCurrent)
            #if canImport(os)
            Self.logger.debug("Processing directory: \(current.absoluteString, privacy: .public)")
            #endif
            let nodes = try await propfind(url: current, depth: recursive ? "1" : "0")
            #if canImport(os)
            Self.logger.debug("Found \(nodes.count, privacy: .public) nodes in \(current.absoluteString, privacy: .public)")
            #endif
            for n in nodes {
                guard let resolved = resolve(href: n.href, relativeTo: current) else {
                    #if canImport(os)
                    Self.logger.debug("Failed to resolve href: \(n.href, privacy: .public)")
                    #endif
                    continue
                }
                #if canImport(os)
                Self.logger.debug("Node: href=\(n.href, privacy: .public) resolved=\(resolved.absoluteString, privacy: .public) isCollection=\(n.isCollection, privacy: .public)")
                #endif
                if n.isCollection {
                    if recursive {
                        // Normalize resolved URL by removing trailing slash before adding to queue
                        let normalizedResolvedString = resolved.absoluteString.hasSuffix("/") ? String(resolved.absoluteString.dropLast()) : resolved.absoluteString
                        let normalizedResolved = URL(string: normalizedResolvedString)!
                        queue.append(normalizedResolved)
                        #if canImport(os)
                        Self.logger.debug("Added directory to queue: \(normalizedResolved.absoluteString, privacy: .public)")
                        #endif
                    }
                } else if hasSupportedExtension(resolved) {
                    let item = RemoteLibraryItem(url: resolved, displayName: n.displayName ?? resolved.lastPathComponent, sizeBytes: n.contentLength, etag: n.etag, lastModified: n.lastModified)
                    result.append(item)
                    #if canImport(os)
                    Self.logger.info("Added ROM file: \(resolved.absoluteString, privacy: .public) size=\(n.contentLength ?? -1, privacy: .public)")
                    #endif
                } else {
                    #if canImport(os)
                    Self.logger.debug("Skipped unsupported file: \(resolved.absoluteString, privacy: .public)")
                    #endif
                }
            }
        }
        #if canImport(os)
        Self.logger.info("WebDAV enumeration complete: found \(result.count, privacy: .public) ROM files")
        #endif
        return result
    }

    private func propfind(url: URL, depth: String) async throws -> [Node] {
        let body = """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <d:propfind xmlns:d=\"DAV:\">
          <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:resourcetype/>
            <d:getetag/>
          </d:prop>
        </d:propfind>
        """.data(using: .utf8)!
        #if canImport(os)
        Self.logger.debug("PROPFIND \(url.absoluteString, privacy: .public) depth=\(depth, privacy: .public)")
        #endif
        let (code, data, _) = try await request("PROPFIND", url: url, headers: ["Depth": depth, "Content-Type": "text/xml"], body: body)
        guard (200...399).contains(code) else {
            #if canImport(os)
            Self.logger.error("PROPFIND failed code=\(code, privacy: .public) url=\(url.absoluteString, privacy: .public)")
            #endif
            return []
        }
        return parsePropfindXML(data: data)
    }

    // MARK: - Pre-caching Support

    /// Cache metadata for tracking cached files
    struct CacheMetadata: Codable {
        var cachedFiles: [String: CachedFileInfo] = [:]

        struct CachedFileInfo: Codable {
            let originalURL: String
            let localPath: String
            var fileSize: Int64
            let cachedDate: Date
            let etag: String?
            let lastModified: Date?
        }
    }

    /// Expose pre-caching enabled status
    var isPreCachingEnabled: Bool { enablePreCaching }

    /// Expose enablePreCaching for UI (make it accessible)
    var preCachingEnabled: Bool { enablePreCaching }

    /// Get cache directory for this source
    func getCacheDirectory() -> URL {
        return cacheDirectory
    }

    /// Load cache metadata from disk
    private func loadCacheMetadata() -> CacheMetadata {
        guard FileManager.default.fileExists(atPath: cacheMetadataFile.path) else {
            return CacheMetadata()
        }

        do {
            let data = try Data(contentsOf: cacheMetadataFile)
            return try JSONDecoder().decode(CacheMetadata.self, from: data)
        } catch {
            #if canImport(os)
            Self.logger.error("Failed to load cache metadata: \(error.localizedDescription)")
            #endif
            return CacheMetadata()
        }
    }

    /// Save cache metadata to disk
    private func saveCacheMetadata(_ metadata: CacheMetadata) {
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: cacheMetadataFile)
        } catch {
            #if canImport(os)
            Self.logger.error("Failed to save cache metadata: \(error.localizedDescription)")
            #endif
        }
    }

    /// Check if an item is cached locally
    func isCached(_ item: RemoteLibraryItem) -> Bool {
        let (cached, _) = isCachedWithPath(item)
        return cached
    }

    /// Check if an item is cached locally (internal implementation)
    private func isCachedWithPath(_ item: RemoteLibraryItem) -> (Bool, String?) {
        let metadata = loadCacheMetadata()
        if let cachedInfo = metadata.cachedFiles[item.url.absoluteString] {
            let localURL = cacheDirectory.appendingPathComponent(cachedInfo.localPath)
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if fileSize != cachedInfo.fileSize {
                    #if canImport(os)
                    Self.logger.info("Cached file size mismatch for \(item.displayName): expected \(cachedInfo.fileSize), got \(fileSize)")
                    #endif
                    // If a file exists but recorded size was wrong (e.g., 0), trust the file and update metadata
                    var updated = metadata
                    var newInfo = cachedInfo
                    newInfo.fileSize = fileSize
                    updated.cachedFiles[item.url.absoluteString] = newInfo
                    saveCacheMetadata(updated)
                    return (true, localURL.path)
                }
            } catch {
                return (false, nil)
            }

            return (true, localURL.path)
        }

        return (false, nil)
    }

    /// Pre-cache a specific item to local storage
    func preCacheItem(_ item: RemoteLibraryItem, progressCallback: @escaping (Double) -> Void) async throws -> String {
        guard enablePreCaching else {
            throw NSError(domain: "WebDAVSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pre-caching is disabled for this source"])
        }

        // Check if already cached
        let (cached, localPath) = isCachedWithPath(item)
        if cached, let path = localPath {
            #if canImport(os)
            Self.logger.info("File already cached: \(item.displayName)")
            #endif
            progressCallback(1.0)
            return path
        }

        let key = item.url.absoluteString

        // Cancel any existing cache task for this item
        activeCacheTasks[key]?.cancel()

        let task = Task<Void, Error> {
            try await downloadFile(item: item, progressCallback: progressCallback)
        }

        activeCacheTasks[key] = task

        do {
            try await task.value
            activeCacheTasks.removeValue(forKey: key)

            // Return the cached file path
            let (_, localPath) = isCachedWithPath(item)
            return localPath ?? ""
        } catch {
            activeCacheTasks.removeValue(forKey: key)
            throw error
        }
    }

    /// Download a file to cache
    private func downloadFile(item: RemoteLibraryItem, progressCallback: @escaping (Double) -> Void) async throws {
        let fileName = item.url.lastPathComponent
        let localURL = cacheDirectory.appendingPathComponent(fileName)

        #if canImport(os)
        Self.logger.info("Starting download of \(item.displayName) to cache")
        #endif

        // Avoid heavy network/disk work while emulation is running
        await waitWhileEmulationActive()
        if Task.isCancelled { return }

        // Create URL request
        var request = URLRequest(url: item.url)
        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            let credentialsData = credentials.data(using: .utf8)!
            let base64Credentials = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        }

        // Create a continuation to bridge the delegate callbacks with async/await
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(
                progressCallback: progressCallback,
                completion: { result in
                    switch result {
                    case .success(let tempURL):
                        do {
                            // Move to final location (replace if exists)
                            if FileManager.default.fileExists(atPath: localURL.path) {
                                try FileManager.default.removeItem(at: localURL)
                            }
                            try FileManager.default.moveItem(at: tempURL, to: localURL)

                            // Determine actual file size on disk
                            let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
                            let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

                            // Update cache metadata with actual size
                            var metadata = self.loadCacheMetadata()
                            let cachedInfo = CacheMetadata.CachedFileInfo(
                                originalURL: item.url.absoluteString,
                                localPath: fileName,
                                fileSize: actualSize,
                                cachedDate: Date(),
                                etag: item.etag,
                                lastModified: item.lastModified
                            )
                            metadata.cachedFiles[item.url.absoluteString] = cachedInfo
                            self.saveCacheMetadata(metadata)

                            // Final progress callback
                            progressCallback(1.0)

                            #if canImport(os)
                            Self.logger.info("Successfully cached \(item.displayName)")
                            #endif

                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: request)
            delegate.task = task
            task.resume()
        }
    }

    /// Cancel pre-caching for an item
    func cancelPreCache(_ item: RemoteLibraryItem) async {
        let key = item.url.absoluteString
        activeCacheTasks[key]?.cancel()
        activeCacheTasks.removeValue(forKey: key)

        #if canImport(os)
        Self.logger.info("Cancelled pre-caching for \(item.displayName)")
        #endif
    }

    /// Remove cached item from local storage
    func removeCachedItem(_ item: RemoteLibraryItem) async throws {
        let key = item.url.absoluteString
        var metadata = loadCacheMetadata()

        guard let cachedInfo = metadata.cachedFiles[key] else {
            return // Not cached
        }

        let localURL = cacheDirectory.appendingPathComponent(cachedInfo.localPath)

        // Remove file
        try FileManager.default.removeItem(at: localURL)

        // Update metadata
        metadata.cachedFiles.removeValue(forKey: key)
        saveCacheMetadata(metadata)

        #if canImport(os)
        Self.logger.info("Removed cached file: \(item.displayName)")
        #endif
    }

    /// Get total cache size in bytes
    func getCacheSize() -> Int64 {
        let metadata = loadCacheMetadata()
        return metadata.cachedFiles.values.reduce(0) { $0 + $1.fileSize }
    }

    /// Clear all cached files for this source
    func clearCache() async throws {
        let metadata = loadCacheMetadata()

        for cachedInfo in metadata.cachedFiles.values {
            let localURL = cacheDirectory.appendingPathComponent(cachedInfo.localPath)
            try? FileManager.default.removeItem(at: localURL)
        }

        // Clear metadata
        saveCacheMetadata(CacheMetadata())

        #if canImport(os)
        Self.logger.info("Cleared all cached files")
        #endif
    }

    /// Clean up stale cache entries with size 0 (from old implementation)
    func cleanupStaleCache() {
        var metadata = loadCacheMetadata()
        var hasChanges = false

        for (key, cachedInfo) in metadata.cachedFiles {
            if cachedInfo.fileSize == 0 {
                #if canImport(os)
                Self.logger.info("Removing stale cache entry with size 0: \(key)")
                #endif

                // Remove the local file
                let localURL = cacheDirectory.appendingPathComponent(cachedInfo.localPath)
                try? FileManager.default.removeItem(at: localURL)

                // Remove from metadata
                metadata.cachedFiles.removeValue(forKey: key)
                hasChanges = true
            }
        }

        if hasChanges {
            saveCacheMetadata(metadata)
            #if canImport(os)
            Self.logger.info("Cleaned up stale cache entries")
            #endif
        }
    }

    /// Get cache information for a specific item
    func getCacheInfo(for item: RemoteLibraryItem) -> CacheMetadata.CachedFileInfo? {
        let metadata = loadCacheMetadata()
        let key = item.url.absoluteString
        return metadata.cachedFiles[key]
    }

    // MARK: - Emulation coordination
    private func emulationIsRunning() -> Bool {
        #if os(iOS) || os(tvOS)
        return TVEmulationBridge.isRunning()
        #else
        return false
        #endif
    }

    private func waitWhileEmulationActive() async {
        while emulationIsRunning() {
            if Task.isCancelled { break }
            #if canImport(os)
            Self.logger.info("Emulation active; deferring WebDAV activity")
            #endif
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
        }
    }
}

// MARK: - Download Progress Delegate

/// URLSession delegate to track download progress
private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    weak var task: URLSessionDownloadTask?

    init(progressCallback: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progressCallback = progressCallback
        self.completion = completion
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        #if canImport(os)
        print("DownloadProgressDelegate: Download completed to: \(location)")
        #endif
        completion(.success(location))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            #if canImport(os)
            print("DownloadProgressDelegate: No expected bytes, skipping progress update")
            #endif
            return
        }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressCallback(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            #if canImport(os)
            print("DownloadProgressDelegate: Download failed with error: \(error)")
            #endif
            completion(.failure(error))
        }
        // Note: Success case is handled in didFinishDownloadingTo
    }
}
