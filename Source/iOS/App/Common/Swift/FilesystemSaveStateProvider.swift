import Foundation
import UIKit

public protocol SaveStateProviding {
    func states(for gameID: String) async -> [SaveStateInfo]
    func statesGroupedByGame() async -> [String: [SaveStateInfo]]
    func thumbnail(for state: SaveStateInfo) async -> UIImage?
    // Actions (stubs for now)
    func delete(state: SaveStateInfo) throws
}

public final class FilesystemSaveStateProvider: SaveStateProviding {
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let bridged = DolphinPaths.stateSavesURL() {
            self.root = bridged
        } else {
            // Last-resort fallback: use temporary directory (will likely yield no states)
            self.root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
    }

    public func states(for gameID: String) async -> [SaveStateInfo] {
        let grouped = await statesGroupedByGame()
        return grouped[gameID] ?? []
    }

    public func statesGroupedByGame() async -> [String: [SaveStateInfo]] {
        var result: [String: [SaveStateInfo]] = [:]
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        for url in entries {
            // Skip directories and PNG thumbnails
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            if url.pathExtension.lowercased() == "png" { continue }

            // Parse save state info
            let name = url.deletingPathExtension().lastPathComponent
            let gameID = Self.extractGameID(from: name)
            let slot = Self.extractSlot(from: name)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let created = values?.creationDate
            let modified = values?.contentModificationDate
            let size = (values?.fileSize).map { Int64($0) }

            // Thumbnail next to file with same basename + .png
            let thumbURL = url.deletingPathExtension().appendingPathExtension("png")
            let hasThumb = fm.fileExists(atPath: thumbURL.path)

            let info = SaveStateInfo(
                gameID: gameID,
                displayName: name,
                slot: slot,
                createdAt: created,
                modifiedAt: modified,
                sizeBytes: size,
                versionHash: nil,
                isCompatible: true,
                path: url,
                thumbnailURL: hasThumb ? thumbURL : nil
            )
            result[gameID, default: []].append(info)
        }

        // Sort each group by most recent modified first
        for (key, list) in result {
            result[key] = list.sorted { (a, b) in
                let ad = a.modifiedAt ?? a.createdAt ?? .distantPast
                let bd = b.modifiedAt ?? b.createdAt ?? .distantPast
                return ad > bd
            }
        }

        return result
    }

    public func thumbnail(for state: SaveStateInfo) async -> UIImage? {
        if let url = state.thumbnailURL, let data = try? Data(contentsOf: url), let img = UIImage(data: data, scale: UIScreen.main.scale) {
            return img
        }
        return nil
    }

    public func delete(state: SaveStateInfo) throws {
        try fm.removeItem(at: state.path)
        if let thumb = state.thumbnailURL, fm.fileExists(atPath: thumb.path) {
            try? fm.removeItem(at: thumb)
        }
    }

    // MARK: - Helpers
    private static func extractGameID(from baseName: String) -> String {
        // Heuristic: first 6 characters look like GALE01, RSBE01, etc.
        let trimmed = baseName.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 6 {
            let prefix = String(trimmed.prefix(6))
            // Basic validation: letters+digits
            if prefix.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil {
                return prefix
            }
        }
        return "UNKNOWN"
    }

    private static func extractSlot(from baseName: String) -> Int? {
        // Common patterns: "StateSlot1", "Slot-3", "s3" etc. Try a few regexes.
        let patterns = [
            "(?i)slot[-_ ]?(\\d+)",
            "(?i)stateslot[-_ ]?(\\d+)",
            "(?i)\\bs(\\d)\\b"
        ]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p),
               let m = r.firstMatch(in: baseName, range: NSRange(location: 0, length: baseName.utf16.count)),
               m.numberOfRanges >= 2,
               let range = Range(m.range(at: 1), in: baseName) {
                return Int(baseName[range])
            }
        }
        return nil
    }
}
