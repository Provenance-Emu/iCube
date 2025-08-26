import Foundation

/// Minimal WebDAV implementation that pings root and emits base URL as an item container.
final class WebDAVSource: RemoteLibrarySource {
    let id: String
    let name: String
    let baseURL: URL
    private let username: String?
    private let password: String?
    private let recursive: Bool
    private let interval: TimeInterval

    private var onlineCont: AsyncStream<Bool>.Continuation!
    private var itemsCont: AsyncStream<[RemoteLibraryItem]>.Continuation!

    private(set) var isOnline: Bool = false { didSet { onlineCont.yield(isOnline) } }

    let onlineStream: AsyncStream<Bool>
    let itemsStream: AsyncStream<[RemoteLibraryItem]>

    init(id: String = UUID().uuidString, name: String, url: URL, username: String?, password: String?, recursive: Bool, interval: TimeInterval = 900) {
        self.id = id
        self.name = name
        self.baseURL = url
        self.username = username
        self.password = password
        self.recursive = recursive
        self.interval = interval
        var oc: AsyncStream<Bool>.Continuation!
        self.onlineStream = AsyncStream<Bool> { c in oc = c; self.onlineCont = c }
        self.onlineCont = oc
        var ic: AsyncStream<[RemoteLibraryItem]>.Continuation!
        self.itemsStream = AsyncStream<[RemoteLibraryItem]> { c in ic = c; self.itemsCont = c }
        self.itemsCont = ic
    }

    func start() {
        Task { await loop() }
    }

    func stop() {
        onlineCont.finish()
        itemsCont.finish()
    }

    private func loop() async {
        while true {
            await ping()
            await listOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, data, resp as! HTTPURLResponse)
    }

    @MainActor private func ping() async {
        do {
            let (code, _, _) = try await request("HEAD", url: baseURL)
            isOnline = (200...399).contains(code)
        } catch {
            isOnline = false
        }
    }

    @MainActor private func listOnce() async {
        guard isOnline else { itemsCont.yield([]); return }
        // For now, emit just the base URL so the core can enumerate through FindAllGamePaths
        let root = RemoteLibraryItem(url: baseURL, displayName: name, sizeBytes: nil, etag: nil, lastModified: nil)
        itemsCont.yield([root])
    }
}
