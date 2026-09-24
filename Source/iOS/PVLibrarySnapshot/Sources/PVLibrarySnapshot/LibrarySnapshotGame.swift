import Foundation

public struct LibrarySnapshotGame: Codable, Sendable, Identifiable, Hashable {
    /// 6-character disc game id (e.g. `GALE01`), or the title id hex for WADs.
    public let id: String
    public let title: String
    public let filePath: String
    public let platform: LibraryPlatform
    public let gametdbID: String?
    public let region: String?
    public let lastPlayed: Date?
    public let isFavorite: Bool
    /// Basename inside `LibrarySnapshotAppGroup.mediaDirectory`, nil when the app has no cover.
    public let coverFilename: String?

    public init(id: String, title: String, filePath: String, platform: LibraryPlatform,
                gametdbID: String?, region: String?, lastPlayed: Date?, isFavorite: Bool,
                coverFilename: String?) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.platform = platform
        self.gametdbID = gametdbID
        self.region = region
        self.lastPlayed = lastPlayed
        self.isFavorite = isFavorite
        self.coverFilename = coverFilename
    }

    public var filename: String { (filePath as NSString).lastPathComponent }

    /// `dolphinios://play?id=<id>`, handled by `URLRouterService` in the app.
    public var launchURL: URL? {
        var components = URLComponents()
        components.scheme = "dolphinios"
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    public var coverURL: URL? {
        guard let coverFilename else { return nil }
        return LibrarySnapshotAppGroup.mediaDirectory?.appendingPathComponent(coverFilename, isDirectory: false)
    }
}
