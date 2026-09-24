import Foundation

public struct DiscHeader: Equatable, Sendable {
    public let gameID: String
    public let makerCode: String
    public let discNumber: Int
    public let revision: Int
    public let title: String
    public let platform: LibraryPlatform

    /// 4th character of the game id: E=USA, P=Europe, J=Japan, K=Korea, ...
    public var regionCode: Character? {
        guard gameID.count >= 4 else { return nil }
        return gameID[gameID.index(gameID.startIndex, offsetBy: 3)]
    }
}

public enum DiscContainer: Equatable, Sendable {
    case iso, rvz, wia, wbfs, ciso, gcz, tgc, unknown
}

/// Reads the 0x80-byte disc header out of the containers iCube supports, without
/// the Dolphin core. Reads at most 64 KiB plus one sector-sized seek. Never throws.
public enum DiscHeaderReader {
    static let wiiMagic: UInt32 = 0x5D1C9EA3
    static let gameCubeMagic: UInt32 = 0xC2339F3D
    static let headerLength = 0x80
    static let titleOffset = 0x20
    static let titleLength = 0x60
    static let rvzHeaderOffset = 0x58
    static let cisoHeaderOffset = 0x8000
    static let initialReadLength = 0x10000

    public static func container(of data: Data) -> DiscContainer {
        guard data.count >= 4 else { return .unknown }
        let b = [UInt8](data.prefix(4))
        switch (b[0], b[1], b[2], b[3]) {
        case (0x52, 0x56, 0x5A, 0x01): return .rvz     // "RVZ\x01"
        case (0x57, 0x49, 0x41, 0x01): return .wia     // "WIA\x01"
        case (0x57, 0x42, 0x46, 0x53): return .wbfs    // "WBFS"
        case (0x43, 0x49, 0x53, 0x4F): return .ciso    // "CISO"
        case (0x01, 0xC0, 0x0B, 0xB1): return .gcz     // 0xB10BC001 LE
        case (0xAE, 0x0F, 0x38, 0xA2): return .tgc
        default:
            return parseDiscHeader(data) != nil ? .iso : .unknown
        }
    }

    public static func read(url: URL) -> DiscHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: initialReadLength), !head.isEmpty else { return nil }

        switch container(of: head) {
        case .iso:
            return parseDiscHeader(head)
        case .rvz, .wia:
            return parseDiscHeader(slice(head, at: rvzHeaderOffset))
        case .wbfs:
            guard head.count > 8 else { return nil }
            let shift = Int(head[8])
            guard (6...20).contains(shift) else { return nil }
            let offset = 1 << shift
            return parseDiscHeader(bytes(handle, head: head, at: offset, count: headerLength))
        case .ciso:
            guard head.count > 8, head[8] == 1 else { return nil }
            return parseDiscHeader(bytes(handle, head: head, at: cisoHeaderOffset, count: headerLength))
        case .gcz, .tgc, .unknown:
            return nil
        }
    }

    /// Parses a buffer whose first 0x80 bytes are a disc header. Requires one of the
    /// two magic words so arbitrary files are not misread as discs.
    static func parseDiscHeader(_ data: Data) -> DiscHeader? {
        guard data.count >= headerLength else { return nil }
        let d = Data(data)   // rebase indices to 0 for slices
        let idBytes = [UInt8](d[0..<6])
        guard idBytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        let platform: LibraryPlatform
        if be32(d, 0x18) == wiiMagic {
            platform = .wii
        } else if be32(d, 0x1C) == gameCubeMagic {
            platform = .gamecube
        } else {
            return nil
        }
        let gameID = String(decoding: idBytes, as: UTF8.self)
        let titleRaw = d[titleOffset..<(titleOffset + titleLength)]
        let titleBytes = titleRaw.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 <= 0x7E }
        let title = String(decoding: titleBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return DiscHeader(gameID: gameID,
                          makerCode: String(gameID.suffix(2)),
                          discNumber: Int(d[6]),
                          revision: Int(d[7]),
                          title: title,
                          platform: platform)
    }

    // MARK: - helpers

    private static func be32(_ d: Data, _ off: Int) -> UInt32 {
        guard d.count >= off + 4 else { return 0 }
        return UInt32(d[off]) << 24 | UInt32(d[off + 1]) << 16 | UInt32(d[off + 2]) << 8 | UInt32(d[off + 3])
    }

    private static func slice(_ d: Data, at offset: Int) -> Data {
        guard d.count > offset else { return Data() }
        return Data(d[offset...])
    }

    /// Returns `count` bytes at `offset`, from the already-read head when possible,
    /// otherwise by seeking the handle.
    private static func bytes(_ handle: FileHandle, head: Data, at offset: Int, count: Int) -> Data {
        if head.count >= offset + count {
            return Data(head[offset..<(offset + count)])
        }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: count) else { return Data() }
        return data
    }
}
