import Foundation
import PVContinuity

// Host-only substitutes for UIKit/ObjC application bridges. Protocol, crypto,
// HTTP-client, manifest, planning and file-transfer code comes from pinned PVContinuity.
@MainActor enum TVLibraryBridge {
    static var registered: [String] = []
    static func updateLibrary(withRemotePaths paths: [String], fetchMetadata: Bool) { registered += paths }
}
@MainActor enum TVEmulationBridge {
    static var launched: [String] = []
    static func launchGame(atPath path: String) { launched.append(path) }
}
@MainActor enum SaveStateService {
    static var pendingBootStatePath: String?
    static var skipResumeOnce = false
}
enum UserFolderUtil {
    nonisolated(unsafe) static var root = FileManager.default.temporaryDirectory
    static func getUserFolder() -> String { root.path }
}
func L(_ key: String) -> String { key }
@MainActor final class ContinuityManager {
    static let shared = ContinuityManager()
    var recordedHosts: [ContinuityPairingClient.PairingHandle] = []
    func rememberPairedHost(_ handle: ContinuityPairingClient.PairingHandle) async {
        recordedHosts.append(handle)
    }
}
struct TVGameItem {
    var gameID = "GALE01"
    var title = "Example"
    var platform = 0
    var discNumber = 0
    var revision = 0
}
struct ICubeLibraryQuery: LibraryQuerying {
    func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch? { nil }
}
