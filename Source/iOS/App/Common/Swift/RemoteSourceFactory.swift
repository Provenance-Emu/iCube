import Foundation

/// Factory for creating and managing remote source instances
/// Ensures single instance per unique source configuration
@MainActor
class RemoteSourceFactory {
    private static var sources: [String: any RemoteLibrarySource] = [:]

    /// Get or create a WebDAV source with the given configuration
    /// Returns existing instance if one exists with the same ID
    static func webdavSource(
        id: String? = nil,
        name: String,
        url: URL,
        username: String?,
        password: String?,
        recursive: Bool = true,
        interval: TimeInterval = 900,
        startPath: String? = nil,
        enablePreCaching: Bool = false
    ) -> WebDAVSource {

        // Use provided ID or generate consistent one from URL
        let sourceId = id ?? WebDAVSource.generateConsistentId(for: url)

        if let existing = sources[sourceId] as? WebDAVSource {
            // Update mutable properties if they've changed
            existing.updateConfiguration(
                name: name,
                username: username,
                password: password,
                recursive: recursive,
                interval: interval,
                enablePreCaching: enablePreCaching
            )
            return existing
        }

        // Create new source
        let newSource = WebDAVSource(
            id: sourceId,
            name: name,
            url: url,
            username: username,
            password: password,
            recursive: recursive,
            interval: interval,
            startPath: startPath,
            enablePreCaching: enablePreCaching
        )

        sources[sourceId] = newSource
        return newSource
    }

    /// Get existing source by ID
    static func getSource(id: String) -> (any RemoteLibrarySource)? {
        return sources[id]
    }

    /// Remove source from factory (for cleanup)
    static func removeSource(id: String) {
        sources.removeValue(forKey: id)
    }

    /// Get all managed sources
    static func allSources() -> [any RemoteLibrarySource] {
        return Array(sources.values)
    }

    /// Clear all sources (for testing/reset)
    static func clearAll() {
        sources.removeAll()
    }
}
