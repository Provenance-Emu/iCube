import Foundation

/// Mirrors `DiscIO::Platform` (Source/Core/DiscIO/Enums.h) without importing the core.
public enum LibraryPlatform: String, Codable, Sendable, CaseIterable {
    case gamecube, triforce, wii, wiiware, elfdol, unknown

    public init(discIOPlatform raw: Int) {
        switch raw {
        case 0: self = .gamecube
        case 1: self = .triforce
        case 2: self = .wii
        case 3: self = .wiiware
        case 4: self = .elfdol
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .gamecube: return "GameCube"
        case .triforce: return "Triforce"
        case .wii: return "Wii"
        case .wiiware: return "WiiWare"
        case .elfdol: return "Homebrew"
        case .unknown: return "Unknown"
        }
    }
}
