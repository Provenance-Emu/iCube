import Foundation

public struct ResolvedGame: Equatable, Sendable {
    public let title: String
    public let gameID: String?
    public let platform: LibraryPlatform
    public let region: String?
    public let discNumber: Int?
    public let makerCode: String?
    public let snapshotGame: LibrarySnapshotGame?
    /// Only set when the mirrored cover file actually exists on disk.
    public let coverURL: URL?

    public var isFavorite: Bool { snapshotGame?.isFavorite ?? false }
    public var lastPlayed: Date? { snapshotGame?.lastPlayed }
}

public enum LibraryLookup {
    /// iCloud evicts files to hidden `.Name.ext.icloud` placeholders; Quick Look hands
    /// us that URL. Recover the real name so the snapshot filename match still works.
    public static func realFilename(from url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".icloud") {
            name = String(name.dropLast(".icloud".count))
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
        }
        return name
    }

    /// Full pipeline: header read (skipped for iCloud placeholders), snapshot load, resolve.
    public static func resolve(url: URL, store: LibrarySnapshotStore = LibrarySnapshotStore()) -> ResolvedGame {
        let header = url.lastPathComponent.hasSuffix(".icloud") ? nil : DiscHeaderReader.read(url: url)
        return resolve(url: url, snapshot: store.load(), header: header)
    }

    /// Pure resolution, in priority order: header id → snapshot by id; no header →
    /// snapshot by filename; nothing → filename-derived title.
    public static func resolve(url: URL, snapshot: LibrarySnapshot, header: DiscHeader?) -> ResolvedGame {
        let filename = realFilename(from: url)
        let fromSnapshot: LibrarySnapshotGame?
        if let header {
            fromSnapshot = snapshot.game(id: header.gameID)
        } else {
            fromSnapshot = snapshot.game(filename: filename)
        }

        let gameID = header?.gameID ?? fromSnapshot?.id
        let platform = fromSnapshot?.platform ?? header?.platform ?? .unknown
        let headerTitle = header?.title.isEmpty == false ? header?.title : nil
        let title = fromSnapshot?.title ?? headerTitle ?? titleFromFilename(filename)
        let region = fromSnapshot?.region ?? regionName(for: header?.regionCode)
        let coverURL = fromSnapshot?.coverURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return ResolvedGame(title: title, gameID: gameID, platform: platform, region: region,
                            discNumber: header?.discNumber, makerCode: header?.makerCode,
                            snapshotGame: fromSnapshot, coverURL: coverURL)
    }

    /// 4th character of a disc game id: E=USA, P/D/F/I/S/U/X/Y=Europe, J=Japan,
    /// K/Q/T=Korea, W=Taiwan, R=Russia, A=Region Free. Unknown codes (e.g. "Z") return nil.
    public static func regionName(for code: Character?) -> String? {
        switch code {
        case "E": return "USA"
        case "P", "D", "F", "I", "S", "U", "X", "Y": return "Europe"
        case "J": return "Japan"
        case "K", "Q", "T": return "Korea"
        case "W": return "Taiwan"
        case "R": return "Russia"
        case "A": return "Region Free"
        default: return nil
        }
    }

    static func titleFromFilename(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
