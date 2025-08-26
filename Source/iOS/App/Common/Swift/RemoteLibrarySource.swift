import Foundation

/// Represents a single item (ROM file) from a remote library source
struct RemoteLibraryItem: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let displayName: String
    let sizeBytes: Int64?
    let etag: String?
    let lastModified: Date?

    // Convenience initializers for backward compatibility
    init(url: URL, name: String, size: Int64) {
        self.url = url
        self.displayName = name
        self.sizeBytes = size > 0 ? size : nil
        self.etag = nil
        self.lastModified = nil
    }

    init(url: URL, displayName: String, sizeBytes: Int64?, etag: String?, lastModified: Date?) {
        self.url = url
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// Protocol for remote library sources (WebDAV, FTP, etc.)
protocol RemoteLibrarySource {
    var id: String { get }
    var name: String { get }
    var isOnline: Bool { get }

    /// Stream of online/offline status changes
    var onlineStream: AsyncStream<Bool> { get }

    /// Stream of discovered items
    var itemsStream: AsyncStream<[RemoteLibraryItem]> { get }

    /// Start monitoring this source
    func start()

    /// Stop monitoring this source
    func stop()

    /// Pre-cache a specific item to local storage
    func preCacheItem(_ item: RemoteLibraryItem, progressCallback: @escaping (Double) -> Void) async throws -> String

    /// Cancel pre-caching for an item
    func cancelPreCache(_ item: RemoteLibraryItem) async

    /// Remove cached item from local storage
    func removeCachedItem(_ item: RemoteLibraryItem) async throws

    /// Get local cache directory for this source
    func getCacheDirectory() -> URL
}
