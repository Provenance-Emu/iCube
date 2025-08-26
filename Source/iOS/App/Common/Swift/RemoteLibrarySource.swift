import Foundation

/// Represents a single remote ROM entry.
public struct RemoteLibraryItem: Hashable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let displayName: String
    public let sizeBytes: Int64?
    public let etag: String?
    public let lastModified: Date?
    public init(url: URL, displayName: String, sizeBytes: Int64?, etag: String?, lastModified: Date?) {
        self.url = url
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// Protocol for any remote library source (e.g., WebDAV).
public protocol RemoteLibrarySource: AnyObject {
    /// Stable identifier for persistence
    var id: String { get }
    /// Human-readable name
    var name: String { get }
    /// Base URL for discovery
    var baseURL: URL { get }
    /// Whether the source is currently online
    var isOnline: Bool { get }
    /// Async stream of online state changes
    var onlineStream: AsyncStream<Bool> { get }
    /// Async stream of the latest discovered items list
    var itemsStream: AsyncStream<[RemoteLibraryItem]> { get }
    /// Start background monitoring and discovery
    func start()
    /// Stop any background work
    func stop()
}
